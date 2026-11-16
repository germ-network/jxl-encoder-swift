---
'@germ-network/jxl-encoder-swift': patch
---

Decode disjoint sequential JPEG scans into padded persistent coefficient planes, bind DQT redefinitions at each scan, apply scan-local restart and entropy state, and preserve grayscale sampling fallback.

Newly accepted multi-scan inputs can produce different JPEG XL output; resolved `quantTableIndex` values can exceed 3, and added public `JPEGParseError` cases can require downstream exhaustive switches to be updated.
