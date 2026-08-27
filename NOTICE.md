# Notices

`jxl-encoder-swift` is a derivative work of
[libjxl-tiny](https://github.com/libjxl/libjxl-tiny), the JPEG XL project's
simplified reference encoder, and of full
[libjxl](https://github.com/libjxl/libjxl), both BSD-3-Clause. See
[LICENSE](LICENSE), which carries the copyright lines for both.

Ownership is not partitioned by file. The encoder was ported from
`libjxl-tiny` stage by stage, diffed against that reference until the output
matched byte for byte; it is now retargeted to match one exact configuration
of full `libjxl` (`cjxl -e 4`), with individual modules — most recently
quantization calibration and chroma-from-luma — brought in line with that
reference's own constants and behavior where they diverged from it.

## What is derived from libjxl-tiny or full libjxl

**Transliterated modules.** Most of `Sources/JXLEncoder/` is a direct port.
Each file's header names the upstream file it came from — `libjxl-tiny`'s for
most, full `libjxl`'s for modules retargeted since (`DistanceParams`'s
quantization constants, `FrameAssembly`'s color-correlation defaults):

`ACContext` · `ACGroupEncoder` · `ACTokenizer` · `BitWriter` · `ContextTree` ·
`DCGroupEncoder` · `DCPredictor` · `DCT` · `DistanceParams` · `Encoder` ·
`EncoderError` · `EntropyCode` · `EntropyCodeWriter` · `FastMath` ·
`FrameAssembly` · `HistogramCluster` · `HuffmanTree` · `ImageHeader` ·
`PrefixCodeWriter` · `QuantMatrices` · `Quantizer` · `QuantizeRoundtrip` ·
`Token` · `XYB`

**Generated tables.** These hold upstream constants, extracted by compiler-driven
generators in `Reference/tools/` rather than transcribed by hand:
`StaticEntropyCodes.swift` (context maps and prefix codes),
`ContextTree.swift` (the modular context tree's static tokens),
`QuantMatrices.swift` (DCT8 quantization weights).

**Test fixtures.** `Tests/*/Fixtures/` holds intermediate dumps and whole-file
output produced by the reference encoder, used as golden data.

**`Reference/patches/0001-test-hooks.patch`** is a diff against libjxl-tiny and
therefore contains fragments of upstream source. libjxl-tiny itself is *not*
vendored here — `Reference/build.sh` clones it — so no upstream C++ is otherwise
redistributed in this repository.

## What is not

Written against published specifications or original to this project, with no
libjxl-tiny counterpart:

- `JPEGParser.swift`, `JPEGHuffman.swift` — baseline JPEG parsing, written to
  ISO/IEC 10918-1 Annex F. libjxl-tiny has no JPEG input path.
- `ReciprocalEstimate.swift` — reproduces Arm's `FPRecipEstimate` as specified in
  the Arm Architecture Reference Manual, to match what the reference gets from
  the hardware instruction. Its header cites libjxl-tiny to explain why the file
  exists, not because anything was ported from it.
- `SRGBTransfer.swift` — the IEC 61966-2-1 sRGB transfer function, tabulated.
- `SectionWriter.swift` — staged section writing, so an entropy code can be
  optimised before anything is emitted. Structurally different from the
  reference's approach.
- `Geometry.swift`, `PlaneBuffer.swift`, `ChromaSubsampling.swift` — tiling and
  buffer handling that the reference expresses inline through Highway;
  reorganised here, though the arithmetic they drive is ported.
- `AdaptiveQuantPipeline.swift` — now holds only the XYB color-space
  conversion. Its per-tile adaptive quantization field (`AdaptiveQuant.swift`,
  `AdaptiveQuantTile.swift`, both deleted) was a direct port of
  `libjxl-tiny`'s Highway-vectorized `enc_adaptive_quantization.cc`; removed
  because `cjxl -e 4` never runs that computation — the retargeted quantizer
  fills a uniform field instead, matching full `libjxl`'s own behavior at this
  speed tier rather than porting a feature the target configuration doesn't
  use.
- `Sources/JXLEncoderApple/` — the platform shim. No upstream counterpart.

## Third-party dependencies

- [swift-numerics](https://github.com/apple/swift-numerics) — Apache License 2.0,
  used for `RealModule` (`pow`, absent from the Swift standard library). It is a
  package dependency, not vendored.

## Trademarks and endorsement

Clause 3 of the licence applies: neither the names of the JPEG XL Project
Authors, Google, nor any contributor may be used to endorse or promote this
package. This is an independent port and is neither produced nor endorsed by
them.
