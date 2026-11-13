#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="${1:-$ROOT/Tests/JXLEncoderTests/Fixtures/semantic}"
HARNESS="$HERE/build/harness/jxl-harness"
CJXL="$HERE/build/harness/libjxl/tools/cjxl"
LINKED="$(sed -n 's/^LIBJXL_DIR:[^=]*=//p' "$HERE/build/harness/CMakeCache.txt")"
JPEG_PREFIX="${JPEG_PREFIX:-/opt/homebrew}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$HERE/pin-check.sh" "$LINKED"
source "$HERE/libjxl.pin"
test -x "$HARNESS" && test -x "$CJXL"
test -x "$JPEG_PREFIX/bin/cjpeg"
test "$("$JPEG_PREFIX/bin/cjpeg" -version 2>&1 | sed -n 's/.*version \([0-9.]*\).*/\1/p')" = "$JPEG_TURBO_VERSION"
mkdir -p "$OUT"

FLOWER="$LINKED/testdata/jxl/flower/flower.pnm"
python3 "$HERE/crop_ppm.py" "$FLOWER" "$WORK/flower_513x267.ppm" 0 0 513 267
"$JPEG_PREFIX/bin/cjpeg" -quality 100 -sample 1x1 -outfile "$OUT/jpeg_flat_444.jpg" "$ROOT/Tests/JXLEncoderTests/Fixtures/semantic/ac_entropy_flat.ppm"
for sampling in 1x2 2x2; do
  case "$sampling" in
    1x2) name=440 ;;
    2x2) name=420 ;;
  esac
  "$JPEG_PREFIX/bin/cjpeg" -quality 100 -sample "$sampling" -outfile "$OUT/jpeg_flower_513x267_${name}.jpg" "$WORK/flower_513x267.ppm"
done

names=(jpeg_hopper_gray_odd jpeg_hopper_420_restart jpeg_hopper_420_odd jpeg_hopper_420_sof1 jpeg_small_422 jpeg_small_440 jpeg_small_444 jpeg_flat_444 jpeg_flower_513x267_422 jpeg_flower_513x267_440 jpeg_flower_513x267_420)
inputs=(
  "$ROOT/Tests/JXLEncoderTests/Fixtures/hopper_gray_odd.jpg"
  "$ROOT/Tests/JXLEncoderTests/Fixtures/hopper_420_restart.jpg"
  "$ROOT/Tests/JXLEncoderTests/Fixtures/hopper_420_odd.jpg"
  "$ROOT/Tests/JXLEncoderTests/Fixtures/hopper_420_sof1.jpg"
  "$ROOT/Tests/JXLEncoderTests/Fixtures/small_422.jpg"
  "$ROOT/Tests/JXLEncoderTests/Fixtures/small_440.jpg"
  "$ROOT/Tests/JXLEncoderTests/Fixtures/small_444.jpg"
  "$OUT/jpeg_flat_444.jpg"
  "$ROOT/Tests/JXLEncoderTests/Fixtures/ac_entropy_jpeg_2x1.jpg"
  "$OUT/jpeg_flower_513x267_440.jpg"
  "$OUT/jpeg_flower_513x267_420.jpg"
)
for i in "${!names[@]}"; do
  name="${names[$i]}"
  input="${inputs[$i]}"
  "$HARNESS" encode-jpeg "$input" "$WORK/$name-api.jxl"
  "$CJXL" "$input" "$WORK/$name-cjxl.jxl" -j 1 --num_threads=1 --effort=4 --quiet
  "$HARNESS" dump "$WORK/$name-api.jxl" > "$WORK/$name-api.sem"
  "$HARNESS" dump "$WORK/$name-cjxl.jxl" > "$WORK/$name-cjxl.sem"
  cmp "$WORK/$name-cjxl.sem" "$WORK/$name-api.sem"
  cp "$WORK/$name-api.sem" "$OUT/$name.sem"
done
for suffix in 420 422 440; do
  name="jpeg_flower_513x267_${suffix}"
  case "$suffix" in
    420|440) input="$OUT/$name.jpg" ;;
    422) input="$ROOT/Tests/JXLEncoderTests/Fixtures/ac_entropy_jpeg_2x1.jpg" ;;
  esac
  "$HARNESS" encode-jpeg "$input" "$WORK/$name-api.jxl"
  "$HARNESS" jpeg-witness "$input" "$WORK/$name-api.jxl" > "$OUT/${name}_context.sem"
done
"$HARNESS" version
"$HERE/pin-check.sh" "$LINKED"
