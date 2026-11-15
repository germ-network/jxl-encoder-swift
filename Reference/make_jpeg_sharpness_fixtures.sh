#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HARNESS="${JXL_SHARPNESS_HARNESS:-$HERE/build/harness/jxl-harness}"
OUT="${1:-$ROOT/Tests/JXLEncoderTests/Fixtures/semantic}"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$OUT"

"$HARNESS" encode "$ROOT/Tests/JXLEncoderTests/Fixtures/edge_linear.dump" 1 "$SCRATCH/pixel.jxl"
"$HARNESS" dump "$SCRATCH/pixel.jxl" epf_sharpness > "$OUT/sharpness_pixel_edge.sem"

for pair in \
  'sharpness_jpeg_444 small_444' \
  'sharpness_jpeg_422 small_422' \
  'sharpness_jpeg_440 small_440' \
  'sharpness_jpeg_420_odd hopper_420_odd' \
  'sharpness_jpeg_gray_odd hopper_gray_odd'; do
  read -r name jpeg <<< "$pair"
  "$HARNESS" encode-jpeg "$ROOT/Tests/JXLEncoderTests/Fixtures/$jpeg.jpg" "$SCRATCH/$name.jxl"
  "$HARNESS" dump "$SCRATCH/$name.jxl" epf_sharpness > "$OUT/$name.sem"
done

echo 'PASS generated native decoded sharpness fixtures'
