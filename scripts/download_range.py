#!/usr/bin/env python3
"""Baixa um objeto do apigw-transfer em blocos: HEAD (tamanho) + GET com
Range por bloco. Só stdlib (urllib), sem dependencias.

Feito para debugar o 500 Internal Server Error intermitente observado em
blocos grandes (~6MiB+) via API Gateway -> S3 Service Proxy (PLAN.md Fase 3).

Uso:
    python scripts/download_range.py [url] [-o saida.bin] [-c BYTES] [-r N] [-v]

Sem argumento de URL, usa TEST_URL (constante abaixo, do stage dev atual).
Se recriar a API (terraform apply muda o rest_api_id), atualize essa constante
com 'terraform output -raw test_object_url'.
"""

import argparse
import sys
import time
import urllib.request
import urllib.error

TEST_URL = "https://7d3q1z0cw9.execute-api.us-east-1.amazonaws.com/dev/servicenow-zurich-platform-security-ptbr.pdf"


def head(url: str, verbose: bool) -> int:
    req = urllib.request.Request(url, method="HEAD")
    t0 = time.time()
    with urllib.request.urlopen(req) as resp:
        dt = time.time() - t0
        size = int(resp.headers.get("Content-Length", "0"))
        print(f"HEAD -> {resp.status} Content-Length={size} ({dt:.2f}s)")
        if verbose:
            for k, v in resp.headers.items():
                print(f"  {k}: {v}")
        return size


def get_range(url: str, start: int, end: int, retries: int, retry_delay: float, verbose: bool):
    """GET com Range bytes=start-end. Retorna (status, body, headers, tentativas)."""
    req = urllib.request.Request(url, headers={"Range": f"bytes={start}-{end}"})
    attempt = 0
    while True:
        attempt += 1
        t0 = time.time()
        try:
            with urllib.request.urlopen(req) as resp:
                body = resp.read()
                dt = time.time() - t0
                if verbose:
                    print(f"  ({dt:.2f}s) headers: {dict(resp.headers)}")
                return resp.status, body, dict(resp.headers), attempt
        except urllib.error.HTTPError as e:
            body = e.read()
            dt = time.time() - t0
            if verbose:
                print(f"  ({dt:.2f}s) HTTPError headers: {dict(e.headers or {})} body={body[:300]!r}")
            if attempt <= retries:
                print(f"  bytes={start}-{end} -> HTTP {e.code} (tentativa {attempt}/{retries + 1}), "
                      f"retry em {retry_delay}s...")
                time.sleep(retry_delay)
                continue
            return e.code, body, dict(e.headers or {}), attempt


def download(url: str, out_path: str, chunk_size: int, retries: int, retry_delay: float, verbose: bool):
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
    p.add_argument("-c", "--chunk-size", type=int, default=9 * 1024 * 1024,
                   help="tamanho do bloco em bytes (default: 9MiB)")
    p.add_argument("-r", "--retries", type=int, default=2,
                   help="tentativas extras por bloco em caso de erro (default: 2)")
    p.add_argument("--retry-delay", type=float, default=1.0, help="segundos entre tentativas (default: 1.0)")
    p.add_argument("-v", "--verbose", action="store_true", help="imprime headers completos de cada requisição")
    args = p.parse_args()

    download(args.url, args.output, args.chunk_size, args.retries, args.retry_delay, args.verbose)


if __name__ == "__main__":
    main()
