# Pixel distance surface

`Encoder.encode(_:distance:)` and `encodeConcurrently` accept every positive finite `Float`. Zero, including negative zero, throws `losslessNotSupported`; negative and non-finite values throw `invalidDistance`. The selected libjxl source normalizes positive values below 0.05 to 0.05. Swift intentionally retains values above the source API's upper limit of 25.

`DistanceParams.originalDistance` stores the normalized value. Values at or above 10 select automatic 2x resampling. `DistanceParams.distance` is the effective value used by EPF and quantization: it is the original value below 10 and `original * 0.25 + 0.25` at or above 10. X quant-matrix selection uses the original value.

The implementation preserves Swift's native `Float.pow`, source arithmetic order, and the minimum-one repairs for `globalScale` and `quantDC`. Finite derived-value safety is covered by targeted boundary and extreme-value tests. This is a bounded implementation proof; it does not establish output identity with a particular libjxl build, universal image quality, or safety for untested downstream decoding behavior.
