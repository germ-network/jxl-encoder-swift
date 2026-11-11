#!/usr/bin/env bash
# Compare Swift decisions with the pinned decoder's interpretation of its files.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.."
HARNESS="$HERE/build/harness/jxl-harness"
if [ ! -x "$HARNESS" ]; then bash "$HERE/build-harness.sh"; fi
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
export JXL_CROSSCHECK_DIR="$OUT"
swift test --filter '^JXLEncoderTests.SemanticCrossCheckTests/write'
for file in "$OUT"/*.jxl; do
  "$HARNESS" dump "$file" > "${file%.jxl}.harness.sem"
done
swift test --skip-build --filter '^JXLEncoderTests.SemanticCrossCheckTests/harnessAgreesWithEmitters'
echo 'PASS semantic cross-check: five encodes and two decoded mutations'
