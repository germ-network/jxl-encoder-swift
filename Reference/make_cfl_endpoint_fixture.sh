#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JPEG_PREFIX="${JPEG_PREFIX:?set the pinned JPEG_PREFIX}"
CXX="${CXX:-c++}"
OUTPUT="$ROOT/Tests/JXLEncoderTests/Fixtures/cfl_endpoint_444.jpg"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
"$CXX" -std=c++17 -I"$JPEG_PREFIX/include" \
	"$ROOT/Reference/harness/generate_cfl_endpoint.cc" \
	-L"$JPEG_PREFIX/lib" -ljpeg -o "$TEMP/generate"
"$TEMP/generate" "$OUTPUT"
shasum -a 256 "$OUTPUT"
