# @germ-network/jxl-encoder-swift

## 0.4.1

### Patch Changes

- [#53](https://github.com/germ-network/jxl-encoder-swift/pull/53) [`b8163a9`](https://github.com/germ-network/jxl-encoder-swift/commit/b8163a972f337ad91cec42ba8fb3d4f5d9d181ac) Thanks [@germ-mark-llm](https://github.com/germ-mark-llm)! - Normalize positive pixel distances below the selected libjxl minimum of 0.05 and document the accepted Swift distance surface.

- [#55](https://github.com/germ-network/jxl-encoder-swift/pull/55) [`cc36ce8`](https://github.com/germ-network/jxl-encoder-swift/commit/cc36ce8d4928120b2b2b9f99a76f45dd50d5a7de) Thanks [@germ-mark-llm](https://github.com/germ-mark-llm)! - Apply the default JPEG 4:4:4 chroma-from-luma transform while preserving source coefficients.

- [#56](https://github.com/germ-network/jxl-encoder-swift/pull/56) [`cbb8a9e`](https://github.com/germ-network/jxl-encoder-swift/commit/cbb8a9e9ebb334a0758186537f4b9017df66e4da) Thanks [@germ-mark-llm](https://github.com/germ-mark-llm)! - Add synchronous pixel encoding with bounded worker scheduling through the optional Dispatch product. Runner APIs require iOS 18 or macOS 15; existing serial and async calls remain available, and eligible JPEG recompression stays serial.

## 0.4.0

### Minor Changes

- Expand baseline JPEG ingestion to support disjoint sequential scans, scan-local restart state, and persistent padded coefficient planes.

### Compatibility

- Added `JPEGParseError.duplicateComponentIdentifier` and `.duplicateRestartInterval` cases can require downstream exhaustive switches to be updated.
- `JPEGComponent.quantTableIndex` indexes the component's bound values in `JPEGImage.quantTables`; it can exceed 3 after table redefinitions and should not be treated as the original JPEG destination identifier.
- Quantization-table redefinitions bind at each component's scan, following JPEG T.81 active-table semantics. This deliberately differs from the pinned libjxl reader's first-definition binding; see [the source and standard evidence](https://github.com/germ-network/jxl-encoder-swift/blob/v0.4.0/Reference/jpeg-quantization-binding.md).
- Grayscale coefficient storage uses padded block strides. Grayscale sampling factors 3 and 4 now decline coefficient recompression: `Encoder.recompressJPEG(_:)` returns nil, while the Apple encoder falls back to decoding pixels and applies its pixel-path budget.
- Newly accepted sequential JPEGs can take coefficient recompression instead of pixel encoding. Encoded output can change across both JPEG and pixel paths.

### Patch Changes

- Serialize VarDCT Gaborish and EPF fields independently, with pixel and JPEG header verification against the selected effort-4 configuration.

- [#51](https://github.com/germ-network/jxl-encoder-swift/pull/51) [`03b45d5`](https://github.com/germ-network/jxl-encoder-swift/commit/03b45d50f6eba893c24a1e83d84e072b7fd59333) Thanks [@germ-mark-llm](https://github.com/germ-mark-llm)! - Bound generated GitHub release notes and make release creation recoverable after tag publication.

- [#45](https://github.com/germ-network/jxl-encoder-swift/pull/45) [`ba09a4b`](https://github.com/germ-network/jxl-encoder-swift/commit/ba09a4b12a8baf3de5f2529f0f8ce7fb4bef25f8) Thanks [@germ-mark](https://github.com/germ-mark)! - Match pinned libjxl e4 coefficient-order sampling and permutation entropy coding.

- [#41](https://github.com/germ-network/jxl-encoder-swift/pull/41) [`f00b64d`](https://github.com/germ-network/jxl-encoder-swift/commit/f00b64d62409dd12014a5fefd56807634e6ea434) Thanks [@germ-mark-llm](https://github.com/germ-mark-llm)! - Fall back to pixel encoding when a JPEG's RGB or ICC color interpretation cannot be preserved by coefficient recompression.

- [#46](https://github.com/germ-network/jxl-encoder-swift/pull/46) [`d98298a`](https://github.com/germ-network/jxl-encoder-swift/commit/d98298a471718f22742f2a2731b23f5d8b79ab68) Thanks [@germ-mark](https://github.com/germ-mark)! - Automatically resample high-distance pixel encodes on a globally prepared XYB grid.

- [#27](https://github.com/germ-network/jxl-encoder-swift/pull/27) [`34b5b9e`](https://github.com/germ-network/jxl-encoder-swift/commit/34b5b9ed11e2c6550f0620f34fafef6727b1072e) Thanks [@germ-mark-llm](https://github.com/germ-mark-llm)! - Preserve unsigned DC histogram bucket mapping when recompressing baseline JPEGs.

- [#28](https://github.com/germ-network/jxl-encoder-swift/pull/28) [`ef52773`](https://github.com/germ-network/jxl-encoder-swift/commit/ef527730ea5d15e690a71030ff596d11d4c731e1) Thanks [@germ-mark](https://github.com/germ-mark)! - Use the first JXL channel's transposed quantization table for JPEG block context thresholds.

- [#33](https://github.com/germ-network/jxl-encoder-swift/pull/33) [`675c6df`](https://github.com/germ-network/jxl-encoder-swift/commit/675c6df23f30928ef2690aa8d5abc2d1e34de6eb) Thanks [@germ-mark-llm](https://github.com/germ-mark-llm)! - Use libjxl's context-map entropy policy for all production context maps.

- [#40](https://github.com/germ-network/jxl-encoder-swift/pull/40) [`659ea26`](https://github.com/germ-network/jxl-encoder-swift/commit/659ea268367958e31cbe3685bdbb98f4a84bd78c) Thanks [@germ-mark-llm](https://github.com/germ-mark-llm)! - Reject non-finite distances before quantizer arithmetic.

- [#48](https://github.com/germ-network/jxl-encoder-swift/pull/48) [`94f1b26`](https://github.com/germ-network/jxl-encoder-swift/commit/94f1b266c70b8c5836f62985f68175d241ffbadc) Thanks [@germ-mark](https://github.com/germ-mark)! - Preserve source quantizer arithmetic order and safe serialization across all positive finite distances.

- [#44](https://github.com/germ-network/jxl-encoder-swift/pull/44) [`780ed8b`](https://github.com/germ-network/jxl-encoder-swift/commit/780ed8bb4d9336b5ea3ad8ed9475fb8671787592) Thanks [@germ-mark-llm](https://github.com/germ-mark-llm)! - Build JPEG Huffman lookup tables from source and enforce exact entropy boundaries.

- [#37](https://github.com/germ-network/jxl-encoder-swift/pull/37) [`99938ad`](https://github.com/germ-network/jxl-encoder-swift/commit/99938ad61f4d5b0dc6f77f5a89815a9059b626d2) Thanks [@germ-mark-llm](https://github.com/germ-mark-llm)! - Use native scalar Float arithmetic for pixel DC quantization.

- [#39](https://github.com/germ-network/jxl-encoder-swift/pull/39) [`e1dca6f`](https://github.com/germ-network/jxl-encoder-swift/commit/e1dca6f022e63332f895c8c10f4c08195de18fd6) Thanks [@germ-mark](https://github.com/germ-mark)! - Preserve InitialQuantDC's reciprocal-times-distance formula while measuring QuantDC with native Swift Float.pow.

- [#30](https://github.com/germ-network/jxl-encoder-swift/pull/30) [`118af57`](https://github.com/germ-network/jxl-encoder-swift/commit/118af57cb1fa6c2dfb48ef1b69c5ddaa3702a592) Thanks [@germ-mark-llm](https://github.com/germ-mark-llm)! - Translate e4 X matrix-scale selection and channel-specific DCT8 AC dead zones to match libjxl.

- [#33](https://github.com/germ-network/jxl-encoder-swift/pull/33) [`f3e1fe7`](https://github.com/germ-network/jxl-encoder-swift/commit/f3e1fe796db578492c6a97ba72f7a509231f6789) Thanks [@germ-mark-llm](https://github.com/germ-mark-llm)! - Preserve source-selected EPF sharpness in serialized DC metadata for JPEG and pixel encodes.

- [#43](https://github.com/germ-network/jxl-encoder-swift/pull/43) [`cad0117`](https://github.com/germ-network/jxl-encoder-swift/commit/cad0117a836a88ce9dc05d622ab888edeee84a85) Thanks [@germ-mark](https://github.com/germ-mark)! - Translate selected libjxl effort-4 modular DC preparation, folded chroma-from-luma, prediction, context trees, and per-stream entropy coding.

- [#52](https://github.com/germ-network/jxl-encoder-swift/pull/52) [`acba207`](https://github.com/germ-network/jxl-encoder-swift/commit/acba207bfc364fe3278b656f7fa0549fe81de6f2) Thanks [@germ-mark-llm](https://github.com/germ-mark-llm)! - Decode disjoint sequential JPEG scans into padded persistent coefficient planes, bind DQT redefinitions at each scan, apply scan-local restart and entropy state, and preserve grayscale sampling fallback.

  Newly accepted multi-scan inputs can produce different JPEG XL output; resolved `quantTableIndex` values can exceed 3, and added public `JPEGParseError` cases can require downstream exhaustive switches to be updated.

- [#30](https://github.com/germ-network/jxl-encoder-swift/pull/30) [`7aee1ae`](https://github.com/germ-network/jxl-encoder-swift/commit/7aee1ae1ae399d593b855e23a32a46911286c3a1) Thanks [@germ-mark-llm](https://github.com/germ-mark-llm)! - Match pinned libjxl e4 clustering costs and original-context coder selection.

- [#33](https://github.com/germ-network/jxl-encoder-swift/pull/33) [`502e162`](https://github.com/germ-network/jxl-encoder-swift/commit/502e16263773edda8ada5479013fcf8ecefd2f18) Thanks [@germ-mark-llm](https://github.com/germ-mark-llm)! - Model pixel block contexts from each frame's quant fields and use them for optimized AC tokenization and frame metadata.

## 0.3.0

### Minor Changes

- [#13](https://github.com/germ-network/jxl-encoder-swift/pull/13) [`e535e37`](https://github.com/germ-network/jxl-encoder-swift/commit/e535e37cb171a26d592e540b70e498be7bc50422) Thanks [@germ-mark](https://github.com/germ-mark)! - Expose the pieces a portable caller needs to own the input policy itself.

  - `JPEGParser.exifOrientation(_:)` reads a JPEG's EXIF orientation without decoding it.
  - `Encoder.recompressJPEG(_:)` is the coefficient-domain fast path, portable: nil for a non-JPEG or a layout the parser declines. Its output declares no orientation, so gating a rotated source is the caller's job. `JXLEncoderApple` now calls it after checking both the EXIF orientation and ImageIO's.
  - `JXLSignature.matches(_:)` recognises the bare codestream and the ISOBMFF container.
  - `JXLEncoderApple.decode(data:maxPixelSize:alphaPolicy:maxSourceBytes:)` returns the oriented, downscaled, budget-checked sRGB `ImageBuffer` that `encode(data:)` encodes, and `JXLEncoderApple.imageBuffer(from:alphaPolicy:)` converts a `CGImage`. `JXLEncoderApple.hasIdentityOrientation(_:)` is public, so a caller can apply the same ImageIO gate. `encode(data:)` output is unchanged, except that a JPEG whose EXIF declares a rotation ImageIO does not report now takes the pixel path instead of recompressing.

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
