#!/usr/bin/env bash
# Regenerates the JPEG parser fixtures and their libjpeg reference dumps.
#
# Everything derives from hopper_420_restart.jpg, the one fixture that is not
# generated: a camera-style 4:2:0 file with restart markers, kept as-is so at
# least one test input is untouched by our own tooling.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE="$HERE/../Tests/JXLEncoderTests/Fixtures"
APPLE="$HERE/../Tests/JXLEncoderAppleTests/Fixtures"
OUT="$HERE/build"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

JPEG_PREFIX="${JPEG_PREFIX:-/opt/homebrew}"
mkdir -p "$OUT"
cc -O2 -I"$JPEG_PREFIX/include" "$HERE/tools/dump_jpeg_coefficients.c" \
	-L"$JPEG_PREFIX/lib" -ljpeg -o "$OUT/dump_jpeg_coefficients"

djpeg -ppm -outfile "$WORK/full.ppm" "$CORE/hopper_420_restart.jpg"
python3 - "$WORK" <<'PY'
import sys
work = sys.argv[1]
data = open(f"{work}/full.ppm", "rb").read()
start = data.index(b"255\n") + 4
pixels, width = data[start:], 200

def crop(x0, y0, w, h, name):
	out = bytearray()
	for y in range(h):
		row = (y0 + y) * width * 3 + x0 * 3
		out += pixels[row:row + w * 3]
	open(f"{work}/{name}.ppm", "wb").write(b"P6\n%d %d\n255\n" % (w, h) + bytes(out))

crop(40, 30, 101, 67, "odd")    # not a multiple of an MCU in either direction
crop(60, 50, 37, 23, "small")   # small enough for a coefficient dump per subsampling
crop(0, 0, 32, 32, "tiny")      # only used for the rejection cases
PY

# Baseline, one per sampling arrangement the parser has to handle. 1x2 is the
# transpose of 2x1 and is what catches a swapped horizontal/vertical factor.
cjpeg -quality 90 -sample 1x1 -outfile "$CORE/small_444.jpg" "$WORK/small.ppm"
cjpeg -quality 90 -sample 2x1 -outfile "$CORE/small_422.jpg" "$WORK/small.ppm"
cjpeg -quality 90 -sample 1x2 -outfile "$CORE/small_440.jpg" "$WORK/small.ppm"
cjpeg -quality 90 -sample 4x1 -outfile "$CORE/small_411.jpg" "$WORK/small.ppm"
cjpeg -quality 85 -sample 2x2 -restart 3 -outfile "$CORE/hopper_420_odd.jpg" "$WORK/odd.ppm"
cjpeg -quality 85 -grayscale -outfile "$CORE/hopper_gray_odd.jpg" "$WORK/odd.ppm"
# Quality 2 pushes the quantization tables past 255, which forces 16-bit DQT
# entries and, with them, an extended-sequential SOF1 frame.
cjpeg -quality 2 -sample 2x2 -outfile "$CORE/hopper_420_sof1.jpg" "$WORK/full.ppm"

cjpeg -quality 80 -progressive -outfile "$CORE/reject_progressive.jpg" "$WORK/tiny.ppm"
cjpeg -quality 80 -arithmetic -outfile "$CORE/reject_arithmetic.jpg" "$WORK/tiny.ppm"
cjpeg -lossless 1 -outfile "$CORE/reject_lossless.jpg" "$WORK/tiny.ppm"

for name in small_444 small_422 small_440 small_411 hopper_420_odd hopper_gray_odd; do
	"$OUT/dump_jpeg_coefficients" "$CORE/$name.jpg" "$CORE/$name.coef"
done

# The cross-check against ImageIO needs the pictures, not the dumps.
cjpeg -quality 88 -sample 1x1 -outfile "$APPLE/hopper_444.jpg" "$WORK/full.ppm"
cjpeg -quality 85 -sample 2x1 -outfile "$APPLE/hopper_422.jpg" "$WORK/full.ppm"
cjpeg -quality 95 -sample 4x1 -outfile "$APPLE/hopper_411.jpg" "$WORK/full.ppm"
cp "$CORE/hopper_420_restart.jpg" "$CORE/hopper_420_odd.jpg" \
	"$CORE/hopper_gray_odd.jpg" "$CORE/hopper_420_sof1.jpg" "$APPLE/"

echo "fixtures regenerated"
