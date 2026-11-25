import Testing

@testable import JXLEncoder

/// Structural invariants of libjxl `PredictICC`, `ICCANSContext` and the
/// `WriteICC` LZ77 choice; byte exactness is proven by an independent decoder
/// recovering the profile.
@Suite("ICCCodec")
struct ICCCodecTests {
	@Test(
		"the stream opens with varint profile size then varint command count",
		.disabled("pending implementation"))
	func predictionStartsWithVarintSizeAndCommandCount() {}

	@Test(
		"header fields matching the initial prediction leave zero residuals",
		.disabled("pending implementation"))
	func headerResidualIsZeroForPredictedFields() {}

	@Test(
		"a TRC shared by all three channels collapses to the shared-tag command",
		.disabled("pending implementation"))
	func sharedTRCCollapsesToCommand() {}

	@Test(
		"contiguous r/g/bXYZ tags use the XYZ command",
		.disabled("pending implementation"))
	func contiguousXYZUsesXYZCommand() {}

	@Test(
		"transformed bytes 0 through 128 use context 0 and byte 129 does not",
		.disabled("pending implementation"))
	func contextIsZeroThroughIndex128() {}

	@Test(
		"later contexts are 1 + ByteKind1(previous) + 8 × ByteKind2(previousPrevious)",
		.disabled("pending implementation"))
	func contextClassifiesByteKinds() {}

	@Test(
		"16,383 transformed bytes select optimal LZ77 and 16,384 select greedy",
		.disabled("pending implementation"))
	func lz77MethodSwitchesAt16384() {}
}
