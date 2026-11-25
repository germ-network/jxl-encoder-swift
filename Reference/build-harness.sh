#!/usr/bin/env bash
# Builds the out-of-tree reference harness (Reference/harness) against the
# pinned libjxl checkout, into Reference/build/harness. libjxl itself is built
# as a subproject there, never inside the checkout, so pin-check stays green.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIN_FILE="$HERE/libjxl.pin"

if [ ! -f "$PIN_FILE" ]; then
	echo "PIN DRIFT: pin file missing: $PIN_FILE" >&2
	exit 1
fi

# shellcheck disable=SC1090
source "$PIN_FILE"

TARGET_DIR="${1:-${LIBJXL_DIR:-$HOME/tmp/automation/libjxl-v0.12.0}}"
OUT="$HERE/build/harness"
JPEG_PREFIX="${JPEG_PREFIX:-}"
if [ -z "$JPEG_PREFIX" ]; then
	echo "Set JPEG_PREFIX to the pinned libjpeg-turbo 3.2.1 installation." >&2
	exit 1
fi
if [ ! -r "$JPEG_PREFIX/include/jconfig.h" ] ||
	[ ! -r "$JPEG_PREFIX/lib/libjpeg.dylib" ]; then
	echo "JPEG_PREFIX is missing jconfig.h or libjpeg.dylib: $JPEG_PREFIX" >&2
	exit 1
fi
JPEG_VERSION="$(awk '$1 == "#define" && $2 == "LIBJPEG_TURBO_VERSION" { print $3; exit }' "$JPEG_PREFIX/include/jconfig.h" | tr -d '"\r')"
if [ "$JPEG_VERSION" != "$JPEG_TURBO_VERSION" ]; then
	echo "JPEG_PREFIX must contain libjpeg-turbo $JPEG_TURBO_VERSION; found ${JPEG_VERSION:-unknown}." >&2
	exit 1
fi

if [ ! -d "$TARGET_DIR/.git" ]; then
	echo "Target directory $TARGET_DIR not found; fetching..."
	"$HERE/fetch-libjxl.sh" "$TARGET_DIR"
fi

"$HERE/pin-check.sh" "$TARGET_DIR"

NCPU="$(sysctl -n hw.ncpu 2>/dev/null || nproc)"

echo "Building jxl-harness against $TARGET_DIR..."
# shellcheck disable=SC2086
cmake -S "$HERE/harness" -B "$OUT" $CMAKE_FLAGS_RELEASE \
	-DLIBJXL_DIR="$TARGET_DIR" -DLIBJXL_COMMIT="$LIBJXL_COMMIT" \
	-DJPEG_INCLUDE_DIR="$JPEG_PREFIX/include" \
	-DJPEG_LIBRARY_RELEASE="$JPEG_PREFIX/lib/libjpeg.dylib" \
	-DCMAKE_EXPORT_COMPILE_COMMANDS=ON >/dev/null
# GNU Make 3.81 splits the spaced Xcode developer path in recursive calls.
env -u DEVELOPER_DIR cmake --build "$OUT" --target jxl-harness cjxl -j"$NCPU" >/dev/null

"$HERE/pin-check.sh" "$TARGET_DIR"
echo "Built $OUT/jxl-harness and $OUT/libjxl/tools/cjxl"
