#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="$ROOT/Tests/JXLEncoderTests/Fixtures/semantic"
HARNESS="$HERE/build/harness/jxl-harness"
CJXL="$HERE/build/harness/libjxl/tools/cjxl"
LINKED="$(sed -n 's/^LIBJXL_DIR:[^=]*=//p' "$HERE/build/harness/CMakeCache.txt")"
: "${JPEG_PREFIX:?Set JPEG_PREFIX to the pinned jpeg-turbo 3.2.1 installation}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$HERE/pin-check.sh" "$LINKED"
source "$HERE/libjxl.pin"
test -x "$HARNESS" && test -x "$CJXL"
test -x "$JPEG_PREFIX/bin/cjpeg"
test "$("$JPEG_PREFIX/bin/cjpeg" -version 2>&1 | sed -n 's/.*version \([0-9.]*\).*/\1/p')" = "$JPEG_TURBO_VERSION"
grep -F "$JPEG_PREFIX/include" "$HERE/build/harness/compile_commands.json" >/dev/null
grep -F "$JPEG_PREFIX/lib/libjpeg" "$HERE/build/harness/libjxl/tools/CMakeFiles/cjxl.dir/link.txt" >/dev/null
mkdir -p "$OUT"

python3 - "$WORK/input.ppm" "$WORK/qtables.txt" <<'PY'
import sys

ppm, tables = sys.argv[1:]
with open(ppm, "wb") as f:
    f.write(b"P6\n512 512\n255\n")
    for by in range(64):
        for y in range(8):
            for bx in range(64):
                value = (bx * 31 + by * 47 + bx * by * 13) % 256
                f.write(bytes((value, value, value)) * 8)
tables_data = []
for i in range(3):
    table = [80 + 40 * i] * 64
    table[0] = 1
    if i == 0:
        for index in (8, 16, 24, 32, 40):
            table[index] = 1
    tables_data.extend(table)
with open(tables, "w") as f:
    for i in range(3):
        f.write(" ".join(map(str, tables_data[i * 64:(i + 1) * 64])) + "\n")
PY

name=distinct_quant_tables
"$JPEG_PREFIX/bin/cjpeg" -sample 2x2,1x1,1x1 -qtables "$WORK/qtables.txt" \
  -qslots 1,0,2 -outfile "$OUT/$name.jpg" "$WORK/input.ppm"
"$CJXL" "$OUT/$name.jpg" "$WORK/$name.jxl" -j 1 --num_threads=1 --effort=4 --quiet
"$HARNESS" dump "$WORK/$name.jxl" > "$OUT/$name.sem"
"$HARNESS" jpeg-witness "$OUT/$name.jpg" "$WORK/$name.jxl" \
  > "$OUT/${name}_context.sem"
"$HARNESS" version
"$HERE/pin-check.sh" "$LINKED"
