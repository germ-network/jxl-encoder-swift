#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HARNESS="${PIXEL_MODEL_HARNESS:-$ROOT/plans/pixel-model/reference-selected/jxl-harness}"
OUT="$ROOT/Tests/JXLEncoderTests/Fixtures/semantic/e4_pixel_block_model_ties.sem"
COUNTS="${TMPDIR:-/tmp}/e4_pixel_block_model_ties.counts"
python3 - "$COUNTS" <<'PY'
import sys
counts = [200 if index < 250 else 0 for index in range(256)]
with open(sys.argv[1], "w", encoding="utf-8") as output:
    output.write(" ".join(map(str, counts)))
PY
"$HARNESS" pixel-block-model "$COUNTS" 1.0 "$OUT"
PHOTO_OUT="$ROOT/Tests/JXLEncoderTests/Fixtures/semantic/e4_pixel_block_model_flower_1024.sem"
PHOTO_COUNTS="${TMPDIR:-/tmp}/e4_pixel_block_model_flower_1024.counts"
python3 - "$PHOTO_COUNTS" <<'PY'
import sys
counts = [0] * 256
counts[5] = 16384
with open(sys.argv[1], "w", encoding="utf-8") as output:
    output.write(" ".join(map(str, counts)))
PY
"$HARNESS" pixel-block-model "$PHOTO_COUNTS" 1.0 "$PHOTO_OUT"
