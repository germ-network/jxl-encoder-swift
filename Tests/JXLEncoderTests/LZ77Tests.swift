import Testing

@testable import JXLEncoder

/// The `ApplyLZ77` port: each method expands back to its input and enables
/// itself only past the source's gain threshold.
@Suite("LZ77")
struct LZ77Tests {
	@Test(
		"RLE codes a run of the previous value as a length then distance 0",
		.disabled("pending implementation"))
	func rleCopiesThePreviousValue() {}

	@Test(
		"greedy LZ77 replaces a repeated substring with a length and distance",
		.disabled("pending implementation"))
	func lz77FindsRepeatedSubstring() {}

	@Test(
		"RLE and greedy LZ77 stay disabled unless they save 0.2 bits per token plus 16",
		.disabled("pending implementation"))
	func lz77RequiresMinimumGain() {}

	@Test(
		"the optimal parse disables LZ77 when the greedy pass finds no gain",
		.disabled("pending implementation"))
	func optimalDisablesWithoutGain() {}

	@Test(
		"every method's output expands back to its input tokens",
		.disabled("pending implementation"),
		arguments: [LZ77.Method.rle, .lz77, .optimal])
	func expansionRecoversInput(method: LZ77.Method) {}
}
