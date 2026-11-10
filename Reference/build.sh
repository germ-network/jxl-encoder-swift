#!/usr/bin/env bash
# Builds the pinned full libjxl reference binaries (cjxl, djxl) and writes
# the revision and configuration report.
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
OUT="$HERE/build"

# Fetch if missing
if [ ! -d "$TARGET_DIR/.git" ]; then
	echo "Target directory $TARGET_DIR not found; fetching..."
	"$HERE/fetch-libjxl.sh" "$TARGET_DIR"
fi

# Pre-build pin check
"$HERE/pin-check.sh" "$TARGET_DIR"

NCPU="$(sysctl -n hw.ncpu 2>/dev/null || nproc)"

# Release build: cjxl and djxl
echo "Building libjxl Release (cjxl, djxl)..."
# shellcheck disable=SC2086
cmake -S "$TARGET_DIR" -B "$TARGET_DIR/build" $CMAKE_FLAGS_RELEASE >/dev/null
cmake --build "$TARGET_DIR/build" --target cjxl djxl -j"$NCPU" >/dev/null

# Debug build: djxl
echo "Building libjxl Debug (djxl)..."
# shellcheck disable=SC2086
cmake -S "$TARGET_DIR" -B "$TARGET_DIR/build-dbg" $CMAKE_FLAGS_DEBUG >/dev/null
cmake --build "$TARGET_DIR/build-dbg" --target djxl -j"$NCPU" >/dev/null

# Copy binaries to Reference/build/
mkdir -p "$OUT"
cp "$TARGET_DIR/build/tools/cjxl" "$OUT/cjxl"
cp "$TARGET_DIR/build/tools/djxl" "$OUT/djxl"
cp "$TARGET_DIR/build-dbg/tools/djxl" "$OUT/djxl-dbg"
echo "Copied cjxl, djxl, and djxl-dbg to $OUT"

# Post-build pin check
"$HERE/pin-check.sh" "$TARGET_DIR"

# Write revision report to Reference/build/REVISION.txt
REPORT="$("$HERE/pin-check.sh" "$TARGET_DIR")"
{
	echo "$REPORT"
	echo "resolved cmake libraries (Release):"
	grep -E '^(JPEG|PNG|LCMS2)[^:]*:(FILEPATH|PATH)=' "$TARGET_DIR/build/CMakeCache.txt" 2>/dev/null | grep -v 'NOTFOUND' || true
	echo "resolved cmake libraries (Debug):"
	grep -E '^(JPEG|PNG|LCMS2)[^:]*:(FILEPATH|PATH)=' "$TARGET_DIR/build-dbg/CMakeCache.txt" 2>/dev/null | grep -v 'NOTFOUND' || true
} > "$OUT/REVISION.txt"

echo "Report written to $OUT/REVISION.txt"
