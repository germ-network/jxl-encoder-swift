#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="$HERE/build/harness/jxl-harness"
OUT="${1:-$HERE/../Tests/JXLEncoderTests/Fixtures/jpeg_huffman}"
mkdir -p "$OUT"
run_capture() {
  local name="$1" counts="$2" symbols="$3"
  "$HARNESS" jpeg-huffman "$counts" "$symbols" > "$OUT/$name.tsv"
  test "$(wc -l < "$OUT/$name.tsv" | tr -d ' ')" = 1024
}
run_capture root_sparse '0,2,0,0,0,0,0,0,0,0,0,0,0,0,0,0' '7,9'
run_capture subtable_9 '0,0,0,0,0,0,0,1,1,0,0,0,0,0,0,0' '7,9'
run_capture subtable_16 '1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1' '7,9'
python3 -c 'print(",".join(map(str, range(256))))' > "$OUT/maximal_ac.symbols"
run_capture maximal_ac '0,0,0,0,0,0,0,255,1,0,0,0,0,0,0,0' "$(cat "$OUT/maximal_ac.symbols")"
rm "$OUT/maximal_ac.symbols"
