---
"@germ-network/jxl-encoder-swift": patch
---

Bake EXIF orientation on the JPEG recompression path.

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
