import Testing

@testable import JXLEncoder

@Suite("Entropy reference contracts")
struct EntropyReferenceTests {
	@Test
	func normalizedTablesAndPrecisionMatchReference() throws {
		for (name, diverges) in [
			("ans_singleton_precise", false),
			("ans_two_symbol_approximate", true),
			("ans_precision_fast", true),
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
			if diverges {
				withKnownIssue(
					Comment(
						rawValue:
							"GER-3386: full-precision ANS normalization"
					)
				) {
					#expect(differences.isEmpty, "\(name): \(differences)")
				}
			} else {
				#expect(differences.isEmpty, "\(name): \(differences)")
			}
		}
	}

	@Test
	func fastAndBestClustersMatchReference() throws {
		for (name, diverges) in [
			("clusters_fast_identical", false),
			("clusters_fast_merge", true),
			("clusters_best_merge", false),
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
			if diverges {
				withKnownIssue(
					Comment(rawValue: "GER-3386: best histogram clustering")
				) {
					#expect(differences.isEmpty, "\(name): \(differences)")
				}
			} else {
				#expect(differences.isEmpty, "\(name): \(differences)")
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
