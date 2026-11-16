#if (os(macOS) && !targetEnvironment(macCatalyst)) || os(Linux)
	import Testing

	@testable import JXLEncoder

	@Suite("Coefficient order native integration")
	struct CoeffOrderNativeIntegrationTests {
		@Test(.disabled("Pending actual coefficient-order serialization"))
		func coefficientOrderSerializationDecodes() {}
	}
#endif
