#!/usr/bin/env python3
"""Baixa um objeto do apigw-transfer em blocos: HEAD (tamanho) + GET com
Range por bloco. Segue o contrato completo do cliente (ver
docs/client-behavior.md): se o path direto responder 404/302, resolve o
template do Location (troca o literal "{key}" pela key real), chama
/fallback/{key}, trata 202 + Retry-After (espera e repete) até o fallback
responder 302, e só então baixa o conteúdo de verdade. Só stdlib
(urllib), sem dependencias.

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


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """urlopen() segue 301/302/303/307 automaticamente por padrao -- ruim
    aqui porque o Location do 404 e' um TEMPLATE com chaves literais
    ("/dev/fallback/{key}"), nao uma URL pronta pra buscar. Sem isso, o
    urllib tenta buscar essa URL malformada sozinho e o CloudFront rejeita
    com 400 antes do nosso codigo sequer ver o Location."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_opener = urllib.request.build_opener(_NoRedirect)


def request(url: str, method: str, verbose: bool, headers: dict = None):
    """Faz a requisicao e retorna (status, headers, body) sem levantar em
    4xx/5xx. Nao segue redirect automaticamente -- ver _NoRedirect acima."""
    req = urllib.request.Request(url, method=method, headers=headers or {})
    t0 = time.time()
    try:
        with _opener.open(req) as resp:
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


def resolve_fallback_url(location_template: str, key: str, origin: str) -> str:
    """Location do 404 é um template estático com o literal '{key}' dentro
    (ex.: '/dev/fallback/{key}') -- o cliente troca pela key real."""
    path = location_template.replace("{key}", urllib.parse.quote(key, safe="/"))
    return origin + path


def ensure_available(direct_url: str, verbose: bool) -> str:
    """Garante que o objeto existe no path direto, acionando o fallback se
    preciso. Retorna a URL final (pode ser a mesma direct_url) pronta pra
    HEAD/GET normal. Levanta RuntimeError em erro permanente (404 na origem)
    ou se o teto de espera (MAX_FALLBACK_WAIT_SECONDS) estourar."""
    parts = urllib.parse.urlsplit(direct_url)
    origin = f"{parts.scheme}://{parts.netloc}"
    key = parts.path.rsplit("/", 1)[-1]

    status, headers, _ = request(direct_url, "HEAD", verbose)
    if status == 200:
        return direct_url
    if status not in (302, 404):
        raise RuntimeError(f"HEAD inicial retornou status inesperado: {status}")

    location = headers.get("Location")
    if not location:
        raise RuntimeError(f"status {status} sem header Location -- não sei montar o fallback")

    fallback_url = resolve_fallback_url(location, key, origin)
    print(f"Objeto ausente no path direto -- acionando fallback: {fallback_url}")

    deadline = time.time() + MAX_FALLBACK_WAIT_SECONDS
    while True:
        status, headers, body = request(fallback_url, "GET", verbose)
        if status == 302:
            final_location = headers.get("Location")
            if not final_location:
                raise RuntimeError("fallback retornou 302 sem Location")
            print(f"Fallback concluiu -- objeto populado em {final_location}")
            return origin + final_location
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
            detail = body[:300]
            raise RuntimeError(f"objeto não existe nem na origem (404 permanente): {detail!r}")
        raise RuntimeError(f"fallback retornou status inesperado: {status} body={body[:300]!r}")


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
