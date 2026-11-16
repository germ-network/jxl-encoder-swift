import Testing

@testable import JXLEncoder

@Suite("Coefficient ordering")
struct CoeffOrderContractTests {
	@Test(.disabled("Pending seeded sampling implementation"))
	func sampledStatisticsFollowGroupRasterAndSourceCursor() {}

	@Test(.disabled("Pending packed JPEG statistics implementation"))
	func jpegSamplingUsesSourceCoefficientStorage() {}

	@Test(.disabled("Pending Float statistics implementation"))
	func quantizedCountsUseFloatAndRankTies() {}

	@Test(.disabled("Pending used-order integration"))
	func usedOrdersAndPermutationTokensMatchReference() {}

	@Test(.disabled("Pending best histogram refinement"))
	func permutationClusteringPreservesSourceMergeAndTieRules() {}

	@Test(.disabled("Pending context-aware RLE implementation"))
	func permutationRunsPreserveContextsAndThresholds() {}

	@Test(.disabled("Pending adaptive hybrid selection"))
	func permutationHybridSelectionPreservesCandidateTiesAndLengths() {}

	@Test(.disabled("Pending default entropy preparation"))
	func permutationEntropyUsesDefaultSourcePolicy() {}
}
