---
"@germ-network/jxl-encoder-swift": minor
---

Expose the pieces a portable caller needs to own the input policy itself.

- `JPEGParser.exifOrientation(_:)` reads a JPEG's EXIF orientation without decoding it.
- `Encoder.recompressJPEG(_:)` is the coefficient-domain fast path, portable: nil for a non-JPEG, a layout the parser declines, or a non-identity EXIF orientation. `JXLEncoderApple` now calls it, keeping its ImageIO orientation check as well.
- `JXLSignature.matches(_:)` recognises the bare codestream and the ISOBMFF container.
- `JXLEncoderApple.decode(data:maxPixelSize:alphaPolicy:maxSourceBytes:)` returns the oriented, downscaled, budget-checked sRGB `ImageBuffer` that `encode(data:)` encodes, and `JXLEncoderApple.imageBuffer(from:alphaPolicy:)` converts a `CGImage`. `JXLEncoderApple.hasIdentityOrientation(_:)` is public, so a caller can apply the same ImageIO gate. `encode(data:)` output is unchanged, except that a JPEG whose EXIF declares a rotation ImageIO does not report now takes the pixel path instead of recompressing.
