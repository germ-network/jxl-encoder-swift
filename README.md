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

## Status

Under construction. Phase 0 (de-risking) is complete:

- A bare `FF 0A` codestream decodes through ImageIO on macOS and iOS — no
  ISOBMFF container needed.
- `BitWriter` and the image header emit bytes **identical to `cjxl_tiny`**,
  verified against reference output in `Tests/JXLEncoderTests`.

Next: the forward transform chain (sRGB → linear → XYB → DCT → quantization).

## Development

The correctness strategy is differential testing against `libjxl-tiny`, ported
stage by stage: each stage must reproduce the reference encoder's intermediate
dump before the next one starts. Building the reference tooling:

```bash
git clone --recursive https://github.com/libjxl/libjxl-tiny.git
```

`djxl` and `ssimulacra2` (from `brew install jpeg-xl`) serve as the independent
decoder and quality metric. Note that quality comparisons are only meaningful
when both images carry the same transfer function.

## License

The port follows libjxl-tiny, which is BSD-3-Clause with an additional IP
rights grant; see that project's `LICENSE` and `PATENTS`.
