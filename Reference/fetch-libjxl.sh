#!/usr/bin/env bash
# Fetches the pinned libjxl repository and its required submodules,
# checks out the pinned commit detached, and runs pin-check.
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

mkdir -p "$TARGET_DIR"

if [ ! -d "$TARGET_DIR/.git" ]; then
	git -C "$TARGET_DIR" init
fi

# Fetch commit and tag
git -C "$TARGET_DIR" fetch --depth 1 "$LIBJXL_URL" "$LIBJXL_COMMIT"
git -C "$TARGET_DIR" fetch --depth 1 "$LIBJXL_URL" --force tag "$LIBJXL_TAG"
git -C "$TARGET_DIR" checkout --detach "$LIBJXL_COMMIT"

# Submodule initialization for highway, brotli, skcms, testdata only
for m in third_party/highway third_party/brotli third_party/skcms testdata; do
	if ! git -C "$TARGET_DIR" submodule update --init --depth 1 "$m"; then
		echo "Shallow submodule fetch failed for $m, retrying without --depth..."
		git -C "$TARGET_DIR" submodule update --init "$m"
	fi
done

# Run pin-check
"$HERE/pin-check.sh" "$TARGET_DIR"
