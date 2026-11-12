#!/usr/bin/env python3
"""Writes a deterministic P6 image spanning two DC groups and a partial edge."""
from pathlib import Path
import sys

path = Path(sys.argv[1])
width, height = 2057, 521
with path.open("wb") as output:
    output.write(f"P6\n{width} {height}\n255\n".encode())
    row = bytearray(width * 3)
    for y in range(height):
        for x in range(width):
            base = (x * 17 + y * 29 + (x * y) % 251) % 256
            row[3 * x] = base
            row[3 * x + 1] = (base + x * 3 + y * 5) % 256
            row[3 * x + 2] = (base + x * 7 + y * 11) % 256
        output.write(row)
