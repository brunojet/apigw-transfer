#!/usr/bin/env bash
# Testa o endpoint do apigw-transfer: HEAD (tamanho) + GET com Range em
# vários tamanhos. Usado pra investigar o 500 Internal Server Error
# intermitente observado acima de ~6MiB por chunk (ver PLAN.md Fase 3).
#
# Uso:
#   ./scripts/probe-range-ceiling.sh <url_do_objeto> [repeticoes]
#
# Exemplo (pegando a URL direto do output do terraform):
#   cd terraform
#   ./../scripts/probe-range-ceiling.sh "$(terraform output -raw test_object_url)" 3

set -euo pipefail

URL="${1:?uso: $0 <url_do_objeto> [repeticoes]}"
REPEAT="${2:-1}"

echo "=== HEAD ==="
curl -sD - -o /dev/null "$URL"
echo

echo "=== Probing ranges (MiB), $REPEAT tentativa(s) cada ==="
for MB in 0.5 1 2 4 5 5.5 5.75 6 7 8 9 10 12; do
  BYTES=$(awk "BEGIN{printf \"%d\", $MB*1048576}")
  END=$((BYTES - 1))
  RESULTS=""
  for ((i = 1; i <= REPEAT; i++)); do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" "$URL" -H "Range: bytes=0-$END")
    RESULTS="$RESULTS $CODE"
  done
  echo "range 0-$END (~${MB}MiB, $BYTES bytes) ->$RESULTS"
done
