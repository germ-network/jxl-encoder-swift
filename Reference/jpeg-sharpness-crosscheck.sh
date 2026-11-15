#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HARNESS="${JXL_SHARPNESS_HARNESS:-$HERE/build/harness/jxl-harness}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

cd "$ROOT"
JXL_SHARPNESS_EXPORT_DIR="$OUT" swift test --scratch-path plans/.build \
  --filter DCGroupSharpnessTests.actualJPEGSharpnessCrossCheck
for stream in "$OUT"/*.jxl; do
  "$HARNESS" dump "$stream" epf_sharpness > "${stream%.jxl}.epf.sem"
done
JXL_SHARPNESS_CHECK_DIR="$OUT" swift test --skip-build \
  --scratch-path plans/.build \
  --filter DCGroupSharpnessTests.actualJPEGSharpnessCrossCheck
echo 'PASS actual Swift JPEG sharpness cross-check: static and optimized codestreams decoded by pinned libjxl'
