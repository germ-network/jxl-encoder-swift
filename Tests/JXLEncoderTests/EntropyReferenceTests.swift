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
		let acMetadata = try EntropyReferenceFixture.load("acmeta_channels_16x16")
		let invalidQuantField = try SemanticDump(
			parsing: acMetadata.input.serialized.replacingOccurrences(
				of: "input.ac_metadata.raw_quant_field i 256 1 ",
				with: "input.ac_metadata.raw_quant_field i 256 256 "))
		#expect(throws: Error.self) {
			try EntropyReferenceFixture.validate(
				name: "acmeta_channels_16x16", input: invalidQuantField,
				expected: acMetadata.expected)
		}
	}

	@Test
	func malformedPrimitiveFixturesAreRejectedBeforeIntegerConversion() throws {
		let uint = try EntropyReferenceFixture.load("hybrid_uint_4_2_0")
		for (old, replacement) in [
			("input.uint.values i 17 0", "input.uint.values i 17 -1"),
			("input.uint.config i 3 4 2 0", "input.uint.config i 3 32 2 0"),
		] {
			let malformed = try SemanticDump(
				parsing: uint.input.serialized.replacingOccurrences(
					of: old, with: replacement))
			#expect(throws: Error.self) {
				try EntropyReferenceFixture.validate(
					name: "hybrid_uint_4_2_0", input: malformed,
					expected: uint.expected)
			}
		}
		let wideUint = try SemanticDump(
			parsing: uint.input.serialized.replacingOccurrences(
				of: "input.uint.values i 17 0",
				with: "input.uint.values i 17 4294967296"))
		#expect(throws: Error.self) {
			try EntropyReferenceFixture.validate(
				name: "hybrid_uint_4_2_0", input: wideUint,
				expected: uint.expected)
		}

		let signed = try EntropyReferenceFixture.load("pack_signed_full_reference")
		let wideSigned = try SemanticDump(
			parsing: signed.input.serialized.replacingOccurrences(
				of: "input.signed.values i 11 0",
				with: "input.signed.values i 11 2147483648"))
		#expect(throws: Error.self) {
			try EntropyReferenceFixture.validate(
				name: "pack_signed_full_reference", input: wideSigned,
				expected: signed.expected)
		}

		let huffman = try EntropyReferenceFixture.load("huffman_tree_full_reference")
		for (old, replacement) in [
			(
				"input.huffman.lengths i 6 4 5 8 1 3 15",
				"input.huffman.lengths i 5 4 5 8 1 3"
			),
			(
				"input.huffman.counts i 36 1 1 1 1",
				"input.huffman.counts i 36 0 0 0 0"
			),
		] {
			let malformed = try SemanticDump(
				parsing: huffman.input.serialized.replacingOccurrences(
					of: old, with: replacement))
			#expect(throws: Error.self) {
				try EntropyReferenceFixture.validate(
					name: "huffman_tree_full_reference", input: malformed,
					expected: huffman.expected)
			}
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
	func treeTokenEntropyMatchesPinnedReference() throws {
		let fixture = try EntropyReferenceFixture.load("tree_entropy_cheetah")
		let actual = SwiftEntropySemanticEncoding.treeEntropy(dcGroupCount: 2)
		let swiftTree = SwiftEntropySemanticEncoding.tree(dcGroupCount: 2)
		var productionWriter = BitWriter()
		ContextTree.write(dcGroupCount: 2, writer: &productionWriter)
		guard
			case .integers(let swiftTokens)? = swiftTree.fields[
				"entropy.tree.full_tokens"],
			case .integers(let inputTokens)? = fixture.input.fields[
				"input.tree_entropy.tokens"],
			case .integers(let encodedTokens)? = fixture.expected.fields[
				"entropy.tree_entropy.tokens"]
		else { throw SemanticDumpError.unimplemented }
		#expect(swiftTokens == inputTokens)
		#expect(inputTokens == encodedTokens)
		let tokens = ContextTree.staticTokens.enumerated().map { index, token in
			index == 1
				? Token(context: token.context, value: packSigned(3)) : token
		}
		let histogramCounts = tokens.reduce(
			into: Array(repeating: 0, count: 6 * StaticEntropyCodes.alphabetSize)
		) { counts, token in
			let (symbol, _, _) = UintCoder.encode(token.value)
			counts[
				Int(token.context) * StaticEntropyCodes.alphabetSize + Int(symbol)] +=
				1
		}
		#expect(
			actual.fields["entropy.tree_entropy.histogram_counts"]
				== .integers(histogramCounts.map(Int64.init)))
		#expect(
			actual.fields["entropy.tree_entropy.context_map"]
				== .integers([0, 1, 0, 1, 1, 1]))
		#expect(actual.fields["entropy.tree_entropy.prefix_code_count"] == .integers([2]))
		#expect(actual.fields["entropy.tree_entropy.use_prefix_code"] == .integers([1]))
		#expect(actual.fields["entropy.tree_entropy.code_bit_count"] == .integers([202]))
		#expect(actual.fields["entropy.tree_entropy.stream_bit_count"] == .integers([908]))
		#expect(actual.fields["entropy.tree_entropy.full_bit_count"] == .integers([910]))
		#expect(
			actual.fields["entropy.tree_entropy.full_bit_count"]
				== .integers([Int64(productionWriter.bitsWritten)]))
		#expect(
			actual.fields["entropy.tree_entropy.full_bytes"]
				== .integers(productionWriter.bytes.map(Int64.init)))
		guard
			case .integers(let prefixDepths)? = actual.fields[
				"entropy.tree_entropy.prefix_depths"],
			case .integers(let prefixBits)? = actual.fields[
				"entropy.tree_entropy.prefix_bits"]
		else { throw SemanticDumpError.unimplemented }
		#expect(prefixDepths.count == 128, "invalid Swift prefix table size")
		#expect(prefixBits.count == 128, "invalid Swift canonical-code table size")
		var comparableSwift = SemanticDump()
		for field in ["context_map", "use_prefix_code", "bit_count", "bytes"] {
			guard let value = actual.fields["entropy.tree_entropy.\(field)"] else {
				throw SemanticDumpError.unimplemented
			}
			comparableSwift.record("entropy.tree_entropy.\(field)", value)
		}
		var comparableReference = SemanticDump()
		for field in ["context_map", "use_prefix_code", "bit_count", "bytes"] {
			guard let value = fixture.expected.fields["entropy.tree_entropy.\(field)"]
			else {
				throw SemanticDumpError.unimplemented
			}
			comparableReference.record("entropy.tree_entropy.\(field)", value)
		}
		let differences = comparableSwift.differences(from: comparableReference)
		let knownDifferences: Set<String> = [
			"entropy.tree_entropy.context_map",
			"entropy.tree_entropy.use_prefix_code",
			"entropy.tree_entropy.bit_count",
			"entropy.tree_entropy.bytes",
		]
		#expect(Set(differences.map(\.field)) == knownDifferences, "\(differences)")
		#expect(
			fixture.expected.fields["entropy.tree_entropy.ans_strategy"]
				== .integers([1]))
		#expect(
			fixture.expected.fields["entropy.tree_entropy.table_lengths"]
				== .integers([40, 11, 6]))
		#expect(
			fixture.expected.fields["entropy.tree_entropy.clustering"] == .integers([1])
		)
		#expect(
			fixture.expected.fields["entropy.tree_entropy.ans_strategy"]
				== .integers([1]))
		#expect(
			fixture.expected.fields["entropy.tree_entropy.lz77_method"]
				== .integers([0]))
		#expect(
			fixture.expected.fields["entropy.tree_entropy.uint_method"]
				== .integers([0]))
		let changedCoding = SwiftEntropySemanticEncoding.treeEntropy(
			dcGroupCount: 2, tokens: tokens,
			contextMapOverride: Array(repeating: 0, count: 6))
		#expect(
			changedCoding.fields["entropy.tree_entropy.tokens"]
				== actual.fields[
					"entropy.tree_entropy.tokens"])
		#expect(
			changedCoding.fields["entropy.tree_entropy.histogram_counts"]
				== actual.fields["entropy.tree_entropy.histogram_counts"])
		let changedFields = Set(changedCoding.differences(from: actual).map(\.field))
		#expect(changedFields.contains("entropy.tree_entropy.context_map"))
		#expect(changedFields.contains("entropy.tree_entropy.bytes"))
		#expect(changedFields.contains("entropy.tree_entropy.bit_count"))
	}

	@Test
	func projectedTreeNodeMutationStaysVisible() throws {
		let tree = SwiftEntropySemanticEncoding.tree(dcGroupCount: 1)
		guard case .integers(var tokens)? = tree.fields["entropy.tree.full_tokens"] else {
			throw SemanticDumpError.unimplemented
		}
		let original = SwiftEntropySemanticEncoding.projectedTree(
			fullTokens: tokens, root: 1)
		tokens[7] = 4
		let mutated = SwiftEntropySemanticEncoding.projectedTree(
			fullTokens: tokens, root: 1)
		let differences = mutated.differences(from: original)
		#expect(
			Set(differences.map(\.field)) == [
				"entropy.tree.nodes", "entropy.tree.tokens",
			])
	}

	@Test
	func predefinedMATreeMatchesReference() throws {
		func leafConfigurations(_ dump: SemanticDump) -> Set<[Int64]> {
			guard case .integers(let nodes)? = dump.fields["entropy.tree.nodes"] else {
				return []
			}
			return Set(
				stride(from: 0, to: nodes.count, by: 7).compactMap { base in
					guard nodes[base] == -1 else { return nil }
					return Array(nodes[(base + 4)..<(base + 7)])
				})
		}
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

		for (name, groupCount) in [
			("tree_wp_fixed_8192_dc1", 1),
			("tree_wp_fixed_8193_dc2", 2),
		] {
			let fixture = try EntropyReferenceFixture.load(name)
			guard
				case .integers(let kind)? = fixture.input.fields["input.tree.kind"],
				case .integers(let pixels)? = fixture.input.fields[
					"input.tree.total_pixels"],
				case .integers(let projectionRoot)? = fixture.input.fields[
					"input.tree.projection_root"],
				case .integers(let expectedNodes)? = fixture.expected.fields[
					"entropy.tree.nodes"],
				case .integers(let expectedTokens)? = fixture.expected.fields[
					"entropy.tree.tokens"],
				case .integers(let swiftFullTokens)? =
					SwiftEntropySemanticEncoding.tree(
						dcGroupCount: groupCount
					).fields["entropy.tree.full_tokens"]
			else { throw SemanticDumpError.unimplemented }
			#expect(kind == [5])
			#expect(pixels == (groupCount == 1 ? [8192] : [8193]))
			var referenceProjection = SemanticDump()
			for field in ["node_count", "nodes", "token_count", "tokens"] {
				guard let value = fixture.expected.fields["entropy.tree.\(field)"]
				else {
					throw SemanticDumpError.unimplemented
				}
				referenceProjection.record("entropy.tree.\(field)", value)
			}
			let swiftProjection = SwiftEntropySemanticEncoding.projectedTree(
				fullTokens: swiftFullTokens, root: Int(projectionRoot[0]))
			let differences = swiftProjection.differences(from: referenceProjection)
			let expectedDifferences: Set<String> =
				groupCount == 1
				? [
					"entropy.tree.node_count", "entropy.tree.nodes",
					"entropy.tree.token_count", "entropy.tree.tokens",
				]
				: ["entropy.tree.nodes", "entropy.tree.tokens"]
			#expect(expectedNodes.count % 7 == 0, "\(name): malformed node tuples")
			#expect(expectedTokens.count % 2 == 0, "\(name): malformed tree tokens")
			#expect(
				Set(differences.map(\.field)) == expectedDifferences,
				"\(name): \(differences)")
			for field in expectedDifferences {
				let fieldDifferences = differences.filter { $0.field == field }
				withKnownIssue(Comment(rawValue: "GER-3386: \(field)")) {
					#expect(
						fieldDifferences.isEmpty,
						"\(name): \(fieldDifferences)")
				}
			}
		}

		for name in ["tree_acmeta_below_1024", "tree_acmeta_above_1024"] {
			let fixture = try EntropyReferenceFixture.load(name)
			guard
				case .integers(let totalPixels)? = fixture.input.fields[
					"input.tree.total_pixels"],
				case .integers(let channelAreas)? = fixture.input.fields[
					"input.tree.channel_areas"],
				case .integers(let projectionRoot)? = fixture.input.fields[
					"input.tree.projection_root"],
				case .integers(let expectedNodeCount)? = fixture.expected.fields[
					"entropy.tree.node_count"],
				case .integers(let swiftTokens)? =
					SwiftEntropySemanticEncoding.tree(
						dcGroupCount: 1
					).fields["entropy.tree.full_tokens"]
			else { throw SemanticDumpError.unimplemented }
			#expect(channelAreas.reduce(0, +) == totalPixels[0])
			#expect(expectedNodeCount == (totalPixels[0] < 1024 ? [1] : [27]))
			let actual = SwiftEntropySemanticEncoding.projectedTree(
				fullTokens: swiftTokens, root: Int(projectionRoot[0]))
			var expected = SemanticDump()
			for field in ["node_count", "nodes", "token_count", "tokens"] {
				guard let value = fixture.expected.fields["entropy.tree.\(field)"]
				else {
					throw SemanticDumpError.unimplemented
				}
				expected.record("entropy.tree.\(field)", value)
			}
			let differences = actual.differences(from: expected)
			#expect(
				!leafConfigurations(actual).isDisjoint(
					with: leafConfigurations(expected)))
			let knownDifferences: Set<String> = [
				"entropy.tree.node_count", "entropy.tree.nodes",
				"entropy.tree.token_count", "entropy.tree.tokens",
			]
			if name == "tree_acmeta_above_1024",
				case .integers(let actualNodes)? = actual.fields[
					"entropy.tree.nodes"],
				case .integers(let expectedNodes)? = expected.fields[
					"entropy.tree.nodes"]
			{
				#expect(actualNodes.prefix(21) == expectedNodes.prefix(21))
			}
			#expect(
				Set(differences.map(\.field)) == knownDifferences,
				"\(name): \(differences)")
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
	func acMetadataContextsAndResidualsMatchReference() throws {
		for name in ["acmeta_channels_16x16", "acmeta_channels_24x24"] {
			let fixture = try EntropyReferenceFixture.load(name)
			func integers(_ fields: [String: SemanticDump.Values], _ key: String) throws
				-> [Int64]
			{
				guard case .integers(let values)? = fields[key] else {
					throw SemanticDumpError.unimplemented
				}
				return values
			}
			let width = Int(
				try integers(fixture.input.fields, "input.ac_metadata.width")[0])
			let height = Int(
				try integers(fixture.input.fields, "input.ac_metadata.height")[0])
			var data = DCGroupData(widthInBlocks: width, heightInBlocks: height)
			data.ytoxMap = try integers(fixture.input.fields, "input.ac_metadata.ytox")
				.map(Int8.init)
			data.ytobMap = try integers(fixture.input.fields, "input.ac_metadata.ytob")
				.map(Int8.init)
			data.rawQuantField = try integers(
				fixture.input.fields, "input.ac_metadata.raw_quant_field"
			).map(UInt8.init)
			let actual = SwiftEntropySemanticEncoding.acMetadataTokens(data: data)
			guard
				case .integers(let actualTokens)? = actual.fields[
					"entropy.ac_metadata.tokens"]
			else { throw SemanticDumpError.unimplemented }
			let mapCount = data.cmapWidth * data.cmapHeight
			let blockCount = width * height
			let channels = [
				("cfl_ytox", mapCount), ("cfl_ytob", mapCount),
				("acs", blockCount), ("quant_field", blockCount),
				("epf", blockCount),
			]
			var offset = 0
			var observedDifferences = Set<String>()
			let belowThreshold = name == "acmeta_channels_16x16"
			for (channel, count) in channels {
				let key = "entropy.ac_metadata.\(channel).tokens"
				guard case .integers(let expected)? = fixture.expected.fields[key]
				else {
					throw SemanticDumpError.unimplemented
				}
				let range = offset..<(offset + count * 2)
				let actualChannel = Array(actualTokens[range])
				let actualContexts = stride(from: 0, to: actualChannel.count, by: 2)
					.map { actualChannel[$0] }
				let actualValues = stride(from: 1, to: actualChannel.count, by: 2)
					.map { actualChannel[$0] }
				let expectedContexts = stride(from: 0, to: expected.count, by: 2)
					.map { expected[$0] }
				let expectedValues = stride(from: 1, to: expected.count, by: 2)
					.map { expected[$0] }
				let contextsMatch = actualContexts.elementsEqual(expectedContexts)
				let valuesMatch = actualValues.elementsEqual(expectedValues)
				let contextDiffers = channel != "epf" || !belowThreshold
				let valuesDiffer =
					belowThreshold
					&& ["cfl_ytox", "cfl_ytob", "epf"].contains(channel)
				if contextDiffers {
					observedDifferences.insert("\(channel).contexts")
					withKnownIssue(
						Comment(
							rawValue:
								"GER-3386: entropy.ac_metadata.\(channel).contexts"
						)
					) {
						#expect(
							contextsMatch,
							"\(name) \(channel) context mismatch")
					}
				} else {
					#expect(
						contextsMatch, "\(name) \(channel) context mismatch"
					)
				}
				if valuesDiffer {
					observedDifferences.insert("\(channel).values")
					withKnownIssue(
						Comment(
							rawValue:
								"GER-3386: entropy.ac_metadata.\(channel).values"
						)
					) {
						#expect(
							valuesMatch,
							"\(name) \(channel) residual mismatch")
					}
				} else {
					#expect(valuesMatch, "\(name) \(channel) residual mismatch")
				}
				offset += count * 2
			}
			#expect(offset == actualTokens.count)
			let expectedDifferences: Set<String> =
				belowThreshold
				? [
					"cfl_ytox.contexts", "cfl_ytob.contexts", "acs.contexts",
					"quant_field.contexts", "cfl_ytox.values",
					"cfl_ytob.values",
					"epf.values",
				]
				: [
					"cfl_ytox.contexts", "cfl_ytob.contexts", "acs.contexts",
					"quant_field.contexts", "epf.contexts",
				]
			#expect(observedDifferences == expectedDifferences)
		}
	}

	@Test
	func modularAndMetadataTokenMutationsStayVisible() throws {
		func values(_ fixture: EntropyReferenceFixture, _ field: String) throws -> [Int64] {
			guard case .integers(let result)? = fixture.input.fields[field] else {
				throw SemanticDumpError.unimplemented
			}
			return result
		}
		func tokenParts(_ dump: SemanticDump) throws -> (contexts: [Int64], values: [Int64])
		{
			guard case .integers(let tokens)? = dump.fields["entropy.modular.tokens"]
			else {
				throw SemanticDumpError.unimplemented
			}
			return (
				stride(from: 0, to: tokens.count, by: 2).map { tokens[$0] },
				stride(from: 1, to: tokens.count, by: 2).map { tokens[$0] }
			)
		}
		let wp = try EntropyReferenceFixture.load("modular_dc_wp_fixed_8192")
		var wpData = DCGroupData(
			widthInBlocks: Int(try values(wp, "input.modular.group0.width")[0]),
			heightInBlocks: Int(try values(wp, "input.modular.group0.height")[0]))
		for channel in 0..<3 {
			wpData.quantDC[channel] = try values(
				wp, "input.modular.group0.channel\(channel)"
			).map(Int16.init)
		}
		let wpBaseline = SwiftEntropySemanticEncoding.modularTokens(data: wpData)
		let wpBaselineParts = try tokenParts(wpBaseline)
		var wpContextMutation = wpData
		wpContextMutation.quantDC[0][1] += 30
		let changedWPContext = SwiftEntropySemanticEncoding.modularTokens(
			data: wpContextMutation)
		let changedWPContextParts = try tokenParts(changedWPContext)
		#expect(changedWPContextParts.contexts != wpBaselineParts.contexts)
		var wpResidualMutation = wpData
		wpResidualMutation.quantDC[2][5] += 1
		let changedWPResidual = SwiftEntropySemanticEncoding.modularTokens(
			data: wpResidualMutation)
		let changedWPResidualParts = try tokenParts(changedWPResidual)
		#expect(changedWPResidualParts.contexts == wpBaselineParts.contexts)
		#expect(changedWPResidualParts.values != wpBaselineParts.values)

		let ac = try EntropyReferenceFixture.load("acmeta_channels_16x16")
		let width = Int(try values(ac, "input.ac_metadata.width")[0])
		let height = Int(try values(ac, "input.ac_metadata.height")[0])
		var acData = DCGroupData(widthInBlocks: width, heightInBlocks: height)
		acData.ytoxMap = try values(ac, "input.ac_metadata.ytox").map(Int8.init)
		acData.ytobMap = try values(ac, "input.ac_metadata.ytob").map(Int8.init)
		acData.rawQuantField = try values(ac, "input.ac_metadata.raw_quant_field").map(
			UInt8.init)
		let acBaseline = SwiftEntropySemanticEncoding.acMetadataTokens(data: acData)
		guard
			case .integers(let baselineTokens)? = acBaseline.fields[
				"entropy.ac_metadata.tokens"]
		else { throw SemanticDumpError.unimplemented }
		var cflMutation = acData
		cflMutation.ytoxMap[0] += 1
		let changedCFL = try integersFromAC(
			SwiftEntropySemanticEncoding.acMetadataTokens(data: cflMutation))
		let mapWidth = acData.cmapWidth * acData.cmapHeight * 2
		#expect(Array(changedCFL[..<mapWidth]) != Array(baselineTokens[..<mapWidth]))
		#expect(Array(changedCFL[mapWidth...]) == Array(baselineTokens[mapWidth...]))
		var qfMutation = acData
		qfMutation.rawQuantField[0] = 16
		let changedQF = try integersFromAC(
			SwiftEntropySemanticEncoding.acMetadataTokens(data: qfMutation))
		let qfStart = (2 * acData.cmapWidth * acData.cmapHeight + width * height) * 2
		let qfEnd = qfStart + width * height * 2
		let baselineQF = Array(baselineTokens[qfStart..<qfEnd])
		let changedQFChannel = Array(changedQF[qfStart..<qfEnd])
		let baselineQFContexts = stride(from: 0, to: baselineQF.count, by: 2).map {
			baselineQF[$0]
		}
		#expect(Array(baselineQFContexts.prefix(6)) == [6, 6, 6, 4, 4, 3])
		let changedQFContexts = stride(from: 0, to: changedQFChannel.count, by: 2).map {
			changedQFChannel[$0]
		}
		let baselineQFValues = stride(from: 1, to: baselineQF.count, by: 2).map {
			baselineQF[$0]
		}
		let changedQFValues = stride(from: 1, to: changedQFChannel.count, by: 2).map {
			changedQFChannel[$0]
		}
		#expect(changedQFContexts != baselineQFContexts)
		#expect(changedQFValues != baselineQFValues)
	}

	private func integersFromAC(_ dump: SemanticDump) throws -> [Int64] {
		guard case .integers(let values)? = dump.fields["entropy.ac_metadata.tokens"] else {
			throw SemanticDumpError.unimplemented
		}
		return values
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

		let wpFixture = try EntropyReferenceFixture.load("modular_dc_wp_fixed_8192")
		func wpIntegers(_ field: String) throws -> [Int64] {
			guard case .integers(let values)? = wpFixture.input.fields[field] else {
				throw SemanticDumpError.unimplemented
			}
			return values
		}
		let firstGroup = "input.modular.group0"
		let width = Int(try wpIntegers("\(firstGroup).width")[0])
		let height = Int(try wpIntegers("\(firstGroup).height")[0])
		var data = DCGroupData(widthInBlocks: width, heightInBlocks: height)
		for channel in 0..<3 {
			data.quantDC[channel] = try wpIntegers("\(firstGroup).channel\(channel)")
				.map(
					Int16.init)
		}
		let wpActual = SwiftEntropySemanticEncoding.modularTokens(data: data)
		guard
			case .integers(let wpOffset)? = wpFixture.input.fields[
				"input.modular.context_offset"],
			case .integers(let wpTokens)? = wpFixture.expected.fields[
				"entropy.modular.tokens"]
		else { throw SemanticDumpError.unimplemented }
		let wpProjected = stride(from: 0, to: wpTokens.count, by: 2).flatMap { index in
			[wpTokens[index] + wpOffset[0], wpTokens[index + 1]]
		}
		var wpExpected = SemanticDump()
		wpExpected.record(
			"entropy.modular.token_count", .integers([Int64(wpProjected.count / 2)]))
		wpExpected.record("entropy.modular.tokens", .integers(wpProjected))
		let wpDifferences = wpActual.differences(from: wpExpected)
		#expect(
			wpDifferences == [
				SemanticDifference(
					field: "entropy.modular.tokens",
					kind: .valueMismatch(index: 0, expected: "13", actual: "26")
				)
			])
		#expect(Set(wpDifferences.map(\.field)) == ["entropy.modular.tokens"])
		let tokenDifferences = wpDifferences.filter { $0.field == "entropy.modular.tokens" }
		withKnownIssue(Comment(rawValue: "GER-3386: entropy.modular.tokens")) {
			#expect(
				tokenDifferences.isEmpty,
				"same explicit DC samples under WP fixed-DC: \(tokenDifferences)")
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
