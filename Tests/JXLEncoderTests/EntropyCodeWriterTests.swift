import Testing

@testable import JXLEncoder

/// The general histogram builder signals forced prefix codes the way libjxl
/// does.
@Suite("EntropyCodeWriter")
struct EntropyCodeWriterTests {
	@Test(
		"forced prefix codes write LZ77 min_symbol 512 and use_prefix_code",
		.disabled("pending implementation"))
	func forcedPrefixCodesUseMinSymbol512() {}
}
