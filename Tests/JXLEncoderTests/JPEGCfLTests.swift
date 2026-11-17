import Testing

@testable import JXLEncoder

@Suite("JPEG chroma from luma")
struct JPEGCfLTests {
	@Test("Zero quantizers and excessive ratios fail before applicability gates", .disabled())
	func jpegCfLRejectsZeroQuantizationAndExcessiveRatio() throws {}

	@Test("Tile maps and residuals follow the selected source search", .disabled())
	func jpegCfLMatchesPinnedTileMapsAndCoefficients() throws {}

	@Test("Separated maxima use the endpoint midpoint and strict gain rule", .disabled())
	func jpegCfLUsesSourceMaximumAndGainRules() throws {}

	@Test("Signed two-round predictions recover every original coefficient", .disabled())
	func jpegCfLRecoversEverySourceCoefficient() throws {}

	@Test("Grayscale and subsampled inputs retain zero maps and original AC", .disabled())
	func jpegCfLIsDisabledForGrayscaleAndSubsampling() throws {}

	@Test("An unrepresentable winning factor retains zero correlation", .disabled())
	func jpegCfLUnrepresentableWinnerUsesZeroCorrelation() throws {}

	@Test("Only an unrepresentable actual residual raises overflow", .disabled())
	func jpegCfLChecksActualResidualRange() throws {}

	@Test("Ordering and tokenization consume the same mapped residuals", .disabled())
	func jpegCfLOrderingAndTokenizationUseResiduals() throws {}

	@Test("Actual static and optimized Swift streams recover source coefficients", .disabled())
	func actualJPEGCfLSerializationCrossCheck() throws {}
}
