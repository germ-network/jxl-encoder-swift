import Testing

@testable import JXLEncoder

struct HistogramCostProofCase: Sendable {
	enum Operation: String, Sendable {
		case floatTotal
		case reciprocal
		case perSymbolLog2
		case termAccumulation
		case combinedMinusFirstMinusSecond
		case emptyInputZero
		case unresolved
	}

	let fixture: String
	let nativeFields: [String]
	let decisions: Set<String>
	let retainedOperations: [Operation]

	var reference: String {
		"Tests/JXLEncoderTests/Fixtures/entropy/\(fixture).expected.sem#clusters"
	}

	static let roundedCost = Self(
		fixture: "clusters_rounded_float_total_fast",
		nativeFields: ["entropy.clusters.input_shannon_entropy"],
		decisions: ["HC-01"],
		retainedOperations: [.floatTotal, .reciprocal, .perSymbolLog2, .termAccumulation])
	static let roundedDistance = Self(
		fixture: "clusters_rounded_float_total_fast",
		nativeFields: ["entropy.clusters.input_shannon_entropy"],
		decisions: ["HC-02"],
		retainedOperations: [.combinedMinusFirstMinusSecond, .emptyInputZero])
	static let all = [
		roundedCost, roundedDistance,
		Self(
			fixture: "clusters_distance_48_fast",
			nativeFields: ["entropy.clusters.input_shannon_entropy"],
			decisions: ["HC-02"],
			retainedOperations: [.combinedMinusFirstMinusSecond, .emptyInputZero]),
		Self(
			fixture: "clusters_distance_56_fast",
			nativeFields: ["entropy.clusters.input_shannon_entropy"],
			decisions: ["HC-02"],
			retainedOperations: [.combinedMinusFirstMinusSecond, .emptyInputZero]),
		Self(
			fixture: "clusters_distance_64_fast",
			nativeFields: ["entropy.clusters.input_shannon_entropy"],
			decisions: ["HC-02"],
			retainedOperations: [.combinedMinusFirstMinusSecond, .emptyInputZero]),
	]

	static func proves(_ reference: DecisionInventory.FixtureReference, decision: String)
		-> Bool
	{
		all.contains {
			$0.reference == "\(reference.path)#\(reference.category ?? "")"
				&& $0.decisions.contains(decision)
		}
	}

	static func hasActiveConsumer(_ reference: String) -> Bool {
		all.contains { $0.reference == reference }
	}
}

private struct FloatCostDiagnostic: Sendable {
	let fixture: String
	let nativeField: String
	let swiftValue: Float
	let nativeValue: Float
	let signedDelta: Float
	let signedULPDelta: Int64
	let firstDivergingOperation: HistogramCostProofCase.Operation?

	var description: String {
		"\(fixture) \(nativeField): Swift=\(swiftValue) native=\(nativeValue) "
			+ "delta=\(signedDelta) ulpDelta=\(signedULPDelta) "
			+ "firstDivergingOperation=\(firstDivergingOperation?.rawValue ?? "none")"
	}
}

@Suite("Upstream e4 histogram clustering")
struct HistogramClusteringTranslationTests {
	@Test
	func shannonCostUsesAnalyticTermsAndSwiftReduction() throws {
		let analyticCounts: [[UInt32]] = [[], [8], [4, 4], [2, 2, 2, 2]]
		let perTermCounts: [UInt32] = [3, 0, 5, 7, 9]
		let proof = HistogramCostProofCase.roundedCost
		let roundedTotal = try EntropyReferenceFixture.load(
			proof.fixture)
		var sourceHistograms = try histograms(from: roundedTotal)
		for index in sourceHistograms.indices {
			sourceHistograms[index].computeBitCost()
		}
		var roundedCombined = sourceHistograms[0]
		roundedCombined.add(sourceHistograms[1])
		roundedCombined.computeBitCost()
		#expect(roundedCombined.totalCount == 16_799_852)
		#expect(Float(roundedCombined.totalCount) == 16_799_852)
		#expect(Float(roundedCombined.counts[0]) == Float(roundedCombined.totalCount))
		#expect(sourceHistograms[0].bitCost.bitPattern == 0)
		let roundedTotalAsFloat = Float(roundedCombined.totalCount)
		let roundedInverseTotal = 1.0 / roundedTotalAsFloat
		let oneCountTerm = -FastMath.log2(roundedInverseTotal)
		#expect(roundedCombined.bitCost.bitPattern == oneCountTerm.bitPattern)
		var ascendingMaskedCost: Float = 0
		for count in roundedCombined.counts {
			let value = Float(count)
			if count == 0 || value == roundedTotalAsFloat { continue }
			ascendingMaskedCost += -(value * FastMath.log2(roundedInverseTotal * value))
		}
		#expect(roundedCombined.bitCost.bitPattern == ascendingMaskedCost.bitPattern)
		var analyticCosts: [Float] = []
		for counts in analyticCounts {
			var histogram = Histogram()
			for (symbol, count) in counts.enumerated() {
				histogram.counts[symbol] = count
				histogram.totalCount += Int(count)
			}
			histogram.computeBitCost()
			analyticCosts.append(histogram.bitCost)
		}
		var perTerm = Histogram()
		for (symbol, count) in perTermCounts.enumerated() {
			perTerm.counts[symbol] = count
			perTerm.totalCount += Int(count)
		}
		perTerm.computeBitCost()
		let inverseTotal = 1.0 / Float(perTerm.totalCount)
		var perBinTerms: [Float] = []
		for count in perTermCounts {
			let value = Float(count)
			if count == 0 || value == Float(perTerm.totalCount) {
				perBinTerms.append(0)
				continue
			}
			perBinTerms.append(-(value * FastMath.log2(inverseTotal * value)))
		}
		var leftToRight: Float = 0
		for term in perBinTerms { leftToRight += term }
		let reductionCounts: [UInt32] = [
			511_835, 609_709, 128_043, 579_356, 793_822, 787_856, 59_456, 194_498,
			128_268, 702_709, 329_019, 477_493, 50_554, 964_476, 996_148, 945_260,
			905_508, 395_548, 729_126, 527_050, 315_437, 574_725, 845_840, 828_396,
			394_900, 217_088, 851_621, 202_291, 346_378, 657_774, 160_264, 614_604,
		]
		var reductionHistogram = Histogram()
		for (symbol, count) in reductionCounts.enumerated() {
			reductionHistogram.counts[symbol] = count
			reductionHistogram.totalCount += Int(count)
		}
		reductionHistogram.computeBitCost()
		let reductionInverseTotal = 1.0 / Float(reductionHistogram.totalCount)
		var swiftReduction: Float = 0
		for count in reductionCounts {
			let value = Float(count)
			swiftReduction += -(value * FastMath.log2(reductionInverseTotal * value))
		}
		let nativeValues = try floats(
			roundedTotal.expected, "entropy.clusters.input_shannon_entropy")
		let diagnostics = zip(sourceHistograms.indices, nativeValues).map {
			index, nativeValue -> FloatCostDiagnostic in
			let swiftValue = sourceHistograms[index].bitCost
			return FloatCostDiagnostic(
				fixture: proof.fixture,
				nativeField: "entropy.clusters.input_shannon_entropy[\(index)]",
				swiftValue: swiftValue, nativeValue: nativeValue,
				signedDelta: swiftValue - nativeValue,
				signedULPDelta: Int64(swiftValue.bitPattern)
					- Int64(nativeValue.bitPattern),
				firstDivergingOperation: swiftValue.bitPattern
					== nativeValue.bitPattern
					? nil : .unresolved)
		}
		#expect(
			analyticCosts == [
				0, 0, -8 * FastMath.log2(0.5), -8 * FastMath.log2(0.25),
			])
		#expect(perTerm.bitCost.bitPattern == leftToRight.bitPattern)
		#expect(reductionHistogram.bitCost.bitPattern == swiftReduction.bitPattern)
		#expect(diagnostics.count == nativeValues.count)
		#expect(
			diagnostics.allSatisfy { diagnostic in
				diagnostic.fixture == proof.fixture
					&& proof.nativeFields.contains {
						diagnostic.nativeField.hasPrefix($0)
					}
			})
		for diagnostic in diagnostics where diagnostic.signedULPDelta != 0 {
			print(diagnostic.description)
		}
	}

	@Test
	func entropyCostDeltasAndDistanceKeepSourceCausality() throws {
		var empty = Histogram()
		empty.computeBitCost()
		var nonempty = Histogram()
		nonempty.add(1)
		nonempty.add(3)
		nonempty.computeBitCost()
		#expect(HistogramCluster.distance(empty, nonempty).bitPattern == 0)
		#expect(HistogramCluster.distance(nonempty, empty).bitPattern == 0)

		let distanceProofs = HistogramCostProofCase.all.filter {
			$0.decisions.contains("HC-02")
		}
		var diagnostics: [FloatCostDiagnostic] = []
		for proof in distanceProofs {
			let fixture = try EntropyReferenceFixture.load(proof.fixture)
			var sourceHistograms = try histograms(from: fixture)
			for index in sourceHistograms.indices {
				sourceHistograms[index].computeBitCost()
			}
			guard sourceHistograms.count >= 2,
				case .floats(let nativeValues)? = fixture.expected.fields[
					"entropy.clusters.input_shannon_entropy"],
				nativeValues.count == sourceHistograms.count
			else { throw SemanticDumpError.unimplemented }
			for index in sourceHistograms.indices {
				let swiftValue = sourceHistograms[index].bitCost
				let nativeValue = nativeValues[index]
				diagnostics.append(
					FloatCostDiagnostic(
						fixture: proof.fixture,
						nativeField:
							"entropy.clusters.input_shannon_entropy[\(index)]",
						swiftValue: swiftValue, nativeValue: nativeValue,
						signedDelta: swiftValue - nativeValue,
						signedULPDelta: Int64(swiftValue.bitPattern)
							- Int64(nativeValue.bitPattern),
						firstDivergingOperation: swiftValue.bitPattern
							== nativeValue.bitPattern
							? nil : .unresolved))
			}
			var combined = sourceHistograms[0]
			combined.add(sourceHistograms[1])
			combined.computeBitCost()
			let expectedDistance =
				(combined.bitCost - sourceHistograms[0].bitCost)
				- sourceHistograms[1].bitCost
			let actualDistance = HistogramCluster.distance(
				sourceHistograms[0], sourceHistograms[1])
			#expect(actualDistance.bitPattern == expectedDistance.bitPattern)
		}
		#expect(diagnostics.count >= distanceProofs.count * 2)
		#expect(
			diagnostics.allSatisfy { diagnostic in
				distanceProofs.contains {
					$0.fixture == diagnostic.fixture
						&& $0.nativeFields.contains(
							where: diagnostic.nativeField.hasPrefix)
				}
			})
		for diagnostic in diagnostics where diagnostic.signedULPDelta != 0 {
			print(diagnostic.description)
		}
	}

	@Test
	func shannonCostsRetainPinnedFixtureDiagnostics() throws {
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
		assertFloatFields(actual, match: fixture.expected, fixture: "clusters_fast_merge")

		let roundedTotal = try EntropyReferenceFixture.load(
			"clusters_rounded_float_total_fast")
		let roundedHistograms = try histograms(from: roundedTotal)
		let rounded = SwiftEntropySemanticEncoding.clusters(
			histograms: roundedHistograms, limit: 1)
		assertFloatFields(
			rounded, match: roundedTotal.expected,
			fixture: "clusters_rounded_float_total_fast")
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
			assertFloatFields(actual, match: fixture.expected, fixture: name)
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
		assertFloatFields(
			actual, match: fixture.expected, fixture: "clusters_default_cap_fast")
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

private func floats(_ dump: SemanticDump, _ field: String) throws -> [Float] {
	guard case .floats(let values)? = dump.fields[field] else {
		throw SemanticDumpError.unimplemented
	}
	return values
}

private let shannonFields: Set<String> = [
	"entropy.clusters.input_shannon_entropy",
	"entropy.clusters.output_shannon_entropy",
]

func assertFloatFields(
	_ actual: SemanticDump, match expected: SemanticDump, fixture: String,
	excludingFields: Set<String> = []
) {
	for field in shannonFields where !excludingFields.contains(field) {
		guard
			case .floats(let actualValues)? = actual.fields[field],
			case .floats(let expectedValues)? = expected.fields[field]
		else {
			Issue.record("Missing Shannon entropy field: \(field)")
			continue
		}
		#expect(actualValues.count == expectedValues.count, Comment(rawValue: field))
		for (index, pair) in zip(actualValues, expectedValues).enumerated() {
			let (swiftValue, nativeValue) = pair
			let diagnostic = FloatCostDiagnostic(
				fixture: fixture,
				nativeField: "\(field)[\(index)]",
				swiftValue: swiftValue,
				nativeValue: nativeValue,
				signedDelta: swiftValue - nativeValue,
				signedULPDelta: Int64(swiftValue.bitPattern)
					- Int64(nativeValue.bitPattern),
				firstDivergingOperation: swiftValue.bitPattern
					== nativeValue.bitPattern ? nil : .unresolved)
			if diagnostic.signedULPDelta != 0 { print(diagnostic.description) }
		}
	}
}
