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

	@Test(.disabled("Pending implementation"))
	func prefixSelectionMatchesOriginalHistogramSingletonFixtures() throws {
		Issue.record(
			"Pin 99/100 tokens and original singleton/empty versus mixed histograms")
	}

	@Test(.disabled("Pending implementation"))
	func sectionOptimizerUsesUpstreamDecisionAndSelectedANSHistograms() throws {
		Issue.record(
			"Pin full-context integration, immutable approximate ANS result and raw-bit fallback"
		)
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
