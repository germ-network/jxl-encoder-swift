# Streaming cropped processing: evidence at `-e 4`

libjxl streams frames above eight groups (`NumGroupsForFrame > 8`, resampling 1) one DC group at a time, each from a patch: the DC group's crop extended by one block per side and clipped to the frame (`lib/jxl/enc_frame.cc:1559-1567`), padded to a block multiple by replicating the last column and row (`lib/jxl/enc_frame.cc:1629`, `lib/jxl/image_ops.cc:21-42`), with the group rectangle taken relative to the patch (`lib/jxl/enc_frame.cc:1633-1634`; one-shot uses `Rect(color)`, `lib/jxl/enc_frame.cc:1656-1658`). Swift converts the full frame lazily by stripe and does not build patches (`Sources/JXLEncoder/Encoder.swift:115-197`). This note records why the source gates leave the patch border unused at the encoder's fixed `-e 4 kCheetah` configuration, and exactly how far the evidence reaches.

## Source gates

The border exists "when computing inverse Gaborish and adaptive quantization map" (`lib/jxl/enc_frame.cc:1560-1562`). Every consumer is off at `kCheetah`:

| Step | Gate | Cite |
|---|---|---|
| Quant field | constant, speed > `kHare` | `lib/jxl/enc_heuristics.cc:1098-1117` |
| Block types | DCT8 everywhere at >= `kCheetah` | `lib/jxl/enc_ac_strategy.cc:1076-1078`, `lib/jxl/enc_ac_strategy.cc:1144-1147` |
| CfL tile search | only <= `kHare` / <= `kSquirrel` | `lib/jxl/enc_heuristics.cc:1170-1175`, `lib/jxl/enc_heuristics.cc:1191-1195` |
| Gaborish | only <= `kHare` | `lib/jxl/enc_frame.cc:316-322` |
| Inverse Gaborish | gated on gaborish | `lib/jxl/enc_heuristics.cc:1135-1144` |
| Dequant matrices | first group only; defaults at e4 | `lib/jxl/enc_heuristics.cc:1145-1148`, `lib/jxl/enc_heuristics.cc:208-232` |
| Quantizer search | skipped when streaming; no-op at `kCheetah` regardless | `lib/jxl/enc_heuristics.cc:1210-1216`, `lib/jxl/enc_adaptive_quantization.cc:1273-1289` |
| Chromacity adjustments | first group only; at e4 distance-only `x_qm_scale`, `b_qm_scale` 2 | `lib/jxl/enc_frame.cc:1636-1639`, `lib/jxl/enc_frame.cc:665-692` |

The first-group-only settings therefore resolve to the same values as one-shot at the cited configuration. Swift applies the same constants to every group (`Sources/JXLEncoder/DistanceParams.swift:84-88`, `Sources/JXLEncoder/FrameAssembly.swift:68`).

## Observed differences

`coefficientIntegersMatchPinnedStages` compares every AC and DC integer against the reference harness, which itself emulates the per-DC-group crop (`Reference/harness/src/cmd_pixel_stages.cc:74-75`, `88-89`, `132`). DC matches exactly in all channels. AC differs in 19 coefficients, all by exactly 1 (delta = Swift − reference). `pixel_lifecycle_2057x521` has 2 DC groups (boundary between block columns 255 and 256, x = 2048), 258x66 blocks; `flower_1024` has one DC group, 128x128 blocks. "AC-group edge" is the distance in blocks to a 32-block AC-group boundary.

| fixture | ch | block row, col | k | Swift | ref | delta | to DC boundary | to frame edge | to AC-group edge |
|---|---|---|---|---|---|---|---|---|---|
| flower_1024 | c0 | 86, 105 | 16 | 1 | 2 | -1 | n/a | 22 | 9 |
| flower_1024 | c0 | 101, 69 | 9 | 1 | 2 | -1 | n/a | 26 | 5 |
| lifecycle | c0 | 3, 79 | 49 | -1 | 0 | -1 | 176 | 3 | 3 |
| lifecycle | c0 | 7, 206 | 26 | 1 | 0 | +1 | 49 | 7 | 7 |
| lifecycle | c0 | 24, 189 | 37 | 2 | 1 | +1 | 66 | 24 | 2 |
| lifecycle | c0 | 28, 203 | 18 | 0 | -1 | +1 | 52 | 28 | 3 |
| lifecycle | c0 | 29, 107 | 41 | -1 | -2 | +1 | 148 | 29 | 2 |
| lifecycle | c0 | 35, 5 | 59 | 0 | -1 | +1 | 250 | 5 | 3 |
| lifecycle | c0 | 38, 222 | 10 | 2 | 1 | +1 | 33 | 27 | 1 |
| lifecycle | c0 | 39, 87 | 42 | 3 | 2 | +1 | 168 | 26 | 7 |
| lifecycle | c0 | 39, 200 | 3 | -1 | 0 | -1 | 55 | 26 | 7 |
| lifecycle | c0 | 47, 143 | 38 | 2 | 1 | +1 | 112 | 18 | 15 |
| lifecycle | c0 | 52, 73 | 10 | -1 | 0 | -1 | 182 | 13 | 9 |
| lifecycle | c0 | 61, 194 | 40 | -1 | 0 | -1 | 61 | 4 | 2 |
| lifecycle | c0 | 63, 50 | 8 | 6 | 7 | -1 | 205 | 2 | 0 |
| lifecycle | c1 | 5, 161 | 41 | 1 | 0 | +1 | 94 | 5 | 1 |
| lifecycle | c1 | 39, 196 | 1 | -1 | -2 | +1 | 59 | 26 | 4 |
| lifecycle | c2 | 39, 196 | 1 | 3 | 4 | -1 | 59 | 26 | 4 |
| lifecycle | c2 | 61, 137 | 42 | 0 | 1 | -1 | 118 | 4 | 2 |

None is within 33 blocks of the DC boundary or closer than 2 blocks to a frame edge, and `flower_1024` (one DC group, no crop) shows the same kind of difference. They are not cropping-caused; they remain under the quantization-rounding issue.

## Exact match where patch geometry acts

`cropSensitiveBlocks` (in `PixelContractTests.swift`) selects the blocks where patch geometry acts: both sides of every interior DC-group boundary and the last block row and column, where the patch border, the group-rectangle offset and rounding, and edge padding apply. The test requires every AC integer in those blocks, in all three channels, to equal the reference exactly: 453 blocks for `pixel_lifecycle_2057x521`, 255 for `flower_1024`. A failure there is reported as a crop-sensitive block, whatever its cause.

Mutations run against this proof (each reverted):

| Mutation | Fails |
|---|---|
| helper returns no blocks | block-count and axis-coverage expectations |
| edge padding replicates → zero | DC, and the crop-sensitive AC assertion |
| XYB stripe rect shifted +8 px at x = 2048 | DC, and the crop-sensitive AC assertion |
| each 8x8 XYB block transposed at x = 2048 (keeps block means, so DC stays exact) | the crop-sensitive AC assertion alone |

## Scope

- Covers the two fixtures' known AC differences at `-e 4`. It is not a claim that the whole frame is crop-neutral.
- Neither fixture has an interior DC-group row boundary, so the row half of `cropSensitiveBlocks` is checked only by a synthetic geometry test, not against reference integers.
- Patch XYB was not compared directly: the pinned fixtures hold only quantized integers (`Reference/harness/src/cmd_pixel_stages.cc:222-230`), so the evidence is the source gates plus the exact match above.
- A per-patch processing loop would be needed only by border heuristics active at `kHare` and slower tiers (`-e 5` and up) or for performance (GER-3639).
