import Foundation
import Testing

@testable import JXLEncoder

@Suite("Entropy reference contracts")
struct EntropyReferenceTests {
	private func exportCurrentStreamDump(_ dump: SemanticDump, name: String) throws {
		guard
			let path = ProcessInfo.processInfo.environment[
				"JXL_ENTROPY_STREAM_EXPORT_DIR"]
		else { return }
		let directory = URL(fileURLWithPath: path, isDirectory: true)
		try FileManager.default.createDirectory(
			at: directory, withIntermediateDirectories: true)
		try dump.serialized.write(
			to: directory.appendingPathComponent(name + ".current.sem"),
			atomically: true, encoding: .utf8)
	}

	private func integers(_ dump: SemanticDump, _ field: String) throws -> [Int64] {
		guard case .integers(let values)? = dump.fields[field] else {
			throw SemanticDumpError.malformedEntropyFixture(
				name: "coefficient", field: field)
		}
		return values
	}

	@Test
	func normalizedTablesAndPrecisionMatchReference() throws {
		for (name, knownDifferences) in [
			("ans_empty", Set<String>()),
			("ans_all_zero", Set<String>()),
			("ans_singleton_precise", Set<String>()),
			(
				"ans_two_symbol_approximate",
				Set([
					"entropy.histogram.normalized",
					"entropy.histogram.serialized_method",
					"entropy.histogram.freqs", "entropy.histogram.reverse_map",
					"entropy.histogram.bit_count", "entropy.histogram.bytes",
				])
			),
			(
				"ans_precision_fast",
				Set([
					"entropy.histogram.normalized", "entropy.histogram.freqs",
					"entropy.histogram.reverse_map",
					"entropy.histogram.serialized_shift",
					"entropy.histogram.bit_count", "entropy.histogram.bytes",
				])
			),
			(
				"ans_sparse_precise",
				Set([
					"entropy.histogram.normalized", "entropy.histogram.freqs",
					"entropy.histogram.reverse_map",
					"entropy.histogram.serialized_shift",
					"entropy.histogram.bit_count", "entropy.histogram.bytes",
				])
			),
			(
				"ans_skewed_approximate",
				Set([
					"entropy.histogram.normalized", "entropy.histogram.freqs",
					"entropy.histogram.reverse_map",
					"entropy.histogram.serialized_shift",
					"entropy.histogram.bit_count", "entropy.histogram.bytes",
				])
			),
			(
				"ans_alphabet48_fast",
				Set([
					"entropy.histogram.serialized_method",
					"entropy.histogram.serialized_shift",
					"entropy.histogram.bit_count", "entropy.histogram.bytes",
				])
			),
			(
				"ans_alphabet64_fast",
				Set([
					"entropy.histogram.serialized_method",
					"entropy.histogram.serialized_shift",
					"entropy.histogram.bit_count", "entropy.histogram.bytes",
				])
			),
		] {
			let fixture = try EntropyReferenceFixture.load(name)
			guard
				case .integers(let counts)? = fixture.input.fields[
					"input.histogram.counts"],
				case .integers(let logAlpha)? = fixture.input.fields[
					"input.histogram.log_alpha_size"]
			else { throw SemanticDumpError.unimplemented }
			let actual = SwiftEntropySemanticEncoding.histogram(
				counts: counts.map(Int.init), logAlphaSize: Int(logAlpha[0]))
			let differences = actual.differences(from: fixture.expected)
			let differenceFields = Set(differences.map(\.field))
			#expect(differenceFields == knownDifferences, "\(name): \(differences)")
			#expect(
				actual.differences(
					from: fixture.expected, excludingFields: knownDifferences
				)
				.isEmpty,
				"\(name) has unexpected matching-field differences")
			for field in knownDifferences {
				let fieldDifferences = differences.filter { $0.field == field }
				withKnownIssue(Comment(rawValue: "GER-3386: \(field)")) {
					#expect(
						fieldDifferences.isEmpty,
						"\(name): \(fieldDifferences)")
				}
			}
		}
	}

	@Test
	func contextMapSimpleChoiceIsStrictlyCheaper() throws {
		let fixture = try EntropyReferenceFixture.load("context_simple_profitability")
		guard
			case .integers(let simpleCost)? = fixture.expected.fields[
				"entropy.context_map.simple_cost"],
			case .integers(let rawCost)? = fixture.expected.fields[
				"entropy.context_map.raw_cost"],
			case .integers(let mtfCost)? = fixture.expected.fields[
				"entropy.context_map.mtf_cost"]
		else { throw SemanticDumpError.unimplemented }
		#expect(fixture.expected.fields["entropy.context_map.simple"] == .integers([1]))
		#expect(simpleCost[0] < rawCost[0])
		#expect(simpleCost[0] < mtfCost[0])
	}

	@Test
	func contextMapRejectsSimpleCodingAtEqualCandidateCost() throws {
		let fixture = try EntropyReferenceFixture.load("context_simple_tie_candidate")
		#expect(
			fixture.expected.fields["entropy.context_map.simple_cost"]
				== fixture.expected.fields["entropy.context_map.raw_cost"])
		#expect(fixture.expected.fields["entropy.context_map.simple"] == .integers([0]))
		#expect(fixture.expected.fields["entropy.context_map.use_mtf"] == .integers([0]))
	}

	@Test
	func contextMapTokenCountsComeFromPinnedCandidateProbe() throws {
		for (name, count) in [("context_prefix_99", 99), ("context_ans_100", 100)] {
			let fixture = try EntropyReferenceFixture.load(name)
			#expect(
				fixture.expected.fields["entropy.context_map.token_count"]
					== .integers([Int64(count)]))
			#expect(
				fixture.expected.fields["entropy.context_map.token_count_status"]
					== .integers([1]))
		}
		let mtf = try EntropyReferenceFixture.load("context_mtf_ans")
		#expect(mtf.expected.fields["entropy.context_map.use_mtf"] == .integers([1]))
		#expect(
			mtf.expected.fields["entropy.context_map.token_count_status"]
				== .integers([2]))
		#expect(
			mtf.expected.fields["entropy.context_map.token_count"]
				== mtf.expected.fields["entropy.context_map.mtf_token_count"])
		let rle = try EntropyReferenceFixture.load("context_raw_rle")
		#expect(rle.expected.fields["entropy.context_map.simple"] == .integers([0]))
		#expect(rle.expected.fields["entropy.context_map.use_mtf"] == .integers([0]))
		#expect(rle.expected.fields["entropy.context_map.token_count"] == .integers([12]))
		#expect(
			rle.expected.fields["entropy.context_map.token_count"]
				== rle.expected.fields["entropy.context_map.raw_token_count"])
		#expect(
			rle.expected.fields["entropy.context_map.token_count_status"]
				== .integers([1]))
		#expect(
			rle.expected.fields["entropy.context_map.token_count"]
				!= rle.input.fields["input.context_map.map_length"])
	}

	@Test
	func contextMapTokenStatusSeparatesInapplicableFromUnobserved() throws {
		for (name, status) in [("context_single_histogram", 0), ("context_prefix_99", 3)] {
			let fixture = try EntropyReferenceFixture.load(name)
			guard
				case .integers(let entries)? = fixture.input.fields[
					"input.context_map.entries"],
				case .integers(let numHistograms)? = fixture.input.fields[
					"input.context_map.num_histograms"],
				case .integers(let allowANS)? = fixture.input.fields[
					"input.context_map.allow_ans"]
			else { throw SemanticDumpError.unimplemented }
			let swift = try SwiftEntropySemanticEncoding.contextMap(
				entries: entries.map(UInt8.init),
				numHistograms: Int(numHistograms[0]),
				allowANS: allowANS[0] != 0)
			#expect(
				swift.fields["entropy.context_map.token_count_status"]
					== .integers([Int64(status)]))
			#expect(swift.fields["entropy.context_map.token_count"] == .integers([-1]))
		}
	}

	@Test
	func contextMapRawWinsExactCostTie() throws {
		let fixture = try EntropyReferenceFixture.load("context_tie_raw_mtf")
		#expect(
			fixture.expected.fields["entropy.context_map.raw_cost"]
				== fixture.expected.fields["entropy.context_map.mtf_cost"])
		#expect(
			fixture.expected.fields["entropy.context_map.use_mtf"]
				== .integers([0]))
	}

	@Test
	func malformedFixturesAreRejectedBeforeEncodingHelpers() throws {
		let histogram = try EntropyReferenceFixture.load("ans_singleton_precise")
		let badCounts = try SemanticDump(
			parsing: histogram.input.serialized.replacingOccurrences(
				of: "input.histogram.counts i 4 0 0 0 10",
				with: "input.histogram.counts i 4 0 0 0 2147483648"))
		#expect(throws: Error.self) {
			try EntropyReferenceFixture.validate(
				name: "ans_singleton_precise", input: badCounts,
				expected: histogram.expected)
		}
		let badType = try SemanticDump(
			parsing: histogram.expected.serialized.replacingOccurrences(
				of: "entropy.histogram.freqs i", with: "entropy.histogram.freqs f"))
		#expect(throws: Error.self) {
			try EntropyReferenceFixture.validate(
				name: "ans_singleton_precise", input: histogram.input,
				expected: badType)
		}
		let badBitCount = try SemanticDump(
			parsing: histogram.expected.serialized.replacingOccurrences(
				of: "entropy.histogram.bit_count i 1 7",
				with: "entropy.histogram.bit_count i 1 9223372036854775807"))
		#expect(throws: Error.self) {
			try EntropyReferenceFixture.validate(
				name: "ans_singleton_precise", input: histogram.input,
				expected: badBitCount)
		}
		for invalidLogAlpha in [4, 9] {
			let invalidConfig = try SemanticDump(
				parsing: histogram.input.serialized.replacingOccurrences(
					of: "input.histogram.log_alpha_size i 1 7",
					with:
						"input.histogram.log_alpha_size i 1 \(invalidLogAlpha)"
				))
			#expect(throws: Error.self) {
				try EntropyReferenceFixture.validate(
					name: "ans_singleton_precise", input: invalidConfig,
					expected: histogram.expected)
			}
		}
		let tooWideCounts = Array(repeating: "0", count: 33).joined(separator: " ")
		let overCapacity = try SemanticDump(
			parsing: histogram.input.serialized
				.replacingOccurrences(
					of: "input.histogram.counts i 4 0 0 0 10",
					with: "input.histogram.counts i 33 \(tooWideCounts)"
				)
				.replacingOccurrences(
					of: "input.histogram.log_alpha_size i 1 7",
					with: "input.histogram.log_alpha_size i 1 5"))
		#expect(throws: Error.self) {
			try EntropyReferenceFixture.validate(
				name: "ans_singleton_precise", input: overCapacity,
				expected: histogram.expected)
		}
		let cluster = try EntropyReferenceFixture.load("clusters_fast_identical")
		let badMap = try SemanticDump(
			parsing: cluster.expected.serialized.replacingOccurrences(
				of: "entropy.clusters.map i 2 0 0",
				with: "entropy.clusters.map i 1 0"))
		#expect(throws: Error.self) {
			try EntropyReferenceFixture.validate(
				name: "clusters_fast_identical", input: cluster.input,
				expected: badMap)
		}
		let badLengths = try SemanticDump(
			parsing: cluster.input.serialized.replacingOccurrences(
				of: "input.clusters.lengths i 2 2 2",
				with: "input.clusters.lengths i 2 1 2"))
		#expect(throws: Error.self) {
			try EntropyReferenceFixture.validate(
				name: "clusters_fast_identical", input: badLengths,
				expected: cluster.expected)
		}
		let clusterOverflow = try EntropyReferenceFixture.load("clusters_farthest_fast")
		let overflowingTotals = try SemanticDump(
			parsing: clusterOverflow.expected.serialized.replacingOccurrences(
				of: "entropy.clusters.total_counts i 2 200 140",
				with: "entropy.clusters.total_counts i 2 \(Int64.max) \(Int64.max)")
		)
		#expect(throws: Error.self) {
			try EntropyReferenceFixture.validate(
				name: "clusters_farthest_fast", input: clusterOverflow.input,
				expected: overflowingTotals)
		}
		let context = try EntropyReferenceFixture.load("context_ans_100")
		let outOfRangeMap = try SemanticDump(
			parsing: context.input.serialized.replacingOccurrences(
				of: "input.context_map.entries i 100 3 7",
				with: "input.context_map.entries i 100 16 7"))
		#expect(throws: Error.self) {
			try EntropyReferenceFixture.validate(
				name: "context_ans_100", input: outOfRangeMap,
				expected: context.expected)
		}
		for invalidHistogramCount in [0, 256] {
			#expect(throws: Error.self) {
				try SwiftEntropySemanticEncoding.contextMap(
					entries: [0], numHistograms: invalidHistogramCount,
					allowANS: false)
			}
		}
		#expect(throws: Error.self) {
			try SwiftEntropySemanticEncoding.contextMap(
				entries: [], numHistograms: 1, allowANS: false)
		}
		let contextTie = try EntropyReferenceFixture.load("context_tie_raw_mtf")
		let badCost = try SemanticDump(
			parsing: contextTie.expected.serialized.replacingOccurrences(
				of: "entropy.context_map.mtf_cost i 1 23",
				with: "entropy.context_map.mtf_cost i 1 22"))
		#expect(throws: Error.self) {
			try EntropyReferenceFixture.validate(
				name: "context_tie_raw_mtf", input: contextTie.input,
				expected: badCost)
		}
		let contextMTF = try EntropyReferenceFixture.load("context_mtf_ans")
		let emptySelectedTokenCount = try SemanticDump(
			parsing: contextMTF.expected.serialized.replacingOccurrences(
				of: "entropy.context_map.token_count i 1 300",
				with: "entropy.context_map.token_count i 0"))
		#expect(throws: Error.self) {
			try EntropyReferenceFixture.validate(
				name: "context_mtf_ans", input: contextMTF.input,
				expected: emptySelectedTokenCount)
		}
		let emptyMTFCandidateTokenCount = try SemanticDump(
			parsing: contextMTF.expected.serialized.replacingOccurrences(
				of: "entropy.context_map.mtf_token_count i 1 300",
				with: "entropy.context_map.mtf_token_count i 0"))
		#expect(throws: Error.self) {
			try EntropyReferenceFixture.validate(
				name: "context_mtf_ans", input: contextMTF.input,
				expected: emptyMTFCandidateTokenCount)
		}
		let tree = try EntropyReferenceFixture.load("tree_gradient_fixed_8193_dc2")
		let mismatchedTreeInput = try SemanticDump(
			parsing: tree.input.serialized.replacingOccurrences(
				of: "input.tree.total_pixels i 1 8193",
				with: "input.tree.total_pixels i 1 8192"))
		#expect(throws: Error.self) {
			try EntropyReferenceFixture.validate(
				name: "tree_gradient_fixed_8193_dc2", input: mismatchedTreeInput,
				expected: tree.expected)
		}
		let mismatchedTreeNodeCount = try SemanticDump(
			parsing: tree.expected.serialized.replacingOccurrences(
				of: "entropy.tree.node_count i 1 67",
				with: "entropy.tree.node_count i 1 66"))
		#expect(throws: Error.self) {
			try EntropyReferenceFixture.validate(
				name: "tree_gradient_fixed_8193_dc2", input: tree.input,
				expected: mismatchedTreeNodeCount)
		}
		let maximalTreeNodeCount = try SemanticDump(
			parsing: tree.expected.serialized.replacingOccurrences(
				of: "entropy.tree.node_count i 1 67",
				with: "entropy.tree.node_count i 1 \(Int64.max)"))
		#expect(throws: Error.self) {
			try EntropyReferenceFixture.validate(
				name: "tree_gradient_fixed_8193_dc2", input: tree.input,
				expected: maximalTreeNodeCount)
		}
		let maximalTreeTokenCount = try SemanticDump(
			parsing: tree.expected.serialized.replacingOccurrences(
				of: "entropy.tree.token_count i 1 236",
				with: "entropy.tree.token_count i 1 \(Int64.max)"))
		#expect(throws: Error.self) {
			try EntropyReferenceFixture.validate(
				name: "tree_gradient_fixed_8193_dc2", input: tree.input,
				expected: maximalTreeTokenCount)
		}
		let modular = try EntropyReferenceFixture.load("modular_dc_gradient_rows")
		let malformedModularOrder = try SemanticDump(
			parsing: modular.input.serialized.replacingOccurrences(
				of: "input.modular.group0.channel_order i 3 1 0 2",
				with: "input.modular.group0.channel_order i 3 1 1 2"))
		#expect(throws: Error.self) {
			try EntropyReferenceFixture.validate(
				name: "modular_dc_gradient_rows", input: malformedModularOrder,
				expected: modular.expected)
		}
		let malformedModularSamples = try SemanticDump(
			parsing: modular.input.serialized.replacingOccurrences(
				of: "input.modular.group1.channel2 i 6 -30 -20 -10 0 10 20",
				with: "input.modular.group1.channel2 i 5 -30 -20 -10 0 10"))
		#expect(throws: Error.self) {
			try EntropyReferenceFixture.validate(
				name: "modular_dc_gradient_rows", input: malformedModularSamples,
				expected: modular.expected)
		}
		let ac = try EntropyReferenceFixture.load("ac_tokens_tiny_map")
		let invalidACContextCount = try SemanticDump(
			parsing: ac.input.serialized.replacingOccurrences(
				of: "input.ac_tokens.context_count i 1 4",
				with: "input.ac_tokens.context_count i 1 15"))
		#expect(throws: Error.self) {
			try EntropyReferenceFixture.validate(
				name: "ac_tokens_tiny_map", input: invalidACContextCount,
				expected: ac.expected)
		}
		let invalidACWidth = try SemanticDump(
			parsing: ac.input.serialized.replacingOccurrences(
				of: "input.ac_tokens.width i 1 2",
				with: "input.ac_tokens.width i 1 0"))
		#expect(throws: Error.self) {
			try EntropyReferenceFixture.validate(
				name: "ac_tokens_tiny_map", input: invalidACWidth,
				expected: ac.expected)
		}
	}

	@Test
	func malformedStreamLengthsAndFrequenciesAreRejectedBeforeArithmetic() throws {
		let ans = try EntropyReferenceFixture.load("stream_shared_ans")
		for invalidLength in ["-1", "9223372036854775807"] {
			let input = try SemanticDump(
				parsing: ans.input.serialized.replacingOccurrences(
					of: "input.streams.lengths i 2 8 8",
					with: "input.streams.lengths i 2 \(invalidLength) 8"))
			#expect(throws: Error.self) {
				try EntropyReferenceFixture.validate(
					name: "stream_shared_ans", input: input,
					expected: ans.expected)
			}
		}
		let invalidFrequency = try SemanticDump(
			parsing: ans.input.serialized.replacingOccurrences(
				of: "input.streams.frequencies i 2 2048 2048",
				with: "input.streams.frequencies i 2 9223372036854775807 2048"))
		#expect(throws: Error.self) {
			try EntropyReferenceFixture.validate(
				name: "stream_shared_ans", input: invalidFrequency,
				expected: ans.expected)
		}
	}

	@Test
	func fastAndBestClustersMatchReference() throws {
		let clusteringDifferences: Set<String> = [
			"entropy.clusters.map", "entropy.clusters.count",
			"entropy.clusters.alphabet_lengths",
			"entropy.clusters.total_counts",
			"entropy.clusters.histogram_counts",
		]
		let fixtures: [(String, Set<String>)] = [
			("clusters_fast_identical", Set<String>()),
			("clusters_best_identical", Set<String>()),
			("clusters_ties_fast", Set<String>()),
			("clusters_distance_48_fast", clusteringDifferences),
			("clusters_distance_56_fast", clusteringDifferences),
			("clusters_distance_64_fast", Set<String>()),
			("clusters_default_cap_fast", Set<String>()),
			("clusters_farthest_fast", Set<String>()),
			("clusters_over_eight_fast", Set<String>()),
			("clusters_fast_merge", clusteringDifferences),
			("clusters_best_merge", Set<String>()),
		]
		for (name, knownDifferences) in fixtures {
			let fixture = try EntropyReferenceFixture.load(name)
			guard
				case .integers(let lengths)? = fixture.input.fields[
					"input.clusters.lengths"],
				case .integers(let counts)? = fixture.input.fields[
					"input.clusters.counts"],
				case .integers(let limit)? = fixture.input.fields[
					"input.clusters.limit"]
			else { throw SemanticDumpError.unimplemented }
			var cursor = 0
			var histograms: [Histogram] = []
			for length in lengths {
				let end = cursor + Int(length)
				guard end <= counts.count else {
					throw SemanticDumpError.unimplemented
				}
				var histogram = Histogram()
				for (symbol, count) in counts[cursor..<end].enumerated() {
					guard count >= 0, count <= Int64(UInt32.max) else {
						throw SemanticDumpError.unimplemented
					}
					histogram.counts[symbol] = UInt32(count)
					histogram.totalCount += Int(count)
				}
				cursor = end
				histograms.append(histogram)
			}
			guard cursor == counts.count else { throw SemanticDumpError.unimplemented }
			let boundaryDistances = [
				"clusters_distance_48_fast": 48,
				"clusters_distance_56_fast": 56,
				"clusters_distance_64_fast": 64,
			]
			if let distance = boundaryDistances[name] {
				#expect(histograms.count == 2)
				var left = histograms[0]
				var right = histograms[1]
				left.computeBitCost()
				right.computeBitCost()
				#expect(HistogramCluster.distance(left, right) == Float(distance))
			}
			let actual: SemanticDump
			if name == "clusters_default_cap_fast" {
				actual = SwiftEntropySemanticEncoding.clusters(
					histograms: histograms)
			} else {
				actual = SwiftEntropySemanticEncoding.clusters(
					histograms: histograms, limit: Int(limit[0]))
			}
			if name == "clusters_distance_48_fast"
				|| name == "clusters_distance_56_fast"
			{
				#expect(
					fixture.expected.fields["entropy.clusters.count"]
						== .integers([2]))
				#expect(actual.fields["entropy.clusters.count"] == .integers([1]))
			}
			if name == "clusters_distance_64_fast" {
				#expect(
					fixture.expected.fields["entropy.clusters.count"]
						== .integers([2]))
				#expect(actual.fields["entropy.clusters.count"] == .integers([2]))
			}
			if name == "clusters_ties_fast" {
				#expect(
					fixture.expected.fields["entropy.clusters.count"]
						== .integers([2]))
				#expect(
					fixture.expected.fields["entropy.clusters.map"]
						== .integers([0, 1, 0]))
			}
			if name == "clusters_farthest_fast" {
				#expect(
					fixture.expected.fields["entropy.clusters.count"]
						== .integers([2]))
				#expect(
					fixture.expected.fields["entropy.clusters.map"]
						== .integers([0, 0, 1, 1]))
			}
			if name == "clusters_over_eight_fast" {
				#expect(histograms.count == 10)
				#expect(
					fixture.expected.fields["entropy.clusters.count"]
						== .integers([9]))
				#expect(
					fixture.expected.fields["entropy.clusters.map"]
						== .integers([0, 1, 2, 3, 4, 5, 6, 7, 8, 0]))
			}
			if name == "clusters_default_cap_fast" {
				#expect(histograms.count == 10)
				#expect(
					fixture.expected.fields["entropy.clusters.count"]
						== .integers([8]))
				#expect(actual.fields["entropy.clusters.count"] == .integers([8]))
			}
			let differences = actual.differences(from: fixture.expected)
			let differenceFields = Set(differences.map(\.field))
			#expect(differenceFields == knownDifferences, "\(name): \(differences)")
			#expect(
				actual.differences(
					from: fixture.expected, excludingFields: knownDifferences
				)
				.isEmpty,
				"\(name) has unexpected matching-field differences")
			for field in knownDifferences {
				let fieldDifferences = differences.filter { $0.field == field }
				withKnownIssue(Comment(rawValue: "GER-3386: \(field)")) {
					#expect(
						fieldDifferences.isEmpty,
						"\(name): \(fieldDifferences)")
				}
			}
		}
	}

	@Test
	func contextMapChoiceMatchesReference() throws {
		for (name, knownDifferences) in [
			("context_single_histogram", Set<String>()),
			(
				"context_simple_two_histograms",
				Set([
					"entropy.context_map.simple",
					"entropy.context_map.entry_bits",
					"entropy.context_map.use_prefix_code",
					"entropy.context_map.bit_count",
					"entropy.context_map.bytes",
				])
			),
			(
				"context_mtf_ans",
				Set([
					"entropy.context_map.use_mtf",
					"entropy.context_map.bit_count",
					"entropy.context_map.bytes",
				])
			),
			(
				"context_raw_ans",
				Set([
					"entropy.context_map.bit_count",
					"entropy.context_map.bytes",
				])
			),
			(
				"context_prefix_99",
				Set(["entropy.context_map.bit_count", "entropy.context_map.bytes"])
			),
			(
				"context_ans_100",
				Set(["entropy.context_map.bit_count", "entropy.context_map.bytes"])
			),
			(
				"context_simple_tie_candidate",
				Set(["entropy.context_map.bit_count", "entropy.context_map.bytes"])
			),
			(
				"context_raw_rle",
				Set([
					"entropy.context_map.bit_count",
					"entropy.context_map.bytes",
					"entropy.context_map.use_prefix_code",
				])
			),
		] {
			let fixture = try EntropyReferenceFixture.load(name)
			guard
				case .integers(let entries)? = fixture.input.fields[
					"input.context_map.entries"],
				case .integers(let numHistograms)? = fixture.input.fields[
					"input.context_map.num_histograms"],
				case .integers(let allowANS)? = fixture.input.fields[
					"input.context_map.allow_ans"]
			else { throw SemanticDumpError.unimplemented }
			let actual = try SwiftEntropySemanticEncoding.contextMap(
				entries: entries.map(UInt8.init),
				numHistograms: Int(numHistograms[0]),
				allowANS: allowANS[0] != 0)
			let probeOnlyFields: Set<String> = [
				"entropy.context_map.token_count",
				"entropy.context_map.token_count_status",
				"entropy.context_map.mtf_entries",
				"entropy.context_map.raw_cost",
				"entropy.context_map.mtf_cost",
				"entropy.context_map.simple_cost",
				"entropy.context_map.raw_token_count",
				"entropy.context_map.mtf_token_count",
			]
			let differences = actual.differences(
				from: fixture.expected, excludingFields: probeOnlyFields)
			let differenceFields = Set(differences.map(\.field))
			#expect(differenceFields == knownDifferences, "\(name): \(differences)")
			#expect(
				actual.differences(
					from: fixture.expected,
					excludingFields: knownDifferences.union(probeOnlyFields)
				)
				.isEmpty,
				"\(name) has unexpected context-map differences")
			for field in knownDifferences {
				let fieldDifferences = differences.filter { $0.field == field }
				withKnownIssue(Comment(rawValue: "GER-3386: \(field)")) {
					#expect(
						fieldDifferences.isEmpty,
						"\(name): \(fieldDifferences)")
				}
			}
		}
	}

	@Test
	func predefinedMATreeMatchesReference() throws {
		for (name, knownDifferences) in [
			(
				"tree_gradient_fixed_8192_dc1",
				Set([
					"entropy.tree.node_count", "entropy.tree.nodes",
					"entropy.tree.token_count", "entropy.tree.tokens",
				])
			),
			("tree_gradient_fixed_8193_dc2", Set<String>()),
		] {
			let fixture = try EntropyReferenceFixture.load(name)
			guard
				case .integers(let dcGroupCount)? = fixture.input.fields[
					"input.tree.dc_group_count"],
				case .integers(let projectionRoot)? = fixture.input.fields[
					"input.tree.projection_root"],
				case .integers(let componentTokenCount)? = fixture.expected.fields[
					"entropy.tree.token_count"]
			else { throw SemanticDumpError.unimplemented }
			let actual = SwiftEntropySemanticEncoding.tree(
				dcGroupCount: Int(dcGroupCount[0]))
			guard
				case .integers(let fullTokens)? = actual.fields[
					"entropy.tree.full_tokens"]
			else { throw SemanticDumpError.unimplemented }
			#expect(projectionRoot == [2])
			#expect(
				actual.fields["entropy.tree.component_root"]
					== .integers(projectionRoot))
			#expect(actual.fields["entropy.tree.full_token_count"] == .integers([313]))
			#expect(actual.fields["entropy.tree.full_node_count"] == .integers([89]))
			#expect(fullTokens.count == 626)
			#expect(fullTokens[3] == Int64(packSigned(Int32(1 + dcGroupCount[0]))))
			var sourceTokens = ContextTree.staticTokens
			sourceTokens[1] = Token(
				context: sourceTokens[1].context,
				value: packSigned(Int32(1 + dcGroupCount[0])))
			#expect(
				fullTokens
					== sourceTokens.flatMap {
						[Int64($0.context), Int64($0.value)]
					})
			#expect(componentTokenCount[0] > 0)
			var projected = SemanticDump()
			for field in ["node_count", "nodes", "token_count", "tokens"] {
				guard let value = actual.fields["entropy.tree.\(field)"] else {
					throw SemanticDumpError.unimplemented
				}
				projected.record(
					"entropy.tree.\(field)", value)
			}
			let comparableFields: Set<String> = [
				"entropy.tree.node_count", "entropy.tree.nodes",
				"entropy.tree.token_count", "entropy.tree.tokens",
			]
			var expected = SemanticDump()
			for field in comparableFields {
				guard let value = fixture.expected.fields[field] else {
					throw SemanticDumpError.unimplemented
				}
				expected.record(field, value)
			}
			let differences = projected.differences(from: expected)
			#expect(
				Set(differences.map(\.field)) == knownDifferences,
				"\(name): \(differences)")
			for field in knownDifferences {
				let fieldDifferences = differences.filter { $0.field == field }
				withKnownIssue(Comment(rawValue: "CT-01: \(field)")) {
					#expect(
						fieldDifferences.isEmpty,
						"\(name): \(fieldDifferences)")
				}
			}
			#expect(
				projected.differences(
					from: expected, excludingFields: knownDifferences
				).isEmpty)
		}
	}

	@Test
	func modularLeafContextsAndResidualsMatchReference() throws {
		let fixture = try EntropyReferenceFixture.load("modular_dc_gradient_rows")
		func integers(_ field: String) throws -> [Int64] {
			guard case .integers(let values)? = fixture.input.fields[field] else {
				throw SemanticDumpError.unimplemented
			}
			return values
		}
		func expectedIntegers(_ field: String) throws -> [Int64] {
			guard case .integers(let values)? = fixture.expected.fields[field] else {
				throw SemanticDumpError.unimplemented
			}
			return values
		}
		let contextOffset = try integers("input.modular.context_offset")[0]
		let referenceTree = try EntropyReferenceFixture.load(
			"tree_gradient_fixed_8193_dc2")
		guard
			case .integers(let encodedNodes)? = referenceTree.expected.fields[
				"entropy.tree.nodes"]
		else { throw SemanticDumpError.unimplemented }
		for (index, context) in DCPredictor.gradientContextLut.enumerated() {
			let property = index - DCPredictor.gradRangeMid
			var nodeIndex = 0
			while encodedNodes[nodeIndex * 7] >= 0 {
				let base = nodeIndex * 7
				nodeIndex =
					property > Int(encodedNodes[base + 1])
					? Int(encodedNodes[base + 2])
					: Int(encodedNodes[base + 3])
			}
			#expect(
				encodedNodes[nodeIndex * 7 + 2] + contextOffset == Int64(context),
				"gradient property \(property) has a different leaf context")
		}

		for group in 0..<2 {
			let prefix = "input.modular.group\(group)"
			let width = Int(try integers("\(prefix).width")[0])
			let height = Int(try integers("\(prefix).height")[0])
			let channelOrder = try integers("\(prefix).channel_order").map(Int.init)
			var data = DCGroupData(widthInBlocks: width, heightInBlocks: height)
			for channel in 0..<3 {
				let samples = try integers("\(prefix).channel\(channel)")
				data.quantDC[channel] = samples.map(Int16.init)
			}
			let actual = SwiftEntropySemanticEncoding.modularTokens(data: data)
			let referenceTokens = try expectedIntegers(
				"entropy.modular.group\(group).tokens")
			let projectedTokens = stride(from: 0, to: referenceTokens.count, by: 2)
				.flatMap { index in
					[
						referenceTokens[index] + contextOffset,
						referenceTokens[index + 1],
					]
				}
			var expected = SemanticDump()
			expected.record(
				"entropy.modular.token_count",
				.integers([Int64(projectedTokens.count / 2)]))
			expected.record("entropy.modular.tokens", .integers(projectedTokens))
			#expect(channelOrder == [1, 0, 2])
			#expect(actual.differences(from: expected).isEmpty)
		}
	}

	@Test
	func acTokenContextsAndValuesMatchReference() throws {
		for name in ["ac_tokens_tiny_map", "ac_tokens_default_map"] {
			let fixture = try EntropyReferenceFixture.load(name)
			func integers(_ field: String) throws -> [Int64] {
				guard case .integers(let values)? = fixture.input.fields[field]
				else {
					throw SemanticDumpError.unimplemented
				}
				return values
			}
			let width = Int(try integers("input.ac_tokens.width")[0])
			let height = Int(try integers("input.ac_tokens.height")[0])
			let order = try integers("input.ac_tokens.order").map(Int.init)
			let qdc = try integers("input.ac_tokens.qdc").map(Int16.init)
			let qf = try integers("input.ac_tokens.qf").map(UInt8.init)
			let coefficients = try (0..<3).map { channel in
				try integers("input.ac_tokens.channel\(channel)").map(Int32.init)
			}
			let group = Encoder.ACGroupCompute(
				groupX: 0, groupY: 0, widthInBlocks: width,
				heightInBlocks: height, coefficients: coefficients,
				quantDC: Array(repeating: qdc, count: 3), quantField: qf)
			let actual = SwiftEntropySemanticEncoding.acTokens(
				group: group, order: Array(repeating: order, count: 3))
			let differences = actual.differences(from: fixture.expected)
			if name == "ac_tokens_tiny_map" {
				#expect(differences.isEmpty, "\(name): \(differences)")
			} else {
				let knownDifferences: Set<String> = [
					"entropy.ac_tokens.context_count",
					"entropy.ac_tokens.contexts",
				]
				#expect(Set(differences.map(\.field)) == knownDifferences)
				withKnownIssue(
					Comment(
						rawValue:
							"GER-3387: Swift's compact AC map differs from upstream's default categories"
					)
				) {
					#expect(
						differences.isEmpty,
						"\(name): \(differences)")
				}
				#expect(
					actual.differences(
						from: fixture.expected,
						excludingFields: knownDifferences
					).isEmpty)
				let contextMap = try integers("input.ac_tokens.context_map")
				#expect(
					contextMap[0] == 0 && contextMap[13] == 7
						&& contextMap[26] == 7)
			}
		}
	}

	@Test
	func sampledCoefficientStatisticsMatchReference() throws {
		let fixture = try EntropyReferenceFixture.load(
			"coefficient_sampled_group_boundary")
		#expect(
			fixture.expected.fields["entropy.coefficient_sampling.blocks"]
				== .integers([33, 32]))
		#expect(
			fixture.expected.fields["entropy.coefficient_sampling.group_count"]
				== .integers([2]))
		#expect(
			fixture.expected.fields["entropy.coefficient_sampling.selected_blocks"]
				== .integers([544]))
		#expect(
			fixture.expected.fields["entropy.coefficient_sampling.rejected_blocks"]
				== .integers([512]))
		#expect(
			fixture.expected.fields["entropy.coefficient_sampling.selected_counts"]
				== .integers([544, 543]))
		let selectedCounts = try integers(
			fixture.expected, "entropy.coefficient_sampling.selected_counts")
		var counts = [Int64](repeating: 0, count: DCT.blockSize)
		counts[1] = selectedCounts[0]
		counts[8] = selectedCounts[1]
		let swiftOrder = SwiftEntropySemanticEncoding.coefficientOrder(
			counts: counts)
		#expect(
			swiftOrder.fields["entropy.coefficient_order.order"]
				== fixture.expected.fields["entropy.coefficient_sampling.order"])
	}

	@Test
	func coefficientSortKeysMatchReferenceBelowRoundingBoundary() throws {
		let fixture = try EntropyReferenceFixture.load("coefficient_sort_bounded")
		let counts = try integers(fixture.input, "input.coefficient_order.counts")
		let actual = SwiftEntropySemanticEncoding.coefficientOrder(counts: counts)
		#expect(
			actual.fields["entropy.coefficient_order.order"]
				== fixture.expected.fields[
					"entropy.coefficient_order.reference_order"])
		#expect(
			actual.fields["entropy.coefficient_order.counts"]
				== fixture.expected.fields["entropy.coefficient_order.counts"])
	}

	@Test
	func coefficientSortKeysExposeRoundingBoundaryDivergence() throws {
		let fixture = try EntropyReferenceFixture.load("coefficient_sort_boundary")
		let counts = try integers(fixture.input, "input.coefficient_order.counts")
		let actual = SwiftEntropySemanticEncoding.coefficientOrder(counts: counts)
		let swiftOrder = try integers(actual, "entropy.coefficient_order.order")
		let sourceOrder = try integers(
			fixture.expected,
			"entropy.coefficient_order.reference_order")
		#expect(sourceOrder.suffix(2) == [1, 8])
		#expect(swiftOrder.suffix(2) == [8, 1])
		#expect(swiftOrder.dropLast(2) == sourceOrder.dropLast(2))
		#expect(
			fixture.expected.fields["entropy.coefficient_order.sampled_counts"]
				== .integers([4_194_312, 4_194_311]))
		#expect(
			fixture.expected.fields["entropy.coefficient_order.sampled_order"]
				== fixture.expected.fields[
					"entropy.coefficient_order.reference_order"])
	}

	@Test
	func naturalDCT8OrderMatchesReference() throws {
		let fixture = try EntropyReferenceFixture.load("coefficient_natural_dct8")
		#expect(
			fixture.expected.fields["entropy.coefficient_natural.order"]
				== .integers(CoeffOrder.natural.map(Int64.init)))
	}

	@Test
	func coefficientFixtureShapeRejectsInconsistentObservations() throws {
		let sampled = try EntropyReferenceFixture.load(
			"coefficient_sampled_group_boundary")
		let wrongSelected = try SemanticDump(
			parsing: sampled.expected.serialized.replacingOccurrences(
				of: "entropy.coefficient_sampling.selected_blocks i 1 544",
				with: "entropy.coefficient_sampling.selected_blocks i 1 545"))
		#expect(throws: Error.self) {
			try EntropyReferenceFixture.validate(
				name: "coefficient_sampled_group_boundary", input: sampled.input,
				expected: wrongSelected)
		}
		let wrongSpeed = try SemanticDump(
			parsing: sampled.input.serialized.replacingOccurrences(
				of: "input.coefficient_sampling.speed_tier i 1 6",
				with: "input.coefficient_sampling.speed_tier i 1 5"))
		#expect(throws: Error.self) {
			try EntropyReferenceFixture.validate(
				name: "coefficient_sampled_group_boundary", input: wrongSpeed,
				expected: sampled.expected)
		}
		let wrongPattern = try SemanticDump(
			parsing: sampled.input.serialized.replacingOccurrences(
				of: "input.coefficient_sampling.zero_positions i 2 1 8",
				with: "input.coefficient_sampling.zero_positions i 2 1 9"))
		#expect(throws: Error.self) {
			try EntropyReferenceFixture.validate(
				name: "coefficient_sampled_group_boundary", input: wrongPattern,
				expected: sampled.expected)
		}
		let overflowingDimensions = try SemanticDump(
			parsing: sampled.input.serialized.replacingOccurrences(
				of: "input.coefficient_sampling.blocks i 2 33 32",
				with: "input.coefficient_sampling.blocks i 2 \(Int64.max) 32"))
		#expect(throws: Error.self) {
			try EntropyReferenceFixture.validate(
				name: "coefficient_sampled_group_boundary",
				input: overflowingDimensions, expected: sampled.expected)
		}

		let boundary = try EntropyReferenceFixture.load("coefficient_sort_boundary")
		let wrongCount = try SemanticDump(
			parsing: boundary.input.serialized.replacingOccurrences(
				of: "input.coefficient_order.counts i 64 0 4194312",
				with: "input.coefficient_order.counts i 64 0 4194311"))
		#expect(throws: Error.self) {
			try EntropyReferenceFixture.validate(
				name: "coefficient_sort_boundary", input: wrongCount,
				expected: boundary.expected)
		}
	}

	@Test
	func smallFrameSharesOneACCodeAcrossIndependentGroupStreams() throws {
		let fixture = try EntropyReferenceFixture.load("stream_shared_ans")
		guard
			case .integers(let contextMap)? = fixture.input.fields[
				"input.streams.context_map"],
			case .integers(let logAlpha)? = fixture.input.fields[
				"input.streams.log_alpha_size"],
			case .integers(let frequencies)? = fixture.input.fields[
				"input.streams.frequencies"],
			case .integers(let lengths)? = fixture.input.fields[
				"input.streams.lengths"],
			case .integers(let tokenValues)? = fixture.input.fields[
				"input.streams.tokens"]
		else { throw SemanticDumpError.unimplemented }
		var offset = 0
		let streams = lengths.map { length in
			let stream = (0..<Int(length)).map { _ -> Token in
				defer { offset += 2 }
				return Token(
					context: UInt32(tokenValues[offset]),
					value: UInt32(tokenValues[offset + 1]))
			}
			return stream
		}
		let info = ANSInfoTable.build(
			distribution: frequencies.map(Int.init), alphabetSize: frequencies.count,
			logAlphaSize: Int(logAlpha[0]))
		let code = EntropyCode(
			contextMap: contextMap.map(UInt8.init), prefixCodes: [],
			ansInfoTables: [info])
		let actual = SwiftEntropySemanticEncoding.tokenStreams(
			tokens: streams, code: code)
		try exportCurrentStreamDump(actual, name: "stream_shared_ans")
		#expect(actual.differences(from: fixture.expected).isEmpty)
		guard
			let receiptURL = Bundle.module.url(
				forResource: "stream_shared_ans.receipt", withExtension: "sem",
				subdirectory: "Fixtures/entropy")
		else { throw SemanticDumpError.fixtureNotFound("stream_shared_ans.receipt") }
		let receipt = try SemanticDump(
			parsing: String(contentsOf: receiptURL, encoding: .utf8))
		#expect(
			try integers(receipt, "entropy.stream_receipt.code_bit_count")
				== integers(fixture.expected, "entropy.streams.code_bit_count"))
		#expect(try integers(receipt, "entropy.stream_receipt.code_is_ans") == [1])
		#expect(
			try integers(receipt, "entropy.stream_receipt.code_bytes")
				== integers(fixture.expected, "entropy.streams.code_bytes"))
		#expect(
			try integers(receipt, "entropy.stream_receipt.stream_bit_counts")
				== integers(fixture.expected, "entropy.streams.bit_counts"))
		#expect(
			try integers(receipt, "entropy.stream_receipt.stream_bytes")
				== integers(fixture.expected, "entropy.streams.bytes"))
		#expect(
			try integers(receipt, "entropy.stream_receipt.order_passes") == [
				0, 1, 1, 0,
			])
		#expect(
			try integers(receipt, "entropy.stream_receipt.readers") == [
				32, 1, 32, 1, 32, 1, 32, 1,
			])
		#expect(try integers(receipt, "entropy.stream_receipt.code_bytes_consumed") == [34])
		#expect(try integers(receipt, "entropy.stream_receipt.decoded_token_count") == [16])
	}

	@Test
	func smallFrameSharesOnePrefixCodeAcrossIndependentGroupStreams() throws {
		let fixture = try EntropyReferenceFixture.load("stream_shared_prefix")
		guard
			case .integers(let contextMap)? = fixture.input.fields[
				"input.streams.context_map"],
			case .integers(let lengths)? = fixture.input.fields[
				"input.streams.lengths"],
			case .integers(let tokenValues)? = fixture.input.fields[
				"input.streams.tokens"]
		else { throw SemanticDumpError.unimplemented }
		var offset = 0
		let streams = lengths.map { length in
			(0..<Int(length)).map { _ -> Token in
				defer { offset += 2 }
				return Token(
					context: UInt32(tokenValues[offset]),
					value: UInt32(tokenValues[offset + 1]))
			}
		}
		var histogram = Histogram()
		for token in streams.flatMap({ $0 }) {
			histogram.add(UintCoder.encode(token.value).token)
		}
		let prefix = HistogramCluster.buildPrefixCodes([histogram])
		let code = EntropyCode(contextMap: contextMap.map(UInt8.init), prefixCodes: prefix)
		let actual = SwiftEntropySemanticEncoding.tokenStreams(tokens: streams, code: code)
		try exportCurrentStreamDump(actual, name: "stream_shared_prefix")
		#expect(actual.differences(from: fixture.expected).isEmpty)
		guard
			let receiptURL = Bundle.module.url(
				forResource: "stream_shared_prefix.receipt", withExtension: "sem",
				subdirectory: "Fixtures/entropy")
		else { throw SemanticDumpError.fixtureNotFound("stream_shared_prefix.receipt") }
		let receipt = try SemanticDump(
			parsing: String(contentsOf: receiptURL, encoding: .utf8))
		#expect(try integers(receipt, "entropy.stream_receipt.code_is_ans") == [0])
		#expect(
			try integers(receipt, "entropy.stream_receipt.code_bytes")
				== integers(fixture.expected, "entropy.streams.code_bytes"))
		#expect(
			try integers(receipt, "entropy.stream_receipt.stream_bytes")
				== integers(fixture.expected, "entropy.streams.bytes"))
		#expect(
			try integers(receipt, "entropy.stream_receipt.code_bit_count")
				== integers(fixture.expected, "entropy.streams.code_bit_count"))
		#expect(
			try integers(receipt, "entropy.stream_receipt.stream_bit_counts")
				== integers(fixture.expected, "entropy.streams.bit_counts"))
		#expect(
			try integers(receipt, "entropy.stream_receipt.order_passes") == [
				0, 1, 1, 0,
			])
		#expect(
			try integers(receipt, "entropy.stream_receipt.readers") == [
				8, 1, 8, 1, 8, 1, 8, 1,
			])
		#expect(try integers(receipt, "entropy.stream_receipt.code_bytes_consumed") == [25])
		#expect(try integers(receipt, "entropy.stream_receipt.decoded_token_count") == [16])
	}

	@Test(.enabled(if: ProcessInfo.processInfo.environment["JXL_CROSSCHECK_DIR"] != nil))
	func streamingLayoutMatchesReferenceAboveEightGroups() throws {
		let directory = try #require(
			ProcessInfo.processInfo.environment["JXL_CROSSCHECK_DIR"])
		let layout = try SemanticDump(
			parsing: String(
				contentsOf: URL(
					fileURLWithPath: directory
				).appendingPathComponent(
					"reference_2057x257.layout.sem"), encoding: .utf8))
		#expect(try integers(layout, "entropy_layout.group_grid") == [9, 2])
		#expect(try integers(layout, "entropy_layout.group_count") == [18])
		#expect(try integers(layout, "entropy_layout.dc_group_count") == [2])
		#expect(try integers(layout, "entropy_layout.histogram_set_count") == [2])
		#expect(try integers(layout, "entropy_layout.selector_bits") == [1])
		let selectors = try integers(layout, "entropy_layout.ac_selectors")
		#expect(
			stride(from: 1, to: selectors.count, by: 4).map { selectors[$0] }
				== Array(0..<18).map(Int64.init))
		#expect(
			stride(from: 3, to: selectors.count, by: 4).map { selectors[$0] } == Array(
				repeating: 0, count: 8) + [1] + Array(repeating: 0, count: 8) + [1])
	}

	@Test
	func entropyMutationIsReportedByItsExactField() throws {
		let fixture = try EntropyReferenceFixture.load("stream_shared_ans")
		let baseline = fixture.expected.serialized
		let mutated = try SemanticDump(
			parsing: baseline.replacingOccurrences(
				of: "entropy.streams.bytes i 8 64 81 1 19 192 152 0 19",
				with: "entropy.streams.bytes i 8 64 81 1 19 192 152 0 18"))
		let differences = mutated.differences(from: fixture.expected)
		#expect(differences.map(\.field) == ["entropy.streams.bytes"])
	}
}
