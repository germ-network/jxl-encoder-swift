# jxl-encoder-swift

A narrow JPEG XL **encoder** in pure Swift, with no `Unsafe*` constructs and no
C or C++ dependencies.

Apple platforms decode JPEG XL natively (iOS 17+, macOS 14+) but ship no
encoder — `public.jpeg-xl` is absent from `CGImageDestinationCopyTypeIdentifiers()`
as of macOS 27 and iOS 26. This package fills that gap without linking libjxl,
which is too large for an App Clip and is unsafe-language code besides.

The encoder is a port of Google's simplified reference encoder
[libjxl-tiny](https://github.com/libjxl/libjxl-tiny): lossy VarDCT, XYB color,
8×8 blocks, prefix-code entropy coding. It targets photographic content at
display and thumbnail sizes.

## Targets

| Target | Contents |
|---|---|
| `JXLEncoder` | Portable core. **Swift stdlib only** — no Foundation, no platform frameworks. Linux CI enforces this so an Android shim can consume it unchanged. |
| `JXLEncoderApple` | Platform shim. The only target that touches Foundation / CoreGraphics / ImageIO: decodes arbitrary input, handles thumbnails and alpha policy, returns `Data`. |

## Usage

```swift
import JXLEncoderApple

// Any ImageIO-decodable input; `maxPixelSize` caps the longest edge for
// thumbnails and applies the EXIF orientation.
let jxl = try JXLEncoderApple.encode(data: jpegData, distance: 1.0)
let thumb = try JXLEncoderApple.encode(
	data: jpegData, distance: 1.0, maxPixelSize: 200)
```

`distance` is a butteraugli target: lower is higher quality. Input carrying
alpha is composited onto `alphaPolicy`'s background, white by default.

### Memory

Encoding is memory-hungry and untrusted headers are cheap to write, so
`encode(data:)` estimates what a source will cost and refuses to start past
`maxSourceBytes` (640 MB by default). Measured peaks: 110 MB at 2 MP, **503 MB
at 12 MP**, 1388 MB at 48 MP — so a full-size 48 MP photograph needs an
explicitly raised budget.

`maxPixelSize` is the cheaper answer, because ImageIO reaches it by DCT-scaling
*during* the decode rather than after: the same 48 MP source costs 24 MB at
200 px and 176 MB at 2000 px. The budget is applied to that scaled size, so
capping a large photograph is never refused for the source's sake.

To pick a cap from what the device can spare:

```swift
// e.g. from ProcessInfo.physicalMemory, or a per-device-model table
let cap = JXLEncoderApple.maxPixelSize(fitting: budgetForThisDevice)
let jxl = try JXLEncoderApple.encode(
	data: input, maxPixelSize: cap, maxSourceBytes: budgetForThisDevice)
```

`maxPixelSize(fitting:)` returns `nil` when nothing fits — no encode was
measured below ~17 MB, so a caller with only tens of megabytes to spare cannot
use this path at any size, whatever cap it picks. `estimatedEncodeBytes(width:
height:maxPixelSize:)` gives the same estimate directly; it bounds every
measurement taken, over-estimating a large encode by up to about half.

Recompressing a JPEG is far cheaper than re-encoding its pixels — coefficients
cost exactly 6 bytes a pixel at 4:2:0, so that 48 MP photograph needs 279 MB
rather than 1.4 GB. JPEG input takes that path automatically, and it is not
subject to `maxSourceBytes` because it never materialises pixels.

Off Apple platforms, drive the core directly with 8-bit sRGB samples:

```swift
import JXLEncoder

let image = try ImageBuffer(width: w, height: h, samples: rgb, channels: 3)
let bytes = try Encoder.encode(image, distance: 1.0)
```

## Status

Working. With static entropy tables the output is **byte-identical to
`cjxl_tiny`** across the corpus, single- and multi-group; with per-image
optimized prefix codes the encoding decisions are unchanged and only the
entropy layer differs. 186 tests, CI on macOS, Mac Catalyst, iOS Simulator and
Linux.

Implemented: lossy VarDCT (8×8), XYB color, adaptive quantization, DC modular
sub-encoder, static and per-image prefix codes, chroma subsampling, alpha
flattening, and baseline JPEG recompression. A bare `FF 0A` codestream decodes
through ImageIO on macOS and iOS — no ISOBMFF container needed.

**JPEG input is recompressed rather than re-encoded.** A JPEG's own quantized
coefficients are re-coded directly — no inverse transform, so no generation of
loss. Fidelity matches `cjxl --lossless_jpeg=1`: identical mean error to three
decimals where comparable, slightly better at 4:4:4, better on greyscale. What
the parser or the format declines — progressive, arithmetic-coded, CMYK, 4:1:1 —
falls back to decoding and re-encoding the pixels, and a `maxPixelSize` does too,
since a transcode reproduces the source's own resolution.

The saving is 1–3%, not the 20% often quoted for JPEG recompression; small
greyscale files come out larger. The reasons to use it are the absence of
generational loss and the memory profile — coefficients cost 6 bytes a pixel at
4:2:0 against roughly 40 for the pixel path, so a 48 MP photograph needs 279 MB
rather than 1.4 GB.

Alpha is flattened onto a background, never preserved.

### Measured

Against `libjxl-tiny` at the same configuration, encoding decisions are
identical — byte-identical files with static tables, and the same ssimulacra2
to the last digit at every distance. Chroma-from-luma and variable block sizes,
both dropped here, save 5–8% at fixed distance but ~0–4% at matched quality on
photographs.

Against full `libjxl` on a 600×600 photograph, at matched quality
(ssimulacra2 ≈ 82.5):

| encoder | bytes |
|---|---|
| this package | 42 197 |
| `cjxl -e1` | 37 443 |
| `cjxl -e7` | 30 811 |

Roughly 11% of that is structural — ANS, variable block sizes and rate
allocation are present even at libjxl's cheapest effort — and the rest is
search effort. Gaborish and EPF are not the cause; disabling them in libjxl
costs under one ssimulacra2 point.

On Apple silicon the encoder runs at ~10 MP/s scalar and single-threaded, and
adds ~336 KB to a stripped iOS binary.

### Known limits

- **Use `distance` ≤ 1.0.** Above roughly 1.0 the inherited
  distance-to-quality mapping falls apart: a 600×600 photograph scores 82.3 at
  d = 1.0 and 64.0 at d = 1.5, where libjxl moves 89.3 → 87.3 over the same
  step. This is inherited from libjxl-tiny, not introduced by the port.
- **Smooth synthetic content is the weak case.** On gradients libjxl stays near
  ssimulacra2 91–95 across the whole distance range while shrinking far below
  what this encoder reaches.
- Output is deterministic on every architecture, which the reference is not:
  `cjxl_tiny` emits different bytes at different SIMD widths because four
  horizontal float reductions in adaptive quantization change summation order
  with lane count.

## Development

The correctness strategy is differential testing against `libjxl-tiny`, ported
stage by stage: each stage must reproduce the reference encoder's intermediate
dump before the next one starts. Building the reference tooling:

```bash
git clone --recursive https://github.com/libjxl/libjxl-tiny.git
```

Then `Reference/build.sh`, which pins the reference to the configuration this
port targets. That pinning matters: `OPTIMIZE_CHROMA_FROM_LUMA` also selects
the tile dimension, so building the reference with its defaults produces dumps
describing a differently tiled encoder.

`djxl` and `ssimulacra2` (from `brew install jpeg-xl`) serve as the independent
decoder and quality metric. Two traps when comparing against the reference:

- Quality comparisons are only meaningful when both images carry the same
  transfer function. `libjxl-tiny` hardcodes linear; this encoder signals sRGB
  in production and can emit linear for byte-comparison.
- `libjxl-tiny` takes linear float input, so a comparison is only valid if that
  input is this encoder's own linearization. Converting through CoreGraphics
  instead gives the reference different data and makes every byte comparison
  meaningless.

## License

BSD-3-Clause — see [LICENSE](LICENSE), which carries both this project's
copyright and the JPEG XL Project Authors', since the port is a derivative work
of libjxl-tiny.

[NOTICE.md](NOTICE.md) records which files are transliterated from upstream,
which hold generated upstream tables, and which were written against published
specifications instead. It also covers the dependency licensing and the open
question about upstream's separate patent grant, which is **not** reproduced
here and should not be assumed to reach this code.
