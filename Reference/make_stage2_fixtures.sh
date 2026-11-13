#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="${1:-$ROOT/Tests/JXLEncoderTests/Fixtures/semantic}"
HARNESS="$HERE/build/harness/jxl-harness"
LINKED="$(sed -n 's/^LIBJXL_DIR:[^=]*=//p' "$HERE/build/harness/CMakeCache.txt")"
"$HERE/pin-check.sh" "$LINKED"
mkdir -p "$OUT"
if [[ "$ROOT/Tests/JXLEncoderTests/Fixtures/semantic/flower_1024.ppm" != "$OUT/flower_1024.ppm" ]]; then
  cp "$ROOT/Tests/JXLEncoderTests/Fixtures/semantic/flower_1024.ppm" "$OUT/flower_1024.ppm"
fi
python3 "$HERE/make_pixel_lifecycle_input.py" "$OUT/pixel_lifecycle_2057x521.ppm"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
"$HARNESS" quantized-ac "$SCRATCH/bounded_quantized.sem"
"$HARNESS" quantized-edge-ac "$ROOT/Tests/JXLEncoderTests/Fixtures/edge_dct.dump" "$SCRATCH/edge_fixed_quantized.sem"
"$HARNESS" coded-dimensions "$SCRATCH/coded_dimensions.sem"
"$HARNESS" quant-bias "$SCRATCH/quant_bias.sem"
"$HARNESS" distance-params "$SCRATCH/distance_params.sem"
python3 "$HERE/make_distance_filter_fixture.py" "$HARNESS" "$SCRATCH/distance_params.sem" "$SCRATCH/distance_filters.sem"
python3 "$HERE/make_dc_boundary_fixture.py" "$HARNESS" "$SCRATCH/distance_params.sem" "$SCRATCH"
cp "$SCRATCH/bounded_quantized.sem" "$OUT/bounded_quantized.sem"
cp "$SCRATCH/edge_fixed_quantized.sem" "$OUT/edge_fixed_quantized.sem"
cp "$SCRATCH/coded_dimensions.sem" "$OUT/coded_dimensions.sem"
cp "$SCRATCH/quant_bias.sem" "$OUT/quant_bias.sem"
cp "$SCRATCH/distance_params.sem" "$OUT/distance_params.sem"
cp "$SCRATCH/distance_filters.sem" "$OUT/distance_filters.sem"
cp "$SCRATCH/dc_boundary.sem" "$OUT/dc_boundary.sem"
cp "$SCRATCH/dc_boundary.ppm" "$OUT/dc_boundary.ppm"
for name in flower_1024 pixel_lifecycle_2057x521; do
  "$HARNESS" encode "$OUT/$name.ppm" 1 "$SCRATCH/$name.jxl"
  "$HARNESS" pixel-stages "$OUT/$name.ppm" "$SCRATCH/$name.jxl" \
    "$SCRATCH/$name.ac.bin" "$SCRATCH/$name.dc.bin" "$SCRATCH/$name.stages.sem"
  cp "$SCRATCH/$name.ac.bin" "$OUT/$name.ac.bin"
  cp "$SCRATCH/$name.dc.bin" "$OUT/$name.dc.bin"
  cp "$SCRATCH/$name.stages.sem" "$OUT/$name.stages.sem"
done
"$HERE/pin-check.sh" "$LINKED"
