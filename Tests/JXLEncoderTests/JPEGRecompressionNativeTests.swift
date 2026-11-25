#if (os(macOS) && !targetEnvironment(macCatalyst)) || os(Linux)
	import Testing

	@testable import JXLEncoder

	/// Profiled recompression checked by libjxl's own decoder through the
	/// `jpeg-witness` harness at `JXL_HARNESS_PATH`.
	@Suite("JPEG recompression native integration")
	struct JPEGRecompressionNativeTests {
		/// Each fixture also fixes whether its coded ICC enables LZ77, measured
		/// with pinned libjxl `WriteICC`: off for the P3 profiles, on for the
		/// repeated-desc and large ones.
		@Test(
			"libjxl recovers the exact profile, coefficients and quantizers",
			.disabled("pending implementation"),
			.enabled(if: CoeffOrderNativeIntegrationTests.harness != nil),
			arguments: ["ycbcr-p3", "rgb-p3", "lz77-p3", "large"], [true, false])
		func witnessRecoversProfileCoefficientsAndQuantizers(
			fixture: String, optimizeCodes: Bool
		) {}
	}
#endif
