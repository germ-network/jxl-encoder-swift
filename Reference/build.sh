#!/usr/bin/env bash
# Builds the reference encoder and the stage dump tool used for differential
# testing. libjxl-tiny stays a pristine clone; only this script knows how to
# link against it.
set -euo pipefail

TINY="${TINY_DIR:-$HOME/tmp/automation/libjxl-tiny}"
OUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build"

if [ ! -d "$TINY" ]; then
	echo "libjxl-tiny not found at $TINY" >&2
	echo "  git clone --recursive https://github.com/libjxl/libjxl-tiny.git $TINY" >&2
	exit 1
fi

cmake -S "$TINY" -B "$TINY/build" -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF >/dev/null
cmake --build "$TINY/build" --target cjxl_tiny -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)" >/dev/null

mkdir -p "$OUT"
clang++ -std=c++17 -O2 \
	-I"$TINY" \
	-I"$TINY/third_party/highway" \
	"$(dirname "${BASH_SOURCE[0]}")/tools/dump_stages.cc" \
	"$TINY/build/encoder/libjxl_tiny.a" \
	"$TINY/build/third_party/highway/libhwy.a" \
	-o "$OUT/dump_stages"

cp "$TINY/build/encoder/cjxl_tiny" "$OUT/cjxl_tiny"
echo "built: $OUT/dump_stages, $OUT/cjxl_tiny"
