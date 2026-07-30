# Notices

`jxl-encoder-swift` is a derivative work of
[libjxl-tiny](https://github.com/libjxl/libjxl-tiny), the JPEG XL project's
simplified reference encoder, which is BSD-3-Clause. See [LICENSE](LICENSE),
which carries both copyright lines.

Ownership is not partitioned by file. The encoder was ported stage by stage and
diffed against the reference until the output matched byte for byte, so upstream
structure runs through it line by line; claiming a clean split between our work
and theirs would be fiction. This file records what is derived and how, so the
claim can be checked rather than taken on trust.

## What is derived from libjxl-tiny

**Transliterated modules.** Most of `Sources/JXLEncoder/` is a direct port. Each
file's header names the upstream file it came from:

`ACContext` · `ACGroupEncoder` · `ACTokenizer` · `AdaptiveQuant` · `BitWriter` ·
`ContextTree` · `DCGroupEncoder` · `DCPredictor` · `DCT` · `DistanceParams` ·
`Encoder` · `EncoderError` · `EntropyCode` · `EntropyCodeWriter` · `FastMath` ·
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
- `Geometry.swift`, `PlaneBuffer.swift`, `AdaptiveQuantTile.swift`,
  `AdaptiveQuantPipeline.swift`, `ChromaSubsampling.swift` — tiling and buffer
  handling that the reference expresses inline through Highway; reorganised here,
  though the arithmetic they drive is ported.
- `Sources/JXLEncoderApple/` — the platform shim. No upstream counterpart.

## Patents

libjxl-tiny carries an
[additional IP rights grant](https://github.com/libjxl/libjxl-tiny/blob/main/PATENTS)
from Google, separate from its copyright licence. It is not reproduced here yet.

The grant is scoped to "the copyrightable works distributed by Google as part of
the JPEG XL project", and whether that reaches an independent Swift
reimplementation is a legal question rather than a mechanical one. Nothing in
this repository should be read as a representation that the grant extends to this
code. Seek your own advice.

## Third-party dependencies

- [swift-numerics](https://github.com/apple/swift-numerics) — Apache License 2.0,
  used for `RealModule` (`pow`, absent from the Swift standard library). It is a
  package dependency, not vendored.

## Trademarks and endorsement

Clause 3 of the licence applies: neither the names of the JPEG XL Project
Authors, Google, nor any contributor may be used to endorse or promote this
package. This is an independent port and is neither produced nor endorsed by
them.
