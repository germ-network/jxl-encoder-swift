#if os(macOS) && !targetEnvironment(macCatalyst) || os(Linux)
	import Testing

	@testable import JXLEncoder

	@Suite("Pixel resampling independent decoding", .disabled("Pending implementation"))
	struct PixelResamplingNativeIntegrationTests {
		@Test func decodedOddRGBAndGrayKeepOutputDimensionsAndMeaning() async throws {
			Issue.record(
				"Decode actual serial/concurrent Swift bytes; verify output size, channels, gradients and seams"
			)
		}
	}
#endif
