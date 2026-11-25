import Foundation
import Testing

@testable import JXLEncoder

/// Frames above eight groups are coded the way libjxl streams them: histograms,
/// coefficient order, block model and modular trees are built DC group by DC
/// group rather than over the whole frame. Frames at or below eight groups keep
/// the one-shot coding, which the existing byte-equality tests pin.
@Suite("Streaming entropy")
struct StreamingEntropyTests {
	// MARK: One-context codes

	@Test(
		"a code with one context transmits no context map")
	func oneContextCodeWritesNoContextMap() throws {
		let tokens = (0..<40).map { Token(context: 0, value: UInt32($0 % 5)) }
		let one = SectionOptimizer.modularCode(
			tokenStreams: [tokens], contextCount: 1, extraDCPrecision: 0)
		#expect(one.transmittedContextCount == 1)
		var writer = BitWriter()
		EntropyCodeWriter.writeContextMap(one, writer: &writer)
		#expect(writer.bitsWritten == 0)

		let two = SectionOptimizer.modularCode(
			tokenStreams: [tokens + [Token(context: 1, value: 3)]],
			contextCount: 2, extraDCPrecision: 0)
		var twoWriter = BitWriter()
		EntropyCodeWriter.writeContextMap(two, writer: &twoWriter)
		#expect(twoWriter.bitsWritten > 0)
	}

	@Test(
		"a single-leaf modular stream decodes in the native decoder",
		.disabled("pending implementation"))
	func oneContextCodeRoundTripsThroughNativeDecoder() throws {}

	// MARK: Clustering against earlier DC groups

	@Test(
		"the first new cluster is always promoted, from the context farthest by KL",
		.disabled("pending implementation"))
	func fastClusterStartsFromFarthestByKLDivergence() throws {}

	@Test(
		"with no budget left every context goes to an earlier histogram",
		.disabled("pending implementation"))
	func exhaustedBudgetAssignsEveryContextToPrevious() throws {}

	@Test(
		"contexts close to an earlier histogram reuse it by KL divergence",
		.disabled("pending implementation"))
	func fastClusterAssignsToPreviousByKLDivergence() throws {}

	@Test(
		"new clusters are numbered after previous ones and only they absorb counts",
		.disabled("pending implementation"))
	func fastClusterPromotesOnlyBeyondPrevious() throws {}

	@Test(
		"encoded histograms read back as ANS frequencies or 2^(15-depth)",
		.disabled("pending implementation"))
	func previousHistogramFromEncodedCodes() throws {}

	// MARK: Local DC modular streams

	@Test(
		"each DC group's local trees are sized by that group's own pixels",
		.disabled("pending implementation"))
	func localTreesUseEachDCGroupsOwnPixelCount() throws {}

	@Test(
		"a streaming DC global section carries no modular tree",
		.disabled("pending implementation"))
	func streamingDCGlobalWritesNoTree() throws {}

	@Test(
		"each local stream writes GroupHeader without the global tree and its own no-lz77 codes",
		.disabled("pending implementation"))
	func localStreamsWriteOwnHeaderAndCodes() throws {}

	@Test(
		"local stream codes keep the default uint config and log_alpha 8",
		.disabled("pending implementation"))
	func streamingModularCodeUsesDefaultUintAndLogAlpha8() throws {}

	@Test(
		"streaming output above eight groups decodes independently",
		.disabled("pending implementation"))
	func streamingOutputAboveEightGroupsDecodes() throws {}

	// MARK: DC group 0 heuristics

	@Test(
		"the coefficient order comes from DC group 0 alone",
		.disabled("pending implementation"))
	func streamingCoeffOrderUsesDCGroupZeroOnly() throws {}

	@Test(
		"the block context map comes from DC group 0 alone",
		.disabled("pending implementation"))
	func streamingBlockContextMapUsesDCGroupZeroOnly() throws {}

	// MARK: Per-DC-group AC histograms

	@Test(
		"each set adds at most the budget left by earlier sets",
		.disabled("pending implementation"))
	func streamingBudgetLimitsNewClustersPerSet() throws {}

	@Test(
		"the first set's prefix-or-ANS choice holds for every set",
		.disabled("pending implementation"))
	func firstSetDecidesPrefixForAllSets() throws {}

	@Test(
		"empty first-set contexts map to the fixed flat histogram, which keeps its first-use index",
		.disabled("pending implementation"))
	func emptyContextsUseFixedHistogramAtFirstUse() throws {}

	@Test(
		"under prefix coding the fixed histogram is an 8-bit code read back as 2^7 per symbol",
		.disabled("pending implementation"))
	func fixedHistogramPrefixFormIsDepthEight() throws {}

	@Test(
		"unused histograms are dropped and the rest renumbered by first use",
		.disabled("pending implementation"))
	func removeUnusedHistogramsRenumbersByFirstUse() throws {}

	@Test(
		"later sets reuse earlier histograms without changing them",
		.disabled("pending implementation"))
	func laterSetsReuseEarlierHistogramsUnchanged() throws {}
}
