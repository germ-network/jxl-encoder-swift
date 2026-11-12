import Testing

@testable import JXLEncoder

@Suite("Entropy reference contracts")
struct EntropyReferenceTests {
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

	@Test(.disabled("Awaiting entropy reference implementation"))
	func predefinedMATreeMatchesReference() throws {
		Issue.record("Predefined tree nodes and tokens match the reference configuration.")
	}

	@Test(.disabled("Awaiting entropy reference implementation"))
	func modularLeafContextsAndResidualsMatchReference() throws {
		Issue.record(
			"Modular leaf contexts and packed residuals match for identical samples.")
	}

	@Test(.disabled("Awaiting entropy reference implementation"))
	func acTokenContextsAndValuesMatchReference() throws {
		Issue.record(
			"Prescribed AC coefficients produce the reference token contexts and values."
		)
	}

	@Test(.disabled("Awaiting entropy reference implementation"))
	func sampledCoefficientStatisticsMatchReference() throws {
		Issue.record(
			"Observed coefficient statistics preserve group-boundary sampling behavior."
		)
	}

	@Test(.disabled("Awaiting entropy reference implementation"))
	func coefficientSortKeysMatchReferenceBelowRoundingBoundary() throws {
		Issue.record("Counts below 2^22 preserve reference ordering at bucket transitions.")
	}

	@Test(.disabled("Awaiting entropy reference implementation"))
	func coefficientSortKeysExposeRoundingBoundaryDivergence() throws {
		Issue.record(
			"The observed coefficient boundary retains its isolated GER-3386 divergence."
		)
	}

	@Test(.disabled("Awaiting entropy reference implementation"))
	func naturalDCT8OrderMatchesReference() throws {
		Issue.record("The natural DCT8 order equals the pinned upstream order.")
	}

	@Test(.disabled("Awaiting entropy reference implementation"))
	func smallFrameSharesOneACCodeAcrossIndependentGroupStreams() throws {
		Issue.record(
			"Small multigroup frames share one code across independently decodable streams."
		)
	}

	@Test(.disabled("Awaiting entropy reference implementation"))
	func streamingLayoutMatchesReferenceAboveEightGroups() throws {
		Issue.record(
			"Eligible large reference frames expose their streaming histogram partition."
		)
	}

	@Test(.disabled("Awaiting entropy reference implementation"))
	func entropyMutationIsReportedByItsExactField() throws {
		Issue.record("An entropy mutation is reported only by its changed semantic field.")
	}
}
