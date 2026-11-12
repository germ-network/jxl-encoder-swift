#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$HERE/../Tests/JXLEncoderTests/Fixtures/semantic/ac_entropy_jpeg_2x1.sem}"
HARNESS="$HERE/build/harness/jxl-harness"
"$HERE/pin-check.sh" "$(sed -n 's/^LIBJXL_DIR:[^=]*=//p' "$HERE/build/harness/CMakeCache.txt")"
"$HARNESS" dump "$HERE/../Tests/JXLEncoderTests/Fixtures/ac_entropy_jpeg_2x1.jxl" ac_entropy ac_entropy_alphabet > "$OUT"
