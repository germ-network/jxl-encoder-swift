# Coefficient sampling reference

The fixtures use the pinned libjxl `ComputeCoeffOrder` API on synthetic DCT8
coefficient images. `Reference/harness/src/cmd_coeff_order.cc` preserves the
frame dimensions and group traversal. Its `sample` mode runs at
`SpeedTier::kCheetah`; its `counts` mode runs at `SpeedTier::kWombat`, so all
prescribed zero counts reach the upstream float sort without sampling.

`coefficient_sampled_group_boundary` spans two groups with 1,056 blocks. An
unchanged-source LLVM coverage build of `enc_coeff_order.cc` observed 544
selected blocks and 512 rejected blocks. The three-channel zero branch ran
3,261 times; coefficient positions 1 and 8 had 544 and 543 zeros per channel.
The generated upstream order ends in `[8, 1]`.

`coefficient_sort_boundary` records the previously observed synthetic witness:
8,392,231 DCT8 blocks, 262,258 groups, 4,194,312 selected blocks and 4,197,919
rejected blocks. The exact input counts are 4,194,312 at raster position 1 and
4,194,311 at raster position 8. Unchanged-source coverage observed 25,165,869
zero and 780,142,035 nonzero coefficients across the three channels. The
actual sampler and an unsampled source call with those same counts both end in
`[1, 8]`; the Swift `Double` calculation ends in `[8, 1]`. This is synthetic
coefficient-stage evidence, not an end-to-end encoder reachability claim.

Coverage was collected by compiling the pinned, unchanged
`lib/jxl/enc_coeff_order.cc` with Clang `-fprofile-instr-generate
-fcoverage-mapping`, running the actual API probe, then merging/exporting the
profile with `llvm-profdata` and `llvm-cov`. The complete machine-local profile
and compiler invocation are retained in the ignored
`plans/ger-3392b/probe/` evidence directory. `coefficient_sampling_observations.tsv`
contains the reviewed counters used to validate the committed fixture outputs.
