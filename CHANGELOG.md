# @germ-network/jxl-encoder-swift

## 0.2.1

### Patch Changes

- [#11](https://github.com/germ-network/jxl-encoder-swift/pull/11) [`1cbd2fa`](https://github.com/germ-network/jxl-encoder-swift/commit/1cbd2fa9fba28cf0ac7cf780fdcd5b71d0f33dc8) Thanks [@germ-mark](https://github.com/germ-mark)! - Bake EXIF orientation on the JPEG recompression path.

  `encode(data:)` re-coded a JPEG from its coefficients when no `maxPixelSize` was
  given, a path that never read EXIF orientation — so a rotated source encoded
  unrotated at full size while its thumbnail (decoded through the
  transform-applying pixel path) baked upright. The two disagreed. The
  coefficient-domain fast path now declines a non-identity EXIF orientation and
  falls through to the pixel path, which bakes it, honouring the contract: EXIF
  orientation baked into pixels, no orientation metadata in the output.

  Behaviour change: a large (>~14 MP) JPEG carrying a non-identity orientation now
  takes the pixel path at full size and is subject to `maxSourceBytes`, so it can
  be refused where it previously recompressed regardless of size. Upright JPEGs
  are unaffected and still recompress.

## 0.2.0

### Minor Changes

- [#8](https://github.com/germ-network/jxl-encoder-swift/pull/8) [`fed585e`](https://github.com/germ-network/jxl-encoder-swift/commit/fed585e34106ccee0f969b19c54b1a3cd41eb3c9) Thanks [@germ-mark](https://github.com/germ-mark)! - Retargeted the encoder to match `cjxl -e 4` exactly, replacing the prior goal
  of byte-identity with `libjxl-tiny`.

  - Ported ANS entropy coding and DCT8 coefficient reordering, and cluster the
    full context space instead of `libjxl-tiny`'s eight-bucket ceiling.
  - Replaced `libjxl-tiny`'s adaptive quantization field — never run by `cjxl`
    at this speed tier — with the uniform field and calibration constants full
    `libjxl` actually uses there. `AdaptiveQuant`/`AdaptiveQuantTile` are
    deleted; nothing in the port computes an adaptive quant field anymore.
  - Verified, not assumed, that the pixel path's chroma-from-luma output
    already matches `cjxl -e 4`'s own default correlation map — `libjxl-tiny`'s
    dropped-CfL literals happen to equal full `libjxl`'s default, which this
    release makes an explicit, tested invariant rather than a coincidence
    nobody checked.

  Measured against the actual `cjxl -e 4` binary (not `libjxl-tiny`, and not a
  higher-effort `cjxl` run): on five real photographs, pixel-path output now
  lands within 0.4–2.8% of `-e 4`'s size and within 0.7 ssimulacra2 points of
  its quality, down from a 4.9–8.2 point gap against that same `-e 4` target
  before this release (the port's older, larger-sounding 3.5–8.0 point figure
  was against `-e 7`, a different and stricter comparison, not `-e 4`). JPEG
  recompression lands within 6.7–7.3% of `-e 4`'s size, down from roughly
  18–19%.

## 0.1.0

### Minor Changes

- [`55fc9c3`](https://github.com/germ-network/jxl-encoder-swift/commit/55fc9c3e8b6d194fd28bdd0a88c947dbb53efc0c) Thanks [@germ-mark](https://github.com/germ-mark)! - First tagged release.

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
