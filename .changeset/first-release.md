---
"@germ-network/jxl-encoder-swift": minor
---

First tagged release.

A lossy JPEG XL encoder in pure Swift — no `Unsafe*`, no C or C++ — ported from
libjxl-tiny. Apple platforms decode JPEG XL but ship no encoder, so this fills
that gap for callers that cannot take on libjxl's size or its unsafe code.

- `JXLEncoder`, the portable core, is Swift stdlib only; Linux CI keeps it that
  way so an Android shim can consume it unchanged.
- `JXLEncoderApple` decodes any ImageIO-supported input, caps thumbnails by
  longest edge, and applies an alpha policy.
- JPEG input takes a coefficient-domain recompression path, so re-encoding a
  JPEG carries no generation of loss. Anything the parser declines — progressive,
  arithmetic-coded, 4:1:1 — falls back to the pixel path.
- Whole-file output is byte-identical to `cjxl_tiny -d 1.0` across the test
  corpus, which is what the port is gated on.
