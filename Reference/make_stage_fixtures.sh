#!/usr/bin/env bash
# Reproduce the recorded linear inputs and full-libjxl intermediate stages.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES="$HERE/../Tests/JXLEncoderTests/Fixtures"
OUT="${1:-$FIXTURES}"
HARNESS="$HERE/build/harness/jxl-harness"
mkdir -p "$OUT"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
python3 "$HERE/make_fixtures.py" "$SCRATCH/edge.pfm"
python3 - "$SCRATCH/edge.pfm" "$SCRATCH/edge.dump" <<'PYCODE'
import struct,sys
from pathlib import Path
with open(sys.argv[1],'rb') as f:
 assert f.readline()==b'PF\n'
 width,height=map(int,f.readline().split())
 assert f.readline()==b'-1.0\n'
 values=struct.unpack('<'+'f'*(width*height*3),f.read())
planes=[values[((height-1-y)*width+x)*3+c] for c in range(3) for y in range(height) for x in range(width)]
Path(sys.argv[2]).write_bytes(struct.pack('<4I',0x304d5544,width,height,3)+struct.pack('<'+'f'*len(planes),*planes))
PYCODE
"$HARNESS" version
"$HARNESS" stages linear "$SCRATCH/edge.dump" "$OUT/edge_linear.dump"
for name in stripe multigroup; do
  "$HARNESS" stages linear "$FIXTURES/${name}_linear.dump" "$OUT/${name}_linear.dump"
done
"$HARNESS" stages xyb "$OUT/edge_linear.dump" "$OUT/edge_xyb.dump"
"$HARNESS" stages dct "$OUT/edge_linear.dump" "$OUT/edge_dct.dump"
"$HARNESS" stages dct "$OUT/stripe_linear.dump" "$OUT/stripe_dct.dump"
