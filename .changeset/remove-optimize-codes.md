---
'@germ-network/jxl-encoder-swift': minor
---

Remove the `optimizeCodes` parameter from `Encoder.encode`, `Encoder.encodeConcurrently`, the runner-based `Encoder.encode` and `Encoder.encodeJPEG`. Every encode builds per-image entropy codes, coefficient orders and block context maps, as libjxl does at every effort. Callers passing `optimizeCodes: false` must drop the argument; output for callers using the default is unchanged.
