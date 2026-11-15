import Testing

@testable import JXLEncoder

@Suite("Upstream e4 histogram clustering")
struct HistogramClusteringTranslationTests {
	@Test
	func shannonCostsMatchPinnedNEONIntermediates() throws {
		var empty = Histogram()
		empty.computeBitCost()
		#expect(empty.bitCost.bitPattern == Float.zero.bitPattern)
		var singleton = Histogram()
		singleton.add(0)
		singleton.computeBitCost()
		#expect(singleton.bitCost.bitPattern == Float.zero.bitPattern)
		let fixture = try EntropyReferenceFixture.load("clusters_fast_merge")
		let histograms = try histograms(from: fixture)
		let actual = SwiftEntropySemanticEncoding.clusters(
			histograms: histograms, limit: 4)
		assertFloatFields(actual, match: fixture.expected)
	}

	@Test
	func fastClusteringMatchesThresholdTieAndMergeFixtures() throws {
		for name in [
			"clusters_fast_identical", "clusters_ties_fast",
			"clusters_distance_48_fast", "clusters_distance_56_fast",
			"clusters_distance_64_fast", "clusters_farthest_fast",
			"clusters_fast_merge", "clusters_over_eight_fast",
		] {
			let fixture = try EntropyReferenceFixture.load(name)
			let histograms = try histograms(from: fixture)
			let limit = try fixture.integers(fixture.input, "input.clusters.limit")
			let actual = SwiftEntropySemanticEncoding.clusters(
				histograms: histograms, limit: Int(limit[0]))
			#expect(
				actual.differences(
					from: fixture.expected,
					excludingFields: shannonFields
				).isEmpty,
				Comment(rawValue: name))
			assertFloatFields(actual, match: fixture.expected)
		}
	}

	@Test
	func fullContextClusteringPreservesUnusedContextsAndUpstreamLimit() throws {
		let fixture = try EntropyReferenceFixture.load("clusters_default_cap_fast")
		let histograms = try histograms(from: fixture)
		let limit = try fixture.integers(fixture.input, "input.clusters.limit")
		let actual = SwiftEntropySemanticEncoding.clusters(
			histograms: histograms, limit: Int(limit[0]))
		#expect(
			actual.differences(
				from: fixture.expected, excludingFields: shannonFields
			).isEmpty)
		assertFloatFields(actual, match: fixture.expected)
		#expect(HistogramCluster.clustersLimit == 128)
		let sparse = [Histogram(), histograms[0], Histogram()]
		let clustered = HistogramCluster.cluster(sparse)
		#expect(clustered.contextMap.count == 3)
		#expect(clustered.contextMap == [0, 0, 0])
	}

	@Test
	func prefixSelectionMatchesOriginalHistogramSingletonFixtures() throws {
		let short = mixedHistogram(first: 50, second: 49)
		#expect(
			SectionOptimizer.usesPrefixCode(
				originalHistograms: [short], totalTokens: 99))

		let mixed = mixedHistogram(first: 50, second: 50)
		#expect(
			!SectionOptimizer.usesPrefixCode(
				originalHistograms: [Histogram(), mixed], totalTokens: 100))

		let originalSingletons = (0..<100).map { index in
			var histogram = Histogram()
			histogram.add(UInt32(index % StaticEntropyCodes.alphabetSize))
			return histogram
		}
		let singletonSelection = SectionOptimizer.usesPrefixCode(
			originalHistograms: originalSingletons, totalTokens: 100)
		#expect(singletonSelection)
		let merged = HistogramCluster.cluster(
			originalSingletons, limit: SectionOptimizer.clustersLimit)
		#expect(merged.clusters.count == 1)
		#expect(merged.clusters[0].counts.filter { $0 > 0 }.count > 1)

		var singletonSection = SectionWriter(mode: .staging(.staticAC))
		for context in 0..<100 {
			singletonSection.write(
				token: Token(
					context: UInt32(context),
					value: UInt32(context % StaticEntropyCodes.alphabetSize)))
		}
		var singletonSections = [singletonSection]
		let singletonOptimization = SectionOptimizer.optimize(
			sections: &singletonSections, range: 0..<singletonSections.count,
			baseCode: .staticAC, allowANS: true)
		#expect(singletonOptimization.contextMap.count == EntropyCode.staticAC.contextCount)
		#expect(singletonOptimization.contextMap.allSatisfy { $0 == 0 })
		#expect(singletonOptimization.ansHistograms == nil)
		#expect(singletonOptimization.ansInfoTables == nil)

		#expect(
			SectionOptimizer.usesPrefixCode(
				originalHistograms: [Histogram(), Histogram()], totalTokens: 0))
	}

	@Test
	func sectionOptimizerUsesUpstreamDecisionAndSelectedANSHistograms() throws {
		let fixture = try EntropyReferenceFixture.load("ans_cost_approx_step2_witness")
		let counts = try fixture.integers(
			fixture.input, "input.histogram.counts"
		).map(UInt32.init)
		let selected = ANSEncodingHistogram.computeBest(
			counts: counts, strategy: .approximate)
		var section = SectionWriter(mode: .staging(.staticAC))
		for (symbol, count) in counts.enumerated() {
			for _ in 0..<count {
				section.write(token: Token(context: 0, value: UInt32(symbol)))
			}
		}
		var sections = [section]
		let optimized = SectionOptimizer.optimize(
			sections: &sections, range: 0..<sections.count,
			baseCode: .staticAC, allowANS: true)
		#expect(optimized.ansHistograms?.count == 1)
		#expect(optimized.ansHistograms?.first?.method == selected.method)
		#expect(
			optimized.ansHistograms?.first?.alphabetSize == selected.alphabetSize)
		#expect(
			Array(
				optimized.ansHistograms?.first?.normalizedCounts.prefix(
					selected.alphabetSize) ?? []) == selected.normalizedCounts)
		#expect(
			optimized.ansInfoTables?.first?.map(\.freq)
				== selected.normalizedCounts.prefix(selected.alphabetSize).map {
					$0
				})
		#expect(selected.method == 7)
		#expect(sections[0].staged.isEmpty)

		var rawSection = section
		rawSection.writeRaw(1, 1)
		var rawSections = [rawSection]
		let prefixFallback = SectionOptimizer.optimize(
			sections: &rawSections, range: 0..<rawSections.count,
			baseCode: .staticAC, allowANS: true)
		#expect(prefixFallback.ansInfoTables == nil)
		#expect(prefixFallback.ansHistograms == nil)

		var eligibleSections = [section]
		let eligible = SectionOptimizer.optimize(
			sections: &eligibleSections, range: 0..<eligibleSections.count,
			baseCode: .staticAC, allowANS: true)
		#expect(eligible.ansHistograms?.count == 1)

		var forcedPrefixSections = [section]
		let forcedPrefix = SectionOptimizer.optimize(
			sections: &forcedPrefixSections,
			range: 0..<forcedPrefixSections.count,
			baseCode: .staticAC, allowANS: false)
		#expect(forcedPrefix.ansInfoTables == nil)
		#expect(forcedPrefix.ansHistograms == nil)
	}
}

private func mixedHistogram(first: UInt32, second: UInt32) -> Histogram {
	var histogram = Histogram()
	histogram.counts[0] = first
	histogram.counts[1] = second
	histogram.totalCount = Int(first + second)
	return histogram
}

private func histograms(from fixture: EntropyReferenceFixture) throws -> [Histogram] {
	let lengths = try fixture.integers(fixture.input, "input.clusters.lengths")
	let counts = try fixture.integers(fixture.input, "input.clusters.counts")
	var offset = 0
	var result: [Histogram] = []
	for length in lengths {
		guard length > 0, length <= 64 else {
			throw SemanticDumpError.unimplemented
		}
		let end = offset + Int(length)
		guard end <= counts.count else { throw SemanticDumpError.unimplemented }
		var histogram = Histogram()
		for (symbol, count) in counts[offset..<end].enumerated() {
			guard (0...Int64(Int32.max)).contains(count) else {
				throw SemanticDumpError.unimplemented
			}
			histogram.counts[symbol] = UInt32(count)
			histogram.totalCount += Int(count)
		}
		offset = end
		result.append(histogram)
	}
	guard offset == counts.count else { throw SemanticDumpError.unimplemented }
	return result
}

private let shannonFields: Set<String> = [
	"entropy.clusters.input_shannon_entropy",
	"entropy.clusters.output_shannon_entropy",
]

private func assertFloatFields(_ actual: SemanticDump, match expected: SemanticDump) {
	for field in shannonFields {
		guard
			case .floats(let actualValues)? = actual.fields[field],
			case .floats(let expectedValues)? = expected.fields[field]
		else {
			Issue.record("Missing Shannon entropy field: \(field)")
			continue
		}
		#expect(
			actualValues.map(\.bitPattern) == expectedValues.map(\.bitPattern),
			Comment(rawValue: field))
	}
}
