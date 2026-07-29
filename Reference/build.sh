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

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Some stages we need to diff against are internal to tiny's translation units.
# Rather than transliterate them (which would only test our own copy), a small
# tracked patch exposes them. Applied idempotently so the checkout stays close
# to upstream and can still be pulled.
for patch in "$HERE"/patches/*.patch; do
	[ -e "$patch" ] || continue
	if git -C "$TINY" apply --reverse --check "$patch" 2>/dev/null; then
		echo "patch already applied: $(basename "$patch")"
	else
		git -C "$TINY" apply "$patch"
		echo "applied: $(basename "$patch")"
	fi
done

# The reference must be built in the configuration the port targets, or the
# dumps describe a different encoder. Chroma-from-luma is dropped (measured at
# ~0.5% size) and variable block sizes are dropped (~5-7%) per the scope fence.
#
# This is not cosmetic: OPTIMIZE_CHROMA_FROM_LUMA also selects kTileDim, 64 when
# on and 16 when off. That changes the stripe height and the whole tiling the
# adaptive quant field is computed over.
cat > "$TINY/encoder/config.h" <<'CONFIG'
#ifndef ENCODER_CONFIG_H_
#define ENCODER_CONFIG_H_

#define OPTIMIZE_CODE 1
#define OPTIMIZE_CHROMA_FROM_LUMA 0
#define OPTIMIZE_BLOCK_SIZES 0

#endif  // ENCODER_CONFIG_H_
CONFIG

cmake -S "$TINY" -B "$TINY/build" -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF >/dev/null
cmake --build "$TINY/build" --target cjxl_tiny -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)" >/dev/null

mkdir -p "$OUT"
clang++ -std=c++17 -O2 \
	-I"$TINY" \
	-I"$TINY/third_party/highway" \
	-I"$(dirname "${BASH_SOURCE[0]}")" \
	"$(dirname "${BASH_SOURCE[0]}")/tools/dump_stages.cc" \
	"$TINY/build/encoder/libjxl_tiny.a" \
	"$TINY/build/third_party/highway/libhwy.a" \
	-o "$OUT/dump_stages"

cp "$TINY/build/encoder/cjxl_tiny" "$OUT/cjxl_tiny"
echo "built: $OUT/dump_stages, $OUT/cjxl_tiny"
