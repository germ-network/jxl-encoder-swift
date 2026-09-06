# jxl-encoder-swift

A narrow JPEG XL **encoder** in pure Swift, with no `Unsafe*` constructs and no
C or C++ dependencies.

Apple platforms decode JPEG XL natively (iOS 17+, macOS 14+) but ship no
encoder — `public.jpeg-xl` is absent from `CGImageDestinationCopyTypeIdentifiers()`
as of macOS 27 and iOS 26. This package fills that gap.

The encoder began as a port of Google's simplified reference encoder
[libjxl-tiny](https://github.com/libjxl/libjxl-tiny) and is now retargeted to
match one exact named configuration of full
[libjxl](https://github.com/libjxl/libjxl): `cjxl -e 4` — lossy VarDCT, XYB
color, 8×8 blocks. It targets photographic content at display and thumbnail
sizes.

## Targets

| Target | Contents |
|---|---|
| `JXLEncoder` | Portable core. **Swift stdlib only** — no Foundation, no platform frameworks. Linux CI enforces this so an Android shim can consume it unchanged. |
| `JXLEncoderApple` | Platform shim. The only target that touches Foundation / CoreGraphics / ImageIO: decodes arbitrary input, handles thumbnails and alpha policy, returns `Data`. |

## Usage

```swift
import JXLEncoderApple

// Any ImageIO-decodable input. EXIF orientation is baked into the pixels on
// every path; `maxPixelSize` caps the longest edge for thumbnails.
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

Working. Gated against the actual `cjxl -e 4` binary, not just against
`libjxl-tiny`: decode-exactness, corridor-bounded size, and quality metrics
across a real-photo corpus, not byte-identity — `-e 4` and this port make
different, independently-arrived-at coding choices in places (ANS vs. prefix
selection per section, ordering) that land on the same output size without
matching bit for bit. 200 tests, CI on macOS, Mac Catalyst, iOS Simulator and
Linux.

Implemented: lossy VarDCT (8×8), XYB color, uniform quantization matching
`-e 4`'s own (non-adaptive) field, ANS and prefix entropy coding chosen per
section, DC modular sub-encoder, chroma subsampling, alpha flattening, and
baseline JPEG recompression. A bare `FF 0A` codestream decodes through ImageIO
on macOS and iOS — no ISOBMFF container needed.

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

Against the real `cjxl -e 4` binary (v0.12.0, no forced flags — the pinned
gate, not a comparison rigged in either direction), at `distance = 1.0` on
five real photographs:

| photo | this package | `cjxl -e 4` | `cjxl -e 7` |
|---|---|---|---|
| hopper | 10 418 B / 89.72 | 10 307 B / 89.82 | 10 002 B / 90.63 |
| flower | 498 677 B / 87.42 | 496 748 B / 87.68 | 486 257 B / 88.86 |
| macan | 46 033 B / 84.49 | 44 913 B / 85.17 | 41 862 B / 83.50 |
| riaphoto | 27 985 B / 88.62 | 27 234 B / 89.19 | 24 125 B / 90.32 |
| bliznaca | 41 859 B / 87.74 | 40 888 B / 88.21 | 40 711 B / 88.76 |

(bytes / ssimulacra2). This package sits 0.4–2.8% larger than `-e 4` and
within 0.7 ssimulacra2 points of it on every photo — closer to `-e 4` than
`-e 4` is to `-e 7` on macan, where this package's quality actually exceeds
`-e 7`'s. `-e 7` is shown for context, not as the target: it runs full
libjxl's rate-distortion search, adaptive quantization, and variable block
sizes, none of which `-e 4` itself uses.

Smooth synthetic content remains the weak case (see Known limits) — a
1024×1024 gradient comes in at 16 165 B against `-e 4`'s 8 214 B, a gap this
package's DC modular coder, not its quantization or entropy layer, is
responsible for.

JPEG recompression (lossless both sides, `flower.jpg` at matched quality):

| source | this package | `cjxl -e 4 -j 1` |
|---|---|---|
| 4:2:0 | 486 422 B | 456 104 B (+6.7%) |
| 4:4:4 | 609 787 B | 568 375 B (+7.3%) |

On Apple silicon the encoder runs at ~10 MP/s single-threaded and adds ~336 KB
to a stripped iOS binary. `encodeConcurrently` splits the AC groups across a
task group for byte-identical output at roughly twice the speed:

| size | serial | concurrent |
|---|---|---|
| 600×600 | 0.041 s | 0.017 s |
| 12 MP | 1.34 s | 0.67 s |
| 48 MP | 5.37 s | 2.76 s |

Twice, not fourteen times, on a fourteen-core machine. The AC groups are 92% of
the work, so Amdahl puts the ceiling near 7× — the shortfall is in the group
work itself rather than the serial remainder, most likely allocator contention,
since every group and every stripe within it allocates. Worth revisiting if
encode latency ever matters more than it does now.

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

Most stages still trace to `libjxl-tiny`: differential testing against its
intermediate dumps, stage by stage, is how most of this port was built and
verified, and most of that gating is still live in the test suite. Building
the reference tooling:

```bash
git clone --recursive https://github.com/libjxl/libjxl-tiny.git
```

Then `Reference/build.sh`, which pins the reference to the configuration this
port targets. That pinning matters: `OPTIMIZE_CHROMA_FROM_LUMA` also selects
the tile dimension, so building the reference with its defaults produces dumps
describing a differently tiled encoder.

**Stages retargeted to full `libjxl`** — entropy coding (ANS, coefficient
reordering, context clustering), quantization calibration, chroma-from-luma —
are gated differently, since `libjxl-tiny` predates or diverges from what
`cjxl -e 4` actually does there: against real corpus output from the pinned
`cjxl`/`djxl` binaries directly (decode-exactness, size corridors, quality
metrics), not byte-identical dumps. `docs/gap-closure-plan.md` records which
gate applies to which stage and why.

`djxl` and `ssimulacra2` (from `brew install jpeg-xl`) serve as the independent
decoder and quality metric throughout, for both kinds of gate. Two traps when
comparing against `libjxl-tiny` specifically:

- Quality comparisons are only meaningful when both images carry the same
  transfer function. `libjxl-tiny` hardcodes linear; this encoder signals sRGB
  in production and can emit linear for byte-comparison.
- `libjxl-tiny` takes linear float input, so a comparison is only valid if that
  input is this encoder's own linearization. Converting through CoreGraphics
  instead gives the reference different data and makes every byte comparison
  meaningless.

## Scope

**This is a reimplementation, not a new encoder.** It is deliberately narrow: a
Swift transliteration of Google's reference implementation and, where that
reference diverges from the pinned target, of full libjxl instead — following
published algorithms and bitstream decisions either way, with no novel
contributions to the format or to the coding techniques it uses. Where a
stage's actual reference disagrees with this port, the reference is right and
this is a bug — which reference that is varies by stage; see "Development"
above and `docs/gap-closure-plan.md`.

Stages not yet retargeted are still gated byte-for-byte against `cjxl_tiny`;
retargeted stages are gated against the pinned `cjxl -e 4` binary instead, per
the corridor/decode/quality criteria `docs/gap-closure-plan.md` records.
Contributions are welcome within that scope; see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

BSD-3-Clause, the same licence as both reference implementations — see
[LICENSE](LICENSE), which carries this project's copyright and the JPEG XL
Project Authors', since the port is a derivative work of libjxl-tiny and, for
the stages retargeted since, of full libjxl.

[NOTICE.md](NOTICE.md) records which files are transliterated from upstream,
which hold generated upstream tables, and which were written against published
specifications instead, along with the dependency licensing.
