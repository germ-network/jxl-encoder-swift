#!/usr/bin/env bash
# Unpinned, frozen build of libjxl-tiny reference tools.
# Not part of the pinned reference build; retained for differential testing
# of legacy-tiny fixtures until retargeted to the pinned libjxl.
set -euo pipefail

echo "=== libjxl-tiny legacy build (unpinned, frozen, not part of the pinned build) ==="

if [ -z "${TINY_DIR:-}" ] || [ ! -d "$TINY_DIR" ]; then
	echo "TINY_DIR is required and must be an existing directory" >&2
	echo "Usage: TINY_DIR=/path/to/libjxl-tiny $0" >&2
	exit 1
fi

TINY="$TINY_DIR"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$(cd "$HERE/.." && pwd)/build/legacy-tiny"

# Some stages we need to diff against are internal to tiny's translation units.
# A tracked patch exposes them. Applied idempotently so the checkout stays
# close to upstream.
for patch in "$HERE"/patches/*.patch; do
	[ -e "$patch" ] || continue
	if git -C "$TINY" apply --reverse --check "$patch" 2>/dev/null; then
		echo "patch already applied: $(basename "$patch")"
	else
		git -C "$TINY" apply "$patch"
		echo "applied: $(basename "$patch")"
	fi
done

# The reference must be built in the configuration the port targets.
# OPTIMIZE_CODE selects between static prefix-code tables (0) and per-image
# optimized Huffman trees (1). All current gates use 0.
OPTIMIZE_CODE="${OPTIMIZE_CODE:-0}"
cat > "$TINY/encoder/config.h" <<CONFIG
#ifndef ENCODER_CONFIG_H_
#define ENCODER_CONFIG_H_

#define OPTIMIZE_CODE $OPTIMIZE_CODE
#define OPTIMIZE_CHROMA_FROM_LUMA 0
#define OPTIMIZE_BLOCK_SIZES 0

#endif  // ENCODER_CONFIG_H_
CONFIG

cmake -S "$TINY" -B "$TINY/build" -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF >/dev/null
cmake --build "$TINY/build" --target cjxl_tiny -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)" >/dev/null

mkdir -p "$OUT"
for tool in dump_stages gencodes genctx genprefix gentokens gentree; do
	clang++ -std=c++17 -O2 \
		-I"$TINY" \
		-I"$TINY/third_party/highway" \
		-I"$HERE" \
		"$HERE/tools/${tool}.cc" \
		"$TINY/build/encoder/libjxl_tiny.a" \
		"$TINY/build/third_party/highway/libhwy.a" \
		-o "$OUT/${tool}"
	echo "built: $OUT/${tool}"
done

cp "$TINY/build/encoder/cjxl_tiny" "$OUT/cjxl_tiny"
echo "built: $OUT/cjxl_tiny"
