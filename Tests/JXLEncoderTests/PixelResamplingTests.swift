import Testing

@testable import JXLEncoder

@Suite("Automatic pixel resampling", .disabled("Pending implementation"))
struct PixelResamplingTests {
	@Test func sharperKernelPreservesConstantsAndBoundsRinging() {
		Issue.record(
			"Pin constants, signed XYB bounds, impulse and asymmetric fixed operation-order cases"
		)
	}

	@Test func preprocessingPadsBeforeFilteringAndKeepsCodedGeometry() {
		Issue.record(
			"Pin 1x1, odd edges, pre-padding versus logical ceil-half dimensions and tile/group seams"
		)
	}

	@Test func frameHeaderSignalsFactorTwoAndLeavesJPEGUnchanged() {
		Issue.record(
			"Parse actual upsampling selectors and preserve existing default JPEG header coverage"
		)
	}

	@Test func serialConcurrentRGBAndGrayUseTheSameCodedGrid() async throws {
		Issue.record(
			"Pin original 513x257 and 257x513 coded multi-group traversal, threshold neighbors and both entropy modes"
		)
	}
}
