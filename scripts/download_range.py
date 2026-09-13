#!/usr/bin/env python3
"""Baixa um objeto do apigw-transfer em blocos: HEAD (tamanho + ETag) + GET
com Range por bloco. Segue o contrato completo do cliente (ver
docs/client-behavior.md): o Location do 404 já vem 100% resolvido pelo
servidor (monta a key real via VTL -- ver módulo apigw_s3_proxy), então
basta seguir redirect normalmente -- usa o auto-follow padrão do requests
(path direto -> 302 -> /fallback/{key} -> 302 -> path direto, tudo numa
chamada só). O 202 (lock ocupado no fallback) é tratado de forma
transparente dentro de request() -- não é um redirect, mas também não
precisa de lógica especial em quem chama: qualquer HEAD/GET espera o
Retry-After e tenta de novo sozinho. Isso é desacoplado do retry
específico de chunk em get_range() (que trata erro transitório -- 5xx,
timeout, falha de conexão -- não 202). 403/404/416 são permanentes e não
são retentados.

Tamanho de bloco: o cliente não escolhe mais -- o servidor sempre
trunca a resposta com segurança (ver openapi.yaml.tftpl e SPEC.md §9),
então cada GET pede só `Range: bytes={start}-` (sem fim definido) e o
script avança pelo tamanho REAL recebido (Content-Length/len(body)),
não por um valor pré-calculado. Não existe mais flag de chunk-size.

Consistência entre chunks: manda `If-Match: <etag>` (do HEAD inicial) em
todo GET Range -- se o arquivo mudar no meio do download, o S3 responde
412 e o script para na hora, em vez de concatenar bytes de duas versões
diferentes do objeto.

Retomada: grava o ETag num sidecar `<saida>.etag`. Se rodar de novo e o
arquivo de saída + sidecar já existirem com o MESMO ETag do HEAD atual,
continua de onde parou (ou pula direto se já estiver completo) em vez de
baixar tudo de novo. Se o ETag mudou, descarta o parcial e recomeça do
zero com a versão atual.

Usa `requests` (não é mais stdlib-only) especificamente pela compressão
transparente: `requests` manda `Accept-Encoding` sozinho e descompacta
`Content-Encoding` sozinho em `resp.content` -- as duas pontas sempre
juntas, sem meio-termo. `urllib.request` puro faz só metade disso (nem
manda o header nem descompacta), o que é seguro por omissão mas exige
código manual pra realmente usar compressão -- ver SPEC.md §5 do
apigw-transfer pra essa distinção validada empiricamente contra o
próprio endpoint (`requests` decodifica certo; header manual sem
decodificação recebe bytes gzip crus). `pip install -r
scripts/requirements.txt`.

Uso:
    python scripts/download_range.py [url] [-o saida.bin] [-r N] [-v]

Sem argumento de URL, usa TEST_URL (constante abaixo, do stage dev atual).
Se recriar a API (terraform apply muda o rest_api_id), atualize essa constante
com 'terraform output -raw test_object_url'.
"""

import argparse
import os
import sys
import time

import requests

TEST_URL = "https://7d3q1z0cw9.execute-api.us-east-1.amazonaws.com/dev/servicenow-zurich-platform-security-ptbr.pdf"

# Teto de tempo total de espera pelo fallback (não é normativo, só evita
# ficar rodando pra sempre num teste de debug -- ver docs/client-behavior.md §7).
MAX_FALLBACK_WAIT_SECONDS = 120

# (conexão, leitura) em segundos -- sem timeout o requests pode esperar
# indefinidamente por uma conexão travada.
REQUEST_TIMEOUT = (10, 60)

# Status que não mudam repetindo a mesma requisição.
PERMANENT_STATUSES = {403, 404, 416}


def _do_request(url: str, method: str, verbose: bool, headers: dict = None):
    """Uma única tentativa HTTP, sem tratar 202 nem nada -- usada por
    request() abaixo. Segue redirect automaticamente (allow_redirects=True
    explícito -- o default do requests.head() de conveniência é False,
    mas aqui usamos requests.request() genérico pra HEAD/GET igual, então
    fixamos o comportamento em vez de depender do default implícito).
    resp.content já vem descompactado por requests caso o servidor mande
    Content-Encoding (gzip/deflate) -- não precisa de gzip.decompress()
    manual; requests também não levanta exceção pra status 4xx/5xx (ao
    contrário do urllib.error.HTTPError), então não precisa de try/except
    aqui pra separar sucesso de erro HTTP."""
    t0 = time.time()
    resp = requests.request(method, url, headers=headers or {}, allow_redirects=True,
                            timeout=REQUEST_TIMEOUT)
    body = resp.content
    resp_headers = dict(resp.headers)
    status = resp.status_code
    if verbose:
        dt = time.time() - t0
        print(f"  {method} {url} -> {status} ({dt:.2f}s) headers={resp_headers}")
    return status, resp_headers, body


def request(url: str, method: str, verbose: bool, headers: dict = None):
    """Wrapper de _do_request() que trata 202 (lock ocupado no fallback)
    de forma transparente pra QUALQUER chamada -- não é redirect, então o
    requests não ajuda sozinho aqui, mas também não precisa que cada
    call site saiba disso: espera o Retry-After e repete a MESMA
    requisição, até um teto de tempo. Decisão de design deliberadamente
    desacoplada do retry de chunk em get_range() (que é sobre erro
    transitório tipo 500, não sobre esperar o fallback terminar)."""
    deadline = time.time() + MAX_FALLBACK_WAIT_SECONDS
    while True:
        status, resp_headers, body = _do_request(url, method, verbose, headers)
        if status != 202:
            return status, resp_headers, body
        try:
            retry_after = int(resp_headers.get("Retry-After", "5"))
        except ValueError:  # Retry-After também pode vir como data HTTP
            retry_after = 5
        if time.time() + retry_after > deadline:
            raise RuntimeError(
                f"202 (lock ocupado) por mais de {MAX_FALLBACK_WAIT_SECONDS}s -- desistindo"
            )
        print(f"  202 (lock ocupado) -- aguardando {retry_after}s (Retry-After) antes de tentar de novo...")
        time.sleep(retry_after)


def head(url: str, verbose: bool):
    """Único HEAD: descobre tamanho + ETag e, de quebra, resolve a
    disponibilidade -- não precisa de uma etapa separada pra isso. O
    requests já seguiu os redirects sozinho (path direto -> fallback ->
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


def get_range(url: str, start: int, etag: str, retries: int, retry_delay: float, verbose: bool):
    """GET com Range bytes=start- (aberto -- sem fim definido: quem decide
    quanto vem de volta é o servidor, que trunca com segurança sozinho),
    mandando If-Match: etag (garante que esse chunk vem da mesma versão do
    objeto que o HEAD viu). Retorna (status, body, headers, tentativas) em
    sucesso ou erro transitório esgotado. Um 412 (ETag não bate -- o
    arquivo mudou no meio do download) NÃO é um erro comum retentável:
    levanta RuntimeError aqui mesmo, em vez de devolver como status
    "normal" -- assim não tem como quem chama esquecer de tratar e acabar
    concatenando bytes de duas versões diferentes do objeto como se fosse
    só "mais um chunk que falhou"."""
    req_headers = {"Range": f"bytes={start}-"}
    if etag:
        req_headers["If-Match"] = etag
    attempt = 0
    while True:
        attempt += 1
        try:
            status, headers, body = request(url, "GET", verbose, headers=req_headers)
        except requests.RequestException as e:
            # Timeout/falha de conexão: transitório, mesmo tratamento de um 5xx.
            if attempt > retries:
                raise RuntimeError(f"bloco a partir de bytes={start}: erro de rede após "
                                   f"{attempt} tentativas: {e}") from e
            print(f"  bytes={start}- -> {type(e).__name__} (tentativa {attempt}/{retries + 1}), "
                  f"retry em {retry_delay}s...")
            time.sleep(retry_delay)
            continue
        if status == 412:
            raise RuntimeError(
                "arquivo mudou durante o download (If-Match falhou, 412) -- "
                "rode de novo pra recomeçar do zero com a versão atual"
            )
        if status in PERMANENT_STATUSES:
            raise RuntimeError(f"bloco a partir de bytes={start}: HTTP {status} é permanente, "
                               f"sem retry: {body[:300]!r}")
        if status == 206 or attempt > retries:
            return status, body, headers, attempt
        print(f"  bytes={start}- -> HTTP {status} (tentativa {attempt}/{retries + 1}), "
              f"retry em {retry_delay}s...")
        time.sleep(retry_delay)


def _content_range_start(headers: dict):
    """Início do Content-Range ("bytes A-B/TOTAL" -> A), ou None se ausente/inválido."""
    value = headers.get("Content-Range", "")
    if not value.startswith("bytes ") or "-" not in value:
        return None
    try:
        return int(value[len("bytes "):].split("-", 1)[0])
    except ValueError:
        return None


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


def download(url: str, out_path: str, retries: int, retry_delay: float, verbose: bool):
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

    print(f"Baixando {total - start} bytes restantes -- tamanho de bloco decidido pelo servidor "
          f"a cada resposta, não pré-calculado aqui.")

    with open(out_path, mode) as f:
        idx = 0
        while start < total:
            idx += 1
            status, body, headers, attempts = get_range(url, start, etag, retries, retry_delay, verbose)
            content_range = headers.get("Content-Range", "-")
            print(f"[{idx}] bytes={start}- -> HTTP {status} "
                  f"len={len(body)} Content-Range={content_range} tentativas={attempts}")
            if status != 206:
                # Sem um "end" pré-calculado, não há como pular um bloco de
                # tamanho desconhecido e continuar de forma segura -- vira
                # erro fatal em vez de deixar um buraco de tamanho incerto
                # no arquivo (comportamento antigo, quando o cliente sabia
                # exatamente quantos bytes o bloco falho ia ocupar).
                raise RuntimeError(f"bloco a partir de bytes={start} falhou definitivamente: "
                                    f"HTTP {status} {body[:300]!r}")
            if len(body) == 0:
                raise RuntimeError(f"resposta 206 com corpo vazio a partir de bytes={start} -- "
                                    f"abortando pra evitar loop infinito")
            # O servidor ignora um Range que não entende e devolve a partir do
            # byte 0 (ver openapi.yaml.tftpl). Gravar isso no offset atual
            # corromperia o arquivo -- confere antes de escrever.
            got_start = _content_range_start(headers)
            if got_start != start:
                raise RuntimeError(f"pedido bytes={start}-, mas o servidor devolveu "
                                    f"Content-Range={content_range} -- abortando")
            f.write(body)
            start += len(body)

    actual_size = os.path.getsize(out_path) if os.path.exists(out_path) else 0
    print(f"\nConcluído. Esperado={total} bytes, arquivo local={actual_size} bytes"
          + (" (OK)" if actual_size == total else " -- TAMANHO NAO CONFERE"))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("url", nargs="?", default=TEST_URL,
                   help="URL do objeto (default: TEST_URL definida no topo do arquivo)")
    p.add_argument("-o", "--output", default="download.bin", help="arquivo de saída (default: download.bin)")
    p.add_argument("-r", "--retries", type=int, default=2,
                   help="tentativas extras por bloco em caso de erro (default: 2)")
    p.add_argument("--retry-delay", type=float, default=1.0, help="segundos entre tentativas (default: 1.0)")
    p.add_argument("-v", "--verbose", action="store_true", help="imprime headers completos de cada requisição")
    args = p.parse_args()

    try:
        download(args.url, args.output, args.retries, args.retry_delay, args.verbose)
    except (RuntimeError, requests.RequestException) as e:
        print(f"ERRO: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
