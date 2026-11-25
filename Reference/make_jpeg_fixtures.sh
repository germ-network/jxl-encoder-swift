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
if [ -d "$JPEG_PREFIX/bin" ]; then
	PATH="$JPEG_PREFIX/bin:$PATH"
fi

PIN_FILE="$HERE/libjxl.pin"
if [ ! -f "$PIN_FILE" ]; then
	echo "Error: $PIN_FILE not found" >&2
	exit 1
fi
# shellcheck source=Reference/libjxl.pin
. "$PIN_FILE"

if [ -z "${JPEG_TURBO_VERSION:-}" ]; then
	echo "Error: JPEG_TURBO_VERSION is not defined in $PIN_FILE" >&2
	exit 1
fi

CJPEG_OUTPUT="$(cjpeg -version 2>&1 || true)"
if [[ "$CJPEG_OUTPUT" != *"version $JPEG_TURBO_VERSION"* ]]; then
	echo "Error: cjpeg version mismatch. Pinned: $JPEG_TURBO_VERSION, found: $CJPEG_OUTPUT" >&2
	exit 1
fi

JCONFIG_H="$JPEG_PREFIX/include/jconfig.h"
if [ ! -f "$JCONFIG_H" ]; then
	echo "Error: $JCONFIG_H not found under $JPEG_PREFIX" >&2
	exit 1
fi

HEADER_VERSION="$(grep -E '^#define[[:space:]]+LIBJPEG_TURBO_VERSION[[:space:]]+' "$JCONFIG_H" | awk '{print $3}' | tr -d '"\r')"
if [ "$HEADER_VERSION" != "$JPEG_TURBO_VERSION" ]; then
	echo "Error: jconfig.h LIBJPEG_TURBO_VERSION mismatch. Pinned: $JPEG_TURBO_VERSION, found: $HEADER_VERSION" >&2
	exit 1
fi

echo "Using libjpeg-turbo $JPEG_TURBO_VERSION ($CJPEG_OUTPUT, jconfig.h: $HEADER_VERSION)"

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
crop(0, 0, 199, 197, "odd_420") # larger odd 4:2:0 crop for pixel acceptance
crop(60, 50, 37, 23, "small")   # small enough for a coefficient dump per subsampling
crop(0, 0, 32, 32, "tiny")      # only used for the rejection cases
PY

# Baseline, one per sampling arrangement the parser has to handle. 1x2 is the
# transpose of 2x1 and is what catches a swapped horizontal/vertical factor.
cjpeg -quality 90 -sample 1x1 -outfile "$CORE/small_444.jpg" "$WORK/small.ppm"
cjpeg -quality 90 -sample 2x1 -outfile "$CORE/small_422.jpg" "$WORK/small.ppm"
cjpeg -quality 90 -sample 1x2 -outfile "$CORE/small_440.jpg" "$WORK/small.ppm"
python3 - "$WORK/colors.ppm" <<'PY'
import sys
width = height = 192
colors = [
    (255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0),
    (255, 0, 255), (0, 255, 255), (240, 64, 16), (32, 96, 240),
    (255, 96, 0), (64, 0, 255), (0, 160, 64), (192, 0, 96),
    (255, 255, 255), (0, 0, 0), (128, 128, 128), (64, 128, 192),
]
pixels = bytearray()
for y in range(height):
    for x in range(width):
        pixels.extend(colors[(y // 48) * 4 + x // 48])
with open(sys.argv[1], "wb") as output:
    output.write(b"P6\n192 192\n255\n" + pixels)
PY
cjpeg -rgb -quality 90 -outfile "$CORE/rgb_color.jpg" "$WORK/colors.ppm"
python3 - "$WORK/rgb-witness.ppm" "$WORK/rgb-witness.qtables" <<'PY'
import sys

width = height = 64
pixels = bytearray()
for y in range(height):
    for x in range(width):
        red = (17 + 3 * x + 5 * y + 7 * ((x * y) % 19)) & 255
        green = (29 + 2 * red + 3 * y + (x * x) % 23) & 255
        blue = (11 + red + 2 * green + 5 * x) & 255
        pixels.extend((red, green, blue))
with open(sys.argv[1], "wb") as output:
    output.write(b"P6\n64 64\n255\n" + pixels)

with open(sys.argv[2], "w") as output:
    for channel, q00 in enumerate((3, 5, 7)):
        values = [q00 + ((i * (channel + 3) + (i // 8) * (channel + 2)) % 29)
                  for i in range(64)]
        values[0] = q00
        output.write(",".join(map(str, values)) + "\n")
PY
cjpeg -rgb -qtables "$WORK/rgb-witness.qtables" -qslots 0,1,2 \
	-outfile "$CORE/rgb_coded_dc.jpg" "$WORK/rgb-witness.ppm"
cjpeg -quality 90 -icc "$HERE/fixtures/Display-P3.icc" -outfile "$CORE/display_p3_profile.jpg" "$WORK/colors.ppm"
cjpeg -rgb -quality 90 -icc "$HERE/fixtures/Display-P3.icc" -outfile "$CORE/rgb_p3_profile.jpg" "$WORK/colors.ppm"
# Repeated-desc rebuilds of Display-P3.icc (make_desc_icc.py): N=4 is the
# smallest that enables LZ77 in the coded ICC, N=3300 exceeds one APP2 chunk
# and the 16,384-byte kLZ77 switch.
python3 "$HERE/make_desc_icc.py" "$HERE/fixtures/Display-P3.icc" 4 "$HERE/fixtures/Display-P3-desc4.icc"
python3 "$HERE/make_desc_icc.py" "$HERE/fixtures/Display-P3.icc" 3300 "$HERE/fixtures/Display-P3-desc3300.icc"
cjpeg -quality 90 -sample 2x2 -icc "$HERE/fixtures/Display-P3-desc4.icc" -outfile "$CORE/p3_desc4_profile.jpg" "$WORK/colors.ppm"
cjpeg -quality 90 -sample 2x2 -icc "$HERE/fixtures/Display-P3-desc3300.icc" -outfile "$CORE/p3_desc3300_profile_420.jpg" "$WORK/colors.ppm"
cjpeg -quality 90 -sample 4x1 -outfile "$CORE/small_411.jpg" "$WORK/small.ppm"
cjpeg -quality 85 -sample 2x2 -restart 3 -outfile "$CORE/hopper_420_odd.jpg" "$WORK/odd.ppm"
cjpeg -quality 85 -grayscale -outfile "$CORE/hopper_gray_odd.jpg" "$WORK/odd.ppm"
cp "$CORE/hopper_gray_odd.jpg" "$CORE/hopper_gray_2x2_odd.jpg"
python3 - "$CORE/hopper_gray_2x2_odd.jpg" <<'PY'
import sys
path = sys.argv[1]
data = bytearray(open(path, "rb").read())
frame = next(i for i in range(2, len(data) - 1) if data[i] == 0xFF and data[i + 1] in (0xC0, 0xC1))
data[frame + 4 + 6 + 1] = 0x22
open(path, "wb").write(data)
PY
# Sequential scan partitions exercise interleaved and non-interleaved MCU grids.
printf '2; 0; 1;\n' > "$WORK/scans_111.txt"
printf '0 1; 2;\n' > "$WORK/scans_21.txt"
printf '1; 0 2;\n' > "$WORK/scans_12.txt"
cjpeg -quality 85 -sample 2x2 -scans "$WORK/scans_111.txt" -outfile "$CORE/scan_420_111.jpg" "$WORK/odd_420.ppm"
cjpeg -quality 85 -sample 2x2 -restart 1B -scans "$WORK/scans_111.txt" -outfile "$CORE/scan_420_111_restart.jpg" "$WORK/odd_420.ppm"
cjpeg -quality 85 -sample 2x1 -scans "$WORK/scans_21.txt" -outfile "$CORE/scan_422_21.jpg" "$WORK/odd.ppm"
cjpeg -quality 85 -sample 1x2 -scans "$WORK/scans_12.txt" -outfile "$CORE/scan_440_12.jpg" "$WORK/odd.ppm"
# Build a T.81 table-replacement source and an equivalent stable-destination
# JPEG. The entropy and component coefficients are identical in both files.
python3 - "$CORE/scan_420_111.jpg" "$CORE/scan_420_111_dqt_redefined.jpg" <<'PY'
import sys

source = bytearray(open(sys.argv[1], "rb").read())

def sos_positions(data):
    positions = []
    pos = 2
    while pos + 3 < len(data):
        if data[pos] != 0xFF:
            raise ValueError("expected marker")
        start = pos
        while data[pos] == 0xFF:
            pos += 1
        marker = data[pos]
        pos += 1
        if marker == 0xD9:
            break
        if marker == 0xDA:
            positions.append(start)
        length = (data[pos] << 8) | data[pos + 1]
        pos += length
        if marker != 0xDA:
            continue
        while pos + 1 < len(data):
            if data[pos] != 0xFF:
                pos += 1
                continue
            code = data[pos + 1]
            if code == 0 or 0xD0 <= code <= 0xD7:
                pos += 2
                continue
            break
    return positions

first_sos = sos_positions(source)[0]
tables = {}
pos = 2
while pos < first_sos:
    marker = source[pos + 1]
    length = (source[pos + 2] << 8) | source[pos + 3]
    end = pos + 2 + length
    if marker == 0xDB:
        cursor = pos + 4
        while cursor < end:
            header = source[cursor]
            cursor += 1
            precision, destination = header >> 4, header & 15
            size = 64 * (precision + 1)
            tables[destination] = bytes([header]) + bytes(source[cursor:cursor + size])
            cursor += size
    pos = end
if 0 not in tables or 1 not in tables:
    raise ValueError("expected luma and chroma DQT destinations")

def dqt(destination, definition):
    payload = bytes([(definition[0] & 0xF0) | destination]) + definition[1:]
    return bytes([0xFF, 0xDB, 0, len(payload) + 2]) + payload

# Remove initial definitions and make all components refer to one destination.
prefix = bytearray(source[:first_sos])
filtered = bytearray(prefix[:2])
pos = 2
while pos < len(prefix):
    length = (prefix[pos + 2] << 8) | prefix[pos + 3]
    end = pos + 2 + length
    if prefix[pos + 1] != 0xDB:
        filtered.extend(prefix[pos:end])
    pos = end
source = filtered + source[first_sos:]
frame = next(i for i in range(2, len(source) - 1) if source[i] == 0xFF and source[i + 1] in (0xC0, 0xC1))
frame_payload = frame + 4
component_count = source[frame_payload + 5]
for component in range(component_count):
    source[frame_payload + 6 + component * 3 + 2] = 0

scans = sos_positions(source)
if len(scans) != 3:
    raise ValueError("expected three sequential scans")
insertions = [
    (scans[0], dqt(0, tables[1])),
    (scans[1], dqt(0, tables[0])),
    (scans[2], dqt(0, tables[1])),
]
for offset, segment in reversed(insertions):
    source[offset:offset] = segment
open(sys.argv[2], "wb").write(source)
PY
# Quality 2 pushes the quantization tables past 255, which forces 16-bit DQT
# entries and, with them, an extended-sequential SOF1 frame.
cjpeg -quality 2 -sample 2x2 -outfile "$CORE/hopper_420_sof1.jpg" "$WORK/full.ppm"

cjpeg -quality 80 -progressive -outfile "$CORE/reject_progressive.jpg" "$WORK/tiny.ppm"
cjpeg -quality 80 -arithmetic -outfile "$CORE/reject_arithmetic.jpg" "$WORK/tiny.ppm"
cjpeg -lossless 1 -outfile "$CORE/reject_lossless.jpg" "$WORK/tiny.ppm"

for name in small_444 small_422 small_440 small_411 hopper_420_odd hopper_gray_odd hopper_gray_2x2_odd \
	scan_420_111 scan_420_111_restart scan_422_21 scan_440_12; do
	"$OUT/dump_jpeg_coefficients" "$CORE/$name.jpg" "$CORE/$name.coef"
done
cp "$CORE/scan_420_111.jpg" "$CORE/scan_420_111_dqt_canonical.jpg"
python3 - "$CORE/scan_420_111_dqt_canonical.jpg" <<'PY'
import sys
path = sys.argv[1]
data = bytearray(open(path, "rb").read())
pos = next(i for i in range(2, len(data) - 1) if data[i] == 0xFF and data[i + 1] in (0xC0, 0xC1))
payload = pos + 4
for component, destination in enumerate((0, 1, 1)):
    data[payload + 6 + component * 3 + 2] = destination
open(path, "wb").write(data)
PY
"$OUT/dump_jpeg_coefficients" "$CORE/scan_420_111_dqt_canonical.jpg" "$CORE/scan_420_111_dqt_canonical.coef"
djpeg -ppm -outfile "$WORK/dqt-original.ppm" "$CORE/scan_420_111_dqt_redefined.jpg"
djpeg -ppm -outfile "$WORK/dqt-canonical.ppm" "$CORE/scan_420_111_dqt_canonical.jpg"
cmp "$WORK/dqt-original.ppm" "$WORK/dqt-canonical.ppm"

cp "$CORE/rgb_color.jpg" "$APPLE/rgb_color.jpg"
cp "$CORE/display_p3_profile.jpg" "$APPLE/display_p3_profile.jpg"
cp "$CORE/rgb_p3_profile.jpg" "$APPLE/rgb_p3_profile.jpg"

# The cross-check against ImageIO needs the pictures, not the dumps.
cjpeg -quality 88 -sample 1x1 -outfile "$APPLE/hopper_444.jpg" "$WORK/full.ppm"
cjpeg -quality 85 -sample 2x1 -outfile "$APPLE/hopper_422.jpg" "$WORK/full.ppm"
cjpeg -quality 95 -sample 4x1 -outfile "$APPLE/hopper_411.jpg" "$WORK/full.ppm"
cp "$CORE/hopper_420_restart.jpg" "$CORE/hopper_420_odd.jpg" \
	"$CORE/hopper_gray_odd.jpg" "$CORE/hopper_420_sof1.jpg" \
	"$CORE/hopper_gray_2x2_odd.jpg" \
	"$CORE/small_422.jpg" "$CORE/small_440.jpg" "$CORE/small_444.jpg" \
	"$CORE/reject_arithmetic.jpg" "$CORE/reject_progressive.jpg" \
	"$CORE/scan_420_111.jpg" "$CORE/scan_420_111_restart.jpg" \
	"$CORE/scan_422_21.jpg" "$CORE/scan_440_12.jpg" \
	"$APPLE/"
cp "$CORE/scan_420_111_dqt_redefined.jpg" "$APPLE/"
cp "$CORE/scan_420_111_dqt_canonical.jpg" "$APPLE/"

echo "fixtures regenerated"
