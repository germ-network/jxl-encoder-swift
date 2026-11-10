#!/usr/bin/env bash
# Verifies that the libjxl checkout matches the pin record exactly and prints
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

if [ ! -d "$TARGET_DIR" ]; then
	echo "PIN DRIFT: target directory does not exist: $TARGET_DIR" >&2
	exit 1
fi

# 1. HEAD must equal LIBJXL_COMMIT
CURRENT_HEAD="$(git -C "$TARGET_DIR" rev-parse HEAD 2>/dev/null || echo "unknown")"
if [ "$CURRENT_HEAD" != "$LIBJXL_COMMIT" ]; then
	echo "PIN DRIFT: HEAD expected $LIBJXL_COMMIT got $CURRENT_HEAD" >&2
	exit 1
fi

# 2. Tag must exist and resolve to LIBJXL_COMMIT
TAG_COMMIT="$(git -C "$TARGET_DIR" rev-parse -q --verify "refs/tags/$LIBJXL_TAG^{commit}" 2>/dev/null || true)"
if [ -z "$TAG_COMMIT" ]; then
	TAG_COMMIT="$(git -C "$TARGET_DIR" rev-parse -q --verify "refs/tags/$LIBJXL_TAG" 2>/dev/null || true)"
fi
if [ -z "$TAG_COMMIT" ]; then
	echo "PIN DRIFT: tag $LIBJXL_TAG absent" >&2
	exit 1
fi
if [ "$TAG_COMMIT" != "$LIBJXL_COMMIT" ]; then
	echo "PIN DRIFT: tag $LIBJXL_TAG expected $LIBJXL_COMMIT got $TAG_COMMIT" >&2
	exit 1
fi

# 3. Submodule pins cross-checked against libjxl's ls-tree
declare -a SUBMODULE_PATHS=("third_party/highway" "third_party/brotli" "third_party/skcms" "testdata")
declare -a SUBMODULE_COMMITS=("$HIGHWAY_COMMIT" "$BROTLI_COMMIT" "$SKCMS_COMMIT" "$TESTDATA_COMMIT")

for i in "${!SUBMODULE_PATHS[@]}"; do
	subpath="${SUBMODULE_PATHS[$i]}"
	expected="${SUBMODULE_COMMITS[$i]}"

	tree_commit="$(git -C "$TARGET_DIR" ls-tree "$LIBJXL_COMMIT" "$subpath" 2>/dev/null | awk '{print $3}')"
	if [ "$tree_commit" != "$expected" ]; then
		echo "PIN DRIFT: ls-tree $subpath expected $expected got $tree_commit" >&2
		exit 1
	fi
done

# 4. Submodules initialized and at expected commits
sub_status="$(git -C "$TARGET_DIR" submodule status "${SUBMODULE_PATHS[@]}")"
while IFS= read -r line; do
	[ -n "$line" ] || continue
	if [[ "$line" =~ ^- ]]; then
		echo "PIN DRIFT: submodule uninitialized: $line" >&2
		exit 1
	fi
done <<< "$sub_status"

for i in "${!SUBMODULE_PATHS[@]}"; do
	subpath="${SUBMODULE_PATHS[$i]}"
	expected="${SUBMODULE_COMMITS[$i]}"
	actual="$(git -C "$TARGET_DIR/$subpath" rev-parse HEAD 2>/dev/null || echo "uninitialized")"
	if [ "$actual" != "$expected" ]; then
		echo "PIN DRIFT: submodule $subpath expected $expected got $actual" >&2
		exit 1
	fi
done

# 5. Tree or submodule dirty
dirty="$(git -C "$TARGET_DIR" status --porcelain --ignore-submodules=none)"
if [ -n "$dirty" ]; then
	echo "PIN DRIFT: tree or submodule dirty" >&2
	echo "$dirty" >&2
	exit 1
fi

# Report
echo "=== libjxl reference revision and configuration report ==="
echo "libjxl: $LIBJXL_TAG ($LIBJXL_COMMIT)"
for i in "${!SUBMODULE_PATHS[@]}"; do
	echo "submodule ${SUBMODULE_PATHS[$i]}: ${SUBMODULE_COMMITS[$i]}"
done
echo "cmake release flags: $CMAKE_FLAGS_RELEASE"
echo "cmake debug flags: $CMAKE_FLAGS_DEBUG"
echo "cmake: $(cmake --version 2>/dev/null | head -n 1)"
echo "clang: $(clang --version 2>/dev/null | head -n 1)"
echo "uname -m: $(uname -m)"
echo "system libraries:"
if command -v brew >/dev/null 2>&1; then
	brew list --versions little-cms2 libpng jpeg-turbo 2>/dev/null || true
elif command -v pkg-config >/dev/null 2>&1; then
	pkg-config --modversion lcms2 libpng libjpeg 2>/dev/null || true
fi
