#!/usr/bin/env bash
# Reproduce the e4 semantic corpus from recorded linear inputs and pinned PPMs.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$HERE/../Tests/JXLEncoderTests/Fixtures/semantic}"
HARNESS="$HERE/build/harness/jxl-harness"
LINKED="$(sed -n 's/^LIBJXL_DIR:[^=]*=//p' "$HERE/build/harness/CMakeCache.txt")"
"$HERE/pin-check.sh" "$LINKED"
mkdir -p "$OUT"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
for size in 512 1024; do
  python3 "$HERE/crop_ppm.py" "$LINKED/testdata/jxl/flower/flower.pnm" "$OUT/flower_${size}.ppm" 0 0 "$size" "$size"
done
for name in edge multigroup flower_512_d1 flower_512_d3 flower_1024; do
  distance=1
  case "$name" in
    edge|multigroup) input="$HERE/../Tests/JXLEncoderTests/Fixtures/${name}_linear.dump" ;;
    flower_512_d1) input="$OUT/flower_512.ppm" ;;
    flower_512_d3) input="$OUT/flower_512.ppm"; distance=3 ;;
    flower_1024) input="$OUT/flower_1024.ppm" ;;
  esac
  "$HARNESS" encode "$input" "$distance" "$SCRATCH/$name.jxl"
  "$HARNESS" dump "$SCRATCH/$name.jxl" > "$OUT/$name.sem"
done
"$HARNESS" encode "$HERE/../Tests/JXLEncoderTests/Fixtures/semantic/ac_entropy_flat.ppm" 1 "$SCRATCH/ac_entropy_flat_singleton.jxl"
"$HARNESS" dump "$SCRATCH/ac_entropy_flat_singleton.jxl" ac_entropy ac_entropy ac_entropy_alphabet > "$OUT/ac_entropy_flat_singleton.sem"
"$HARNESS" dump "$HERE/../Tests/JXLEncoderTests/Fixtures/edge_whole.jxl" ac_entropy ac_entropy ac_entropy_alphabet > "$OUT/ac_entropy_static_prefix.sem"
"$HARNESS" version
"$HERE/pin-check.sh" "$LINKED"
