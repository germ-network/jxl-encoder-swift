---
'@germ-network/jxl-encoder-swift': minor
---

Recompress JPEGs carrying an SDR ICC v4 display RGB matrix profile, coding the exact profile into the JPEG XL header. Adds the public `ICCProfile` and `JPEGTranscode.iccProfile`, and `EncoderError.unsupportedICCProfile`, thrown by `encodeJPEG` for a profile libjxl's ICC reader would reject.
