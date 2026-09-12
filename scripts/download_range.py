#!/usr/bin/env python3
"""Baixa um objeto do apigw-transfer em blocos: HEAD (tamanho + ETag) + GET
com Range por bloco. Segue o contrato completo do cliente (ver
docs/client-behavior.md): o Location do 404 já vem 100% resolvido pelo
servidor (monta a key real via VTL -- ver módulo apigw_s3_proxy), então
basta seguir redirect normalmente -- usa o auto-follow padrão do urllib
(path direto -> 302 -> /fallback/{key} -> 302 -> path direto, tudo numa
chamada só). O 202 (lock ocupado no fallback) é tratado de forma
transparente dentro de request() -- não é um redirect, mas também não
precisa de lógica especial em quem chama: qualquer HEAD/GET espera o
Retry-After e tenta de novo sozinho. Isso é desacoplado do retry
específico de chunk em get_range() (que trata erro transitório tipo 500,
não 202).

Consistência entre chunks: manda `If-Match: <etag>` (do HEAD inicial) em
todo GET Range -- se o arquivo mudar no meio do download, o S3 responde
412 e o script para na hora, em vez de concatenar bytes de duas versões
diferentes do objeto.

Retomada: grava o ETag num sidecar `<saida>.etag`. Se rodar de novo e o
arquivo de saída + sidecar já existirem com o MESMO ETag do HEAD atual,
continua de onde parou (ou pula direto se já estiver completo) em vez de
baixar tudo de novo. Se o ETag mudou, descarta o parcial e recomeça do
zero com a versão atual.

Só stdlib (urllib), sem dependencias.

Uso:
    python scripts/download_range.py [url] [-o saida.bin] [-c BYTES] [-r N] [-v]

Sem argumento de URL, usa TEST_URL (constante abaixo, do stage dev atual).
Se recriar a API (terraform apply muda o rest_api_id), atualize essa constante
com 'terraform output -raw test_object_url'.
"""

import argparse
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

TEST_URL = "https://7d3q1z0cw9.execute-api.us-east-1.amazonaws.com/dev/servicenow-zurich-platform-security-ptbr.pdf"

# Teto de tempo total de espera pelo fallback (não é normativo, só evita
# ficar rodando pra sempre num teste de debug -- ver docs/client-behavior.md §7).
MAX_FALLBACK_WAIT_SECONDS = 120


def _do_request(url: str, method: str, verbose: bool, headers: dict = None):
    """Uma única tentativa HTTP, sem tratar 202 nem nada -- usada por
    request() abaixo. Segue redirect automaticamente (padrão do urllib)."""
    req = urllib.request.Request(url, method=method, headers=headers or {})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req) as resp:
            body = resp.read()
            resp_headers = dict(resp.headers)
            status = resp.status
    except urllib.error.HTTPError as e:
        body = e.read()
        resp_headers = dict(e.headers or {})
        status = e.code
    if verbose:
        dt = time.time() - t0
        print(f"  {method} {url} -> {status} ({dt:.2f}s) headers={resp_headers}")
    return status, resp_headers, body


def request(url: str, method: str, verbose: bool, headers: dict = None):
    """Wrapper de _do_request() que trata 202 (lock ocupado no fallback)
    de forma transparente pra QUALQUER chamada -- não é redirect, então o
    urllib não ajuda sozinho aqui, mas também não precisa que cada
    call site saiba disso: espera o Retry-After e repete a MESMA
    requisição, até um teto de tempo. Decisão de design deliberadamente
    desacoplada do retry de chunk em get_range() (que é sobre erro
    transitório tipo 500, não sobre esperar o fallback terminar)."""
    deadline = time.time() + MAX_FALLBACK_WAIT_SECONDS
    while True:
        status, resp_headers, body = _do_request(url, method, verbose, headers)
        if status != 202:
            return status, resp_headers, body
        retry_after = int(resp_headers.get("Retry-After", "5"))
        if time.time() + retry_after > deadline:
            raise RuntimeError(
                f"202 (lock ocupado) por mais de {MAX_FALLBACK_WAIT_SECONDS}s -- desistindo"
            )
        print(f"  202 (lock ocupado) -- aguardando {retry_after}s (Retry-After) antes de tentar de novo...")
        time.sleep(retry_after)


def head(url: str, verbose: bool):
    """Único HEAD: descobre tamanho + ETag e, de quebra, resolve a
    disponibilidade -- não precisa de uma etapa separada pra isso. O
    urllib já seguiu os redirects sozinho (path direto -> fallback ->
    path direto) e request() já absorveu qualquer 202 no caminho; aqui só
    sobra checar 200 vs 404 (permanente) vs algo inesperado."""
    status, headers, body = request(url, "HEAD", verbose)
    if status == 200:
        size = int(headers.get("Content-Length", "0"))
        etag = headers.get("ETag", "")
        print(f"HEAD -> {status} Content-Length={size} ETag={etag}")
        return size, etag
    if status == 404:
        raise RuntimeError(f"objeto não existe nem na origem (404 permanente): {body[:300]!r}")
    raise RuntimeError(f"HEAD retornou status inesperado: {status} body={body[:300]!r}")


def get_range(url: str, start: int, end: int, etag: str, retries: int, retry_delay: float, verbose: bool):
    """GET com Range bytes=start-end, mandando If-Match: etag (garante que
    esse chunk vem da mesma versão do objeto que o HEAD viu). Retorna
    (status, body, headers, tentativas) em sucesso ou erro transitório
    esgotado. Um 412 (ETag não bate -- o arquivo mudou no meio do
    download) NÃO é um erro comum retentável: levanta RuntimeError aqui
    mesmo, em vez de devolver como status "normal" -- assim não tem como
    quem chama esquecer de tratar e acabar concatenando bytes de duas
    versões diferentes do objeto como se fosse só "mais um chunk que
    falhou"."""
    req_headers = {"Range": f"bytes={start}-{end}"}
    if etag:
        req_headers["If-Match"] = etag
    attempt = 0
    while True:
        attempt += 1
        status, headers, body = request(url, "GET", verbose, headers=req_headers)
        if status == 412:
            raise RuntimeError(
                "arquivo mudou durante o download (If-Match falhou, 412) -- "
                "rode de novo pra recomeçar do zero com a versão atual"
            )
        if status == 206 or attempt > retries:
            return status, body, headers, attempt
        print(f"  bytes={start}-{end} -> HTTP {status} (tentativa {attempt}/{retries + 1}), "
              f"retry em {retry_delay}s...")
        time.sleep(retry_delay)


def _etag_sidecar(out_path: str) -> str:
    return out_path + ".etag"


def _load_saved_etag(out_path: str):
    sidecar = _etag_sidecar(out_path)
    if os.path.exists(sidecar):
        with open(sidecar, "r", encoding="utf-8") as f:
            return f.read().strip() or None
    return None


def _save_etag(out_path: str, etag: str):
    with open(_etag_sidecar(out_path), "w", encoding="utf-8") as f:
        f.write(etag)


def download(url: str, out_path: str, chunk_size: int, retries: int, retry_delay: float, verbose: bool):
    total, etag = head(url, verbose)
    if total == 0:
        print("Content-Length veio 0/ausente — abortando.")
        sys.exit(1)

    start = 0
    mode = "wb"
    saved_etag = _load_saved_etag(out_path)
    if saved_etag and os.path.exists(out_path):
        if saved_etag == etag:
            existing_size = os.path.getsize(out_path)
            if existing_size >= total:
                print(f"Já baixado por completo ({existing_size} bytes, ETag confere) — nada a fazer.")
                return
            start = existing_size
            mode = "ab"
            print(f"Retomando de onde parou: {start}/{total} bytes já no disco (ETag confere).")
        else:
            print("ETag mudou desde a última tentativa — descartando parcial e recomeçando do zero.")

    _save_etag(out_path, etag)

    n_chunks = ((total - start) + chunk_size - 1) // chunk_size
    print(f"Baixando {total - start} bytes restantes em {n_chunks} blocos de {chunk_size} bytes...")

    failures = []
    with open(out_path, mode) as f:
        idx = 0
        while start < total:
            end = min(start + chunk_size, total) - 1
            idx += 1
            status, body, headers, attempts = get_range(url, start, end, etag, retries, retry_delay, verbose)
            content_range = headers.get("Content-Range", "-")
            print(f"[{idx}/{n_chunks}] bytes={start}-{end} -> HTTP {status} "
                  f"len={len(body)} Content-Range={content_range} tentativas={attempts}")
            if status != 206:
                print(f"  ERRO definitivo neste bloco: {body[:300]!r}")
                failures.append((start, end, status))
                start = end + 1
                continue
            f.write(body)
            start = end + 1

    actual_size = os.path.getsize(out_path) if os.path.exists(out_path) else 0
    print(f"\nConcluído. Esperado={total} bytes, arquivo local={actual_size} bytes"
          + (" (OK, sem falhas)" if not failures else f" -- {len(failures)} bloco(s) falharam: {failures}"))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("url", nargs="?", default=TEST_URL,
                   help="URL do objeto (default: TEST_URL definida no topo do arquivo)")
    p.add_argument("-o", "--output", default="download.bin", help="arquivo de saída (default: download.bin)")
    p.add_argument("-c", "--chunk-size", type=int, default=8 * 1024 * 1024,
                   help="tamanho do bloco em bytes (default: 8MiB, validado na Fase 3)")
    p.add_argument("-r", "--retries", type=int, default=2,
                   help="tentativas extras por bloco em caso de erro (default: 2)")
    p.add_argument("--retry-delay", type=float, default=1.0, help="segundos entre tentativas (default: 1.0)")
    p.add_argument("-v", "--verbose", action="store_true", help="imprime headers completos de cada requisição")
    args = p.parse_args()

    try:
        download(args.url, args.output, args.chunk_size, args.retries, args.retry_delay, args.verbose)
    except RuntimeError as e:
        print(f"ERRO: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
