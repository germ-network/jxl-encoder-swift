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
				"ans_threshold48_fast",
				Set([
					"entropy.histogram.serialized_method",
					"entropy.histogram.serialized_shift",
					"entropy.histogram.bit_count", "entropy.histogram.bytes",
				])
			),
			(
				"ans_threshold64_fast",
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
	}

	@Test
	func fastAndBestClustersMatchReference() throws {
		for (name, knownDifferences) in [
			("clusters_fast_identical", Set<String>()),
			("clusters_best_identical", Set<String>()),
			("clusters_ties_fast", Set<String>()),
			(
				"clusters_farthest_fast",
				Set([
					"entropy.clusters.map", "entropy.clusters.count",
					"entropy.clusters.alphabet_lengths",
					"entropy.clusters.total_counts",
					"entropy.clusters.histogram_counts",
				])
			),
			("clusters_over_eight_fast", Set<String>()),
			(
				"clusters_fast_merge",
				Set([
					"entropy.clusters.map", "entropy.clusters.count",
					"entropy.clusters.alphabet_lengths",
					"entropy.clusters.total_counts",
					"entropy.clusters.histogram_counts",
				])
			),
			("clusters_best_merge", Set<String>()),
		] {
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
			let actual = SwiftEntropySemanticEncoding.clusters(
				histograms: histograms, limit: Int(limit[0]))
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

	@Test(.disabled("Awaiting entropy reference implementation"))
	func contextMapChoiceMatchesReference() throws {
		Issue.record(
			"Context map coding choices match the reference for identical map inputs.")
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
