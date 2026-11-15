import Testing

@testable import JXLEncoder

@Suite("DC group sharpness")
struct DCGroupSharpnessTests {
	@Test(
		"metadata emits the selected sharpness on every full-grid block",
		.disabled("Awaiting sharpness serialization"))
	func selectedSharpnessTokens() throws {}

	@Test(
		"JPEG metadata matches pinned native sharpness across sampling and grayscale",
		.disabled("Awaiting native sharpness fixtures"))
	func jpegSharpnessMatchesReference() throws {}

	@Test(
		"native decoding observes actual JPEG sharpness in both coding modes",
		.disabled("Awaiting native sharpness cross-check"))
	func actualJPEGSharpnessCrossCheck() throws {}

	@Test(
		"sharpness fixture proofs require consumed exact comparisons",
		.disabled("Awaiting sharpness proof descriptors"))
	func sharpnessProofReferences() throws {}
}
