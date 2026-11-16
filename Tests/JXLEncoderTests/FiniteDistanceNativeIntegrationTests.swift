#if (os(macOS) && !targetEnvironment(macCatalyst)) || os(Linux)
	import Testing

	@testable import JXLEncoder

	@Suite("Finite distance independent decoding")
	struct FiniteDistanceNativeIntegrationTests {
		@Test(.disabled("Pending finite distance serialization implementation"))
		func extremeFiniteCodestreamsDecodeWithFiniteSamples() async throws {}
	}
#endif
