#!/usr/bin/env bash
# Headless stand-in for draw-things-cli generate. Writes a tiny PNG to --output.
set -euo pipefail
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output|-o)
      out="${2:-}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
if [[ -z "${out}" ]]; then
  echo "fake_drawthings_cli: --output required" >&2
  exit 2
fi
mkdir -p "$(dirname "$out")"
python3 - "$out" <<'PY'
import struct, zlib, sys
path = sys.argv[1]
def chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)
raw = b"\x00" + b"\x00\x00\x00"
png = (
    b"\x89PNG\r\n\x1a\n"
    + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
    + chunk(b"IDAT", zlib.compress(raw))
    + chunk(b"IEND", b"")
)
open(path, "wb").write(png)
PY
