#!/usr/bin/env python3
"""Generates the XYB differential-test fixture.

Deliberately includes values a photograph never produces — exact zero (which
the fast cube root special-cases), negatives (clamped before the cube root),
and out-of-gamut values above 1.0.
"""
import struct, sys, math

W = H = 32

def pixels():
    rows = []
    for y in range(H):
        row = []
        for x in range(W):
            if y == 0:
                row.append((0.0, 0.0, 0.0))                    # exact zero
            elif y == 1:
                row.append((1.0, 1.0, 1.0))                    # white
            elif y == 2:
                row.append((-0.05, -0.01, -0.2))               # negative / out of gamut
            elif y == 3:
                row.append((4.0, 2.5, 3.0))                    # above 1.0
            elif y == 4:
                row.append((1e-8, 1e-7, 1e-9))                 # near zero
            elif y == 5:
                g = x / (W - 1)
                row.append((g, g, g))                          # neutral: X must be 0
            elif y == 6:
                row.append((1.0, 0.0, 0.0))                    # saturated primaries
            elif y == 7:
                row.append((0.0, 1.0, 0.0))
            elif y == 8:
                row.append((0.0, 0.0, 1.0))
            else:
                row.append((
                    (x / W) ** 2,
                    abs(math.sin(x * 0.4 + y * 0.2)),
                    (y / H) ** 1.5,
                ))
        rows.append(row)
    return rows

with open(sys.argv[1], 'wb') as f:
    f.write(b"PF\n%d %d\n-1.0\n" % (W, H))
    for row in reversed(pixels()):       # PFM is bottom-to-top
        for (r, g, b) in row:
            f.write(struct.pack('<fff', r, g, b))
print(f"wrote {sys.argv[1]} ({W}x{H})")
