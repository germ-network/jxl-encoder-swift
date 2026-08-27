---
"@germ-network/jxl-encoder-swift": minor
---

Retargeted the encoder to match `cjxl -e 4` exactly, replacing the prior goal
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
its quality, down from a 3.5–8.0 point quality gap before this release.
JPEG recompression lands within 6.7–7.3% of `-e 4`'s size, down from roughly
18–19%.
