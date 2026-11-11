#!/usr/bin/env python3
"""Crop an 8-bit binary PPM without a color conversion or image dependency."""
import re, sys
from pathlib import Path
source, output, *bounds = sys.argv[1:]
x, y, width, height = map(int, bounds)
data = Path(source).read_bytes()
match = re.match(rb'P6\s+(\d+)\s+(\d+)\s+255[ \t\r\n]', data)
if not match:
    raise ValueError("expected 8-bit P6 PPM")
sw, sh = map(int, match.groups())
pixels = data[match.end():]
if len(pixels) != sw * sh * 3 or not (0 <= x < x+width <= sw and 0 <= y < y+height <= sh):
    raise ValueError("invalid raster length or crop bounds")
raster = b''.join(pixels[((y+row)*sw+x)*3:((y+row)*sw+x+width)*3] for row in range(height))
Path(output).write_bytes(f'P6\n{width} {height}\n255\n'.encode()+raster)
