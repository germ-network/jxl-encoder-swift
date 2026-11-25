import Foundation
import Testing

@testable import JXLEncoder

/// Frames above eight groups are coded the way libjxl streams them: histograms,
/// coefficient order, block model and modular trees are built DC group by DC
/// group rather than over the whole frame. Frames at or below eight groups keep
/// the one-shot coding, which the existing byte-equality tests pin.
@Suite("Streaming entropy")
struct StreamingEntropyTests {
	static func histogram(_ counts: [Int: UInt32]) -> Histogram {
		var histogram = Histogram()
		for (symbol, count) in counts {
			for _ in 0..<count { histogram.add(UInt32(symbol)) }
		}
		return histogram
	}

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
		"the first new cluster is always promoted, from the context farthest by KL")
	func fastClusterStartsFromFarthestByKLDivergence() throws {
		let previous = [Self.histogram([0: 500, 1: 500])]
		let input = [
			Self.histogram([0: 90, 1: 90]),
			Self.histogram([10: 20, 11: 20]),
			Self.histogram([0: 40, 1: 40]),
		]
		let far = HistogramCluster.fastCluster(
			input, maxHistograms: 1, previous: previous)
		#expect(far.symbols == [0, 1, 0])
		#expect(far.clusters.count == 1)

		// Every context already matches the earlier histogram, so no
		// divergence is positive and the largest context starts the cluster.
		let same = [
			Self.histogram([0: 30, 1: 30]), Self.histogram([0: 90, 1: 90]),
			Self.histogram([0: 40, 1: 40]),
		]
		let fallback = HistogramCluster.fastCluster(
			same, maxHistograms: 1, previous: previous)
		#expect(fallback.symbols[1] == 1)
	}

	@Test(
		"with no budget left every context goes to an earlier histogram")
	func exhaustedBudgetAssignsEveryContextToPrevious() throws {
		let previous = [
			Self.histogram([0: 500, 1: 500]), Self.histogram([10: 500, 11: 500]),
		]
		let input = [
			Self.histogram([0: 9, 1: 11]), Histogram(),
			Self.histogram([10: 7, 11: 5]),
		]
		let result = HistogramCluster.fastCluster(
			input, maxHistograms: 0, previous: previous)
		#expect(result.clusters.isEmpty)
		#expect(result.symbols == [0, 0, 1])
	}

	@Test(
		"contexts close to an earlier histogram reuse it by KL divergence")
	func fastClusterAssignsToPreviousByKLDivergence() throws {
		let previous = [
			Self.histogram([0: 500, 1: 500]), Self.histogram([10: 500, 11: 500]),
		]
		let input = [
			Self.histogram([10: 30, 11: 25]),
			Self.histogram([0: 20, 1: 30]),
			Self.histogram([10: 5, 11: 2]),
			Self.histogram([30: 100]),
		]
		let result = HistogramCluster.fastCluster(
			input, maxHistograms: 1, previous: previous)
		#expect(result.symbols == [1, 0, 1, 2])
		let missing = HistogramCluster.klDivergence(
			Self.histogram([0: 4, 5: 4]), coding: previous[0])
		#expect(missing == .infinity)
		#expect(
			HistogramCluster.klDivergence(
				Self.histogram([0: 4, 1: 4]), coding: previous[0]) < 0.01)
		#expect(
			HistogramCluster.klDivergence(Histogram(), coding: previous[0]) == 0)
		#expect(result.clusters.count == 1)
	}

	@Test(
		"new clusters are numbered after previous ones and only they absorb counts")
	func fastClusterPromotesOnlyBeyondPrevious() throws {
		let previous = [Self.histogram([0: 500, 1: 500])]
		let input = [
			Self.histogram([20: 1000]), Self.histogram([40: 1000, 41: 1000]),
			Self.histogram([40: 10, 41: 10]), Self.histogram([0: 4, 1: 6]),
		]
		let result = HistogramCluster.fastCluster(
			input, maxHistograms: 2, previous: previous)
		#expect(result.clusters.count == 2)
		#expect(Set(result.symbols[0...1]) == [1, 2])
		#expect(result.symbols[2] == result.symbols[1])
		#expect(result.symbols[3] == 0)
		let absorbed = result.clusters[Int(result.symbols[1]) - 1]
		#expect(absorbed.totalCount == 2020)
		let untouched = result.clusters[Int(result.symbols[0]) - 1]
		#expect(untouched.totalCount == 1000)
	}

	@Test(
		"encoded histograms read back as ANS frequencies or 2^(15-depth)")
	func previousHistogramFromEncodedCodes() throws {
		var source = Self.histogram([0: 700, 1: 200, 2: 100])
		source.computeBitCost()
		let encoded = ANSEncodingHistogram.computeBest(
			counts: source.counts, strategy: .fast)
		let fromANS = Histogram(encodedANS: encoded)
		#expect(fromANS.counts.map(Int.init) == encoded.normalizedCounts)
		#expect(fromANS.totalCount == encoded.normalizedCounts.reduce(0, +))

		let prefix = PrefixCode(depths: [1, 2, 0, 2], bits: [0, 1, 0, 3])
		let fromPrefix = Histogram(encodedPrefix: prefix)
		#expect(fromPrefix.counts == [16384, 8192, 0, 8192])
		#expect(fromPrefix.totalCount == 32768)
	}

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
