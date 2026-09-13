#!/usr/bin/env bash
# Builda o Lambda de fallback (linux/arm64) e empacota em build/fallback.zip
# com o binário renomeado pra "bootstrap" (exigido pelo runtime provided.al2).
set -euo pipefail
APPNAME="fallback"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build"
mkdir -p "$OUT"

echo "Building $APPNAME (linux/arm64)"
GOOS=linux GOARCH=arm64 go build -o "$OUT/bootstrap" "$ROOT/cmd/$APPNAME"

python3 - "$OUT/bootstrap" "$OUT/$APPNAME.zip" << 'PY'
import sys, zipfile, os
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zf:
    info = zipfile.ZipInfo("bootstrap")
    info.external_attr = 0o755 << 16
    with open(src, "rb") as f:
        zf.writestr(info, f.read())
PY

echo "Lambda package: $OUT/$APPNAME.zip"
