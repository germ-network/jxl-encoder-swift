#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${JPEG_PREFIX:?set the pinned JPEG_PREFIX}"
: "${JXL_SOURCE:?set the pinned libjxl source checkout}"
JXL_PIN=a7a9c787341cf703dede03c2009fa460cae5e5df
BUILD_DIR="${JXL_CFL_BUILD_DIR:-$ROOT/Reference/build/harness}"
HARNESS="${JXL_CFL_HARNESS:-$BUILD_DIR/jxl-harness}"
CJXL="${CJXL:-$BUILD_DIR/libjxl/tools/cjxl}"
JPEG="$ROOT/Tests/JXLEncoderTests/Fixtures/cfl_tile_65x8.jpg"
DUMP="$ROOT/Tests/JXLEncoderTests/Fixtures/semantic/cfl_tile_65x8_source.sem"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT

[[ "$(git -C "$JXL_SOURCE" rev-parse HEAD)" == "$JXL_PIN" ]]
[[ -z "$(git -C "$JXL_SOURCE" status --porcelain)" ]]
c++ -std=c++17 -I"$JPEG_PREFIX/include" \
	"$ROOT/Reference/harness/generate_cfl_tile_fixture.cc" \
	-L"$JPEG_PREFIX/lib" -ljpeg -o "$TEMP/generate"
"$TEMP/generate" "$JPEG"
cmake --build "$BUILD_DIR" --target cjxl
"$CJXL" "$JPEG" "$TEMP/source.jxl" -j 1 -e 4 --container=0 --quiet
"$HARNESS" jpeg-witness "$JPEG" "$TEMP/source.jxl" >"$DUMP"
shasum -a 256 "$JPEG" "$DUMP"
