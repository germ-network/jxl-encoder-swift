---
'@germ-network/jxl-encoder-swift': patch
---

Recompress recognized unprofiled 4:4:4 RGB JPEGs from their quantized coefficients while signaling RGB meaning and the source decoder's integer DC offset.

The offset can leave a fractional source-unit difference in decoded pixels when q00 does not divide 1024, while the original JPEG coefficients remain exactly recoverable.
