#!/usr/bin/env python3
"""Rebuilds Display-P3.icc with its 'desc' text repeated N times.

Usage: make_desc_icc.py <Display-P3.icc> <N> <out.icc> [seed prefix suffix]

The 'desc' mluc keeps one enUS record whose UTF-16BE text is "Display P3"
repeated N times. With a seed, `prefix` printable ASCII characters from a
fixed 64-bit LCG (which do not compress) come before the repeats and `suffix`
more after them. Tag data is laid out again in the original table order, each
tag at the next 4-byte boundary, so tags that share data (the TRC curves) keep
sharing it. The v4 profile ID is recomputed (MD5 over the profile with the
flags, rendering intent and ID fields zeroed). N=1 must reproduce the input
byte for byte.
"""
import hashlib
import struct
import sys


def random_text(count: int, state: int):
    out = []
    for _ in range(count):
        state = (state * 6364136223846793005 + 1442695040888963407) % (1 << 64)
        out.append(chr(0x20 + (state >> 33) % 95))
    return "".join(out), state


def rebuild(src: bytes, repeat: int, seed=None, prefix: int = 0, suffix: int = 0) -> bytes:
    count = struct.unpack(">I", src[128:132])[0]
    tags = [struct.unpack(">4sII", src[132 + 12 * i:144 + 12 * i]) for i in range(count)]

    head, state = random_text(prefix, seed or 0)
    tail, _ = random_text(suffix, state)
    text = (head + "Display P3" * repeat + tail).encode("utf-16-be")
    mluc = (b"mluc" + struct.pack(">III", 0, 1, 12) + b"enUS"
            + struct.pack(">II", len(text), 28) + text)

    data = bytearray()
    placed = {}
    table = []
    first = 132 + 12 * count
    for sig, offset, size in tags:
        if sig == b"desc":
            body = mluc
        else:
            body = src[offset:offset + size]
        key = (sig == b"desc", offset, size)
        if key not in placed:
            while (first + len(data)) % 4:
                data.append(0)
            placed[key] = (first + len(data), len(body))
            data += body
        table.append((sig, *placed[key]))
    while (first + len(data)) % 4:
        data.append(0)

    out = bytearray(src[:128])
    struct.pack_into(">I", out, 0, first + len(data))
    out += struct.pack(">I", count)
    for sig, offset, size in table:
        out += struct.pack(">4sII", sig, offset, size)
    out += data

    scratch = bytearray(out)
    scratch[44:48] = bytes(4)
    scratch[64:68] = bytes(4)
    scratch[84:100] = bytes(16)
    out[84:100] = hashlib.md5(scratch).digest()
    return bytes(out)


def main() -> None:
    source, repeat, destination = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    original = open(source, "rb").read()
    if rebuild(original, 1) != original:
        sys.exit("N=1 does not reproduce the input profile")
    seed, prefix, suffix = (int(v) for v in sys.argv[4:7]) if len(sys.argv) > 4 else (0, 0, 0)
    open(destination, "wb").write(rebuild(original, repeat, seed, prefix, suffix))


if __name__ == "__main__":
    main()
