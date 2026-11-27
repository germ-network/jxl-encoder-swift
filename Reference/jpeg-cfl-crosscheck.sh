#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HARNESS="${JXL_CFL_HARNESS:-$HERE/build/harness/jxl-harness}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

cd "$ROOT"
JXL_CFL_EXPORT_DIR="$OUT" swift test --scratch-path plans/.build \
	--filter JPEGCfLIntegrationTests.actualJPEGCfLSerializationCrossCheck
JXL_RGB_EXPORT_DIR="$OUT" swift test --skip-build --scratch-path plans/.build \
	--filter JPEGCfLIntegrationTests.actualRGBJPEGSerializationCrossCheck
for name in small_444 cfl_endpoint_444 cfl_tile_65x8 small_422 hopper_gray_odd; do
	for suffix in optimized; do
		echo "Checking $name $suffix"
		"$HARNESS" jpeg-witness "Tests/JXLEncoderTests/Fixtures/$name.jpg" \
			"$OUT/$name-$suffix.jxl" >"$OUT/$name-$suffix.cfl.sem"
	done
done
for name in rgb_color rgb_coded_dc; do
	for suffix in optimized; do
		echo "Checking $name $suffix"
		"$HARNESS" jpeg-witness "Tests/JXLEncoderTests/Fixtures/$name.jpg" \
			"$OUT/$name-$suffix.jxl" >"$OUT/$name-$suffix.rgb.sem"
	done
done
JXL_CFL_CHECK_DIR="$OUT" swift test --skip-build \
	--scratch-path plans/.build \
	--filter JPEGCfLIntegrationTests.actualJPEGCfLSerializationCrossCheck
JXL_RGB_CHECK_DIR="$OUT" swift test --skip-build --scratch-path plans/.build \
	--filter JPEGCfLIntegrationTests.actualRGBJPEGSerializationCrossCheck
echo 'PASS actual Swift JPEG CfL maps and coefficient recovery cross-check'
