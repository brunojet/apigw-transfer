#!/usr/bin/env python3
"""Baixa um objeto do apigw-transfer em blocos: HEAD (tamanho) + GET com
Range por bloco. Segue o contrato completo do cliente (ver
docs/client-behavior.md): o Location do 404 já vem 100% resolvido pelo
servidor (monta a key real via VTL -- ver módulo apigw_s3_proxy), então
o cliente só precisa seguir redirect normalmente -- usa o auto-follow
padrão do urllib (path direto -> 302 -> /fallback/{key} -> 302 -> path
direto, tudo numa chamada só). Só o 202 (lock ocupado no fallback)
precisa de tratamento manual, porque não é um redirect -- trata
Retry-After e tenta de novo. Só stdlib (urllib), sem dependencias.

Uso:
    python scripts/download_range.py [url] [-o saida.bin] [-c BYTES] [-r N] [-v]

Sem argumento de URL, usa TEST_URL (constante abaixo, do stage dev atual).
Se recriar a API (terraform apply muda o rest_api_id), atualize essa constante
com 'terraform output -raw test_object_url'.
"""

import argparse
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

TEST_URL = "https://7d3q1z0cw9.execute-api.us-east-1.amazonaws.com/dev/servicenow-zurich-platform-security-ptbr.pdf"

# Teto de tempo total de espera pelo fallback (não é normativo, só evita
# ficar rodando pra sempre num teste de debug -- ver docs/client-behavior.md §7).
MAX_FALLBACK_WAIT_SECONDS = 120


def request(url: str, method: str, verbose: bool, headers: dict = None):
    """Faz a requisicao e retorna (status, headers, body) sem levantar em
    4xx/5xx. Segue redirect automaticamente (comportamento padrao do
    urllib) -- o Location do servidor ja vem resolvido, entao isso e'
    seguro (ver docstring do modulo)."""
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


def ensure_available(direct_url: str, verbose: bool) -> str:
    """Garante que o objeto existe, deixando o urllib seguir os redirects
    sozinho (path direto -> fallback -> path direto, numa chamada só).
    Só trata manualmente o 202 (lock ocupado no fallback -- não é um
    redirect, precisa esperar Retry-After e tentar tudo de novo do zero).
    Retorna direct_url (é sempre a URL final, já que o fallback redireciona
    de volta pra ela). Levanta RuntimeError em erro permanente (404 na
    origem) ou se o teto de espera (MAX_FALLBACK_WAIT_SECONDS) estourar."""
    deadline = time.time() + MAX_FALLBACK_WAIT_SECONDS
    while True:
        status, headers, body = request(direct_url, "HEAD", verbose)
        if status == 200:
            return direct_url
        if status == 202:
            retry_after = int(headers.get("Retry-After", "5"))
            if time.time() + retry_after > deadline:
                raise RuntimeError(
                    f"fallback continua 202 após {MAX_FALLBACK_WAIT_SECONDS}s de espera -- desistindo"
                )
            print(f"Fallback em andamento (202) -- aguardando {retry_after}s (Retry-After) antes de tentar de novo...")
            time.sleep(retry_after)
            continue
        if status == 404:
            raise RuntimeError(f"objeto não existe nem na origem (404 permanente): {body[:300]!r}")
        raise RuntimeError(f"status inesperado ao garantir disponibilidade: {status} body={body[:300]!r}")


def head(url: str, verbose: bool) -> int:
    status, headers, _ = request(url, "HEAD", verbose)
    if status != 200:
        raise RuntimeError(f"HEAD final retornou {status}, esperado 200")
    size = int(headers.get("Content-Length", "0"))
    print(f"HEAD -> {status} Content-Length={size}")
    return size


def get_range(url: str, start: int, end: int, retries: int, retry_delay: float, verbose: bool):
    """GET com Range bytes=start-end. Retorna (status, body, headers, tentativas)."""
    attempt = 0
    while True:
        attempt += 1
        status, headers, body = request(url, "GET", verbose, headers={"Range": f"bytes={start}-{end}"})
        if status == 206 or attempt > retries:
            return status, body, headers, attempt
        print(f"  bytes={start}-{end} -> HTTP {status} (tentativa {attempt}/{retries + 1}), "
              f"retry em {retry_delay}s...")
        time.sleep(retry_delay)


def download(url: str, out_path: str, chunk_size: int, retries: int, retry_delay: float, verbose: bool):
    url = ensure_available(url, verbose)

    total = head(url, verbose)
    if total == 0:
        print("Content-Length veio 0/ausente — abortando.")
        sys.exit(1)

    n_chunks = (total + chunk_size - 1) // chunk_size
    print(f"Baixando {total} bytes em {n_chunks} blocos de {chunk_size} bytes...")

    failures = []
    with open(out_path, "wb") as f:
        start = 0
        idx = 0
        while start < total:
            end = min(start + chunk_size, total) - 1
            idx += 1
            status, body, headers, attempts = get_range(url, start, end, retries, retry_delay, verbose)
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

    downloaded_expected = total
    actual_size = 0
    try:
        import os
        actual_size = os.path.getsize(out_path)
    except OSError:
        pass

    print(f"\nConcluído. Esperado={downloaded_expected} bytes, arquivo local={actual_size} bytes"
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
