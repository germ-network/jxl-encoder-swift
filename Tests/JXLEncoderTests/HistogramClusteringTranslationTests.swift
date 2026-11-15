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
		let mergeHistograms = try histograms(from: fixture)
		let actual = SwiftEntropySemanticEncoding.clusters(
			histograms: mergeHistograms, limit: 4)
		assertFloatFields(actual, match: fixture.expected)

		let roundedTotal = try EntropyReferenceFixture.load(
			"clusters_rounded_float_total_fast")
		let roundedHistograms = try histograms(from: roundedTotal)
		let rounded = SwiftEntropySemanticEncoding.clusters(
			histograms: roundedHistograms, limit: 1)
		assertFloatFields(rounded, match: roundedTotal.expected)
		guard
			case .floats(let inputEntropies)? = roundedTotal.expected.fields[
				"entropy.clusters.input_shannon_entropy"],
			case .floats(let outputEntropies)? = roundedTotal.expected.fields[
				"entropy.clusters.output_shannon_entropy"]
		else { throw SemanticDumpError.unimplemented }
		var first = roundedHistograms[0]
		var second = roundedHistograms[1]
		first.computeBitCost()
		second.computeBitCost()
		let expectedDistance =
			outputEntropies[0] - inputEntropies[0]
			- inputEntropies[1]
		#expect(
			HistogramCluster.distance(first, second).bitPattern
				== expectedDistance.bitPattern)
	}

	@Test
	func fastClusteringMatchesThresholdTieAndMergeFixtures() throws {
		for name in [
			"clusters_fast_identical", "clusters_ties_fast",
			"clusters_distance_48_fast", "clusters_distance_56_fast",
			"clusters_distance_64_fast", "clusters_farthest_fast",
			"clusters_fast_merge", "clusters_over_eight_fast",
			"clusters_rounded_float_total_fast",
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
		for (name, expectedPrefixCode) in [
			("coder_choice_99_mixed", true),
			("coder_choice_100_mixed", false),
			("coder_choice_100_singletons", true),
		] {
			let fixture = try EntropyReferenceFixture.load(name)
			let contextCount = try fixture.integers(
				fixture.input, "input.coder_choice.context_count")[0]
			let pairs = try fixture.integers(
				fixture.input, "input.coder_choice.tokens")
			guard pairs.count.isMultiple(of: 2) else {
				throw SemanticDumpError.unimplemented
			}
			let baseCode = EntropyCode(
				contextMap: Array(repeating: 0, count: Int(contextCount)),
				prefixCodes: [])
			var section = SectionWriter(mode: .staging(baseCode))
			for index in stride(from: 0, to: pairs.count, by: 2) {
				section.write(
					token: Token(
						context: UInt32(pairs[index]),
						value: UInt32(pairs[index + 1])))
			}
			var sections = [section]
			let actual = SectionOptimizer.optimize(
				sections: &sections, range: 0..<sections.count,
				baseCode: baseCode, allowANS: true)
			let expectedUsePrefixCode = try fixture.integers(
				fixture.expected, "entropy.coder_choice.use_prefix_code")
			let expectedContextMap = try fixture.integers(
				fixture.expected, "entropy.coder_choice.context_map"
			).map(UInt8.init)
			#expect(expectedUsePrefixCode == [expectedPrefixCode ? 1 : 0])
			#expect((actual.ansHistograms == nil) == expectedPrefixCode)
			#expect(actual.contextMap == expectedContextMap)
			if name == "coder_choice_100_singletons" {
				#expect(actual.contextMap.allSatisfy { $0 == 0 })
				#expect(actual.ansInfoTables == nil)
			}
		}
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
