import Testing

@testable import JXLEncoder

@Suite("Upstream ANS histogram translation")
struct ANSHistogramWriterTests {
	private func strategy(_ code: Int64) -> ANSHistogramStrategy {
		switch code {
		case 0: .fast
		case 1: .approximate
		case 2: .precise
		default: preconditionFailure("invalid ANS strategy fixture")
		}
	}

	private func strategyCode(_ strategy: ANSHistogramStrategy) -> Int64 {
		switch strategy {
		case .fast: 0
		case .approximate: 1
		case .precise: 2
		}
	}

	@Test
	func declaredANSProofCasesMatchBoundedPublicObservations() throws {
		for proof in ANSHistogramProofCase.all {
			let fixture = try EntropyReferenceFixture.load(proof.fixture)
			switch proof.observation {
			case .selectedCandidate, .preciseContextMap:
				let selectedStrategy = proof.strategy
				let shift = proof.selectedShift
				let code = strategyCode(selectedStrategy)
				#expect(
					try fixture.integers(
						fixture.input, "input.histogram.strategy") == [
							code
						],
					Comment(rawValue: proof.fixture))
				let counts = try fixture.integers(
					fixture.input, "input.histogram.counts"
				).map(UInt32.init)
				let selected = ANSEncodingHistogram.computeBest(
					counts: counts, strategy: selectedStrategy)
				let expectedCounts = try fixture.integers(
					fixture.expected, "entropy.ans_cost.normalized"
				).map(Int.init)
				let expectedMethod = try fixture.integers(
					fixture.expected, "entropy.ans_cost.serialized_method")[0]
				let expectedShift = try fixture.integers(
					fixture.expected, "entropy.ans_cost.serialized_shift")[0]
				let expectedBits = try fixture.integers(
					fixture.expected, "entropy.ans_cost.header_bits")[0]
				let expectedBytes = try fixture.integers(
					fixture.expected, "entropy.ans_cost.bytes"
				).map(Int.init)
				guard
					case .floats(let sourceDataBits)? = fixture.expected.fields[
						"entropy.ans_cost.source_data_bits"],
					case .floats(let totalCost)? = fixture.expected.fields[
						"entropy.ans_cost.total_cost"]
				else { throw SemanticDumpError.unimplemented }
				#expect(expectedShift == Int64(shift ?? -1))
				#expect(expectedMethod == (shift == nil ? 0 : 2))
				#expect(
					Array(
						selected.normalizedCounts.prefix(
							expectedCounts.count))
						== expectedCounts)
				#expect(selected.method == (shift.map { $0 + 1 } ?? 0))
				#expect(selected.headerBits == expectedBits)
				#expect(selected.dataBits == sourceDataBits[0])
				#expect(selected.cost == totalCost[0])
				var writer = BitWriter()
				selected.write(to: &writer)
				writer.zeroPadToByte()
				#expect(writer.bytes.map(Int.init) == expectedBytes)
			case .semanticHistogram(let selectedStrategy):
				guard
					case .integers(let counts)? = fixture.input.fields[
						"input.histogram.counts"],
					case .integers(let logAlpha)? = fixture.input.fields[
						"input.histogram.log_alpha_size"],
					case .integers(let code)? = fixture.input.fields[
						"input.histogram.strategy"]
				else { throw SemanticDumpError.unimplemented }
				#expect(code == [strategyCode(selectedStrategy)])
				let actual = SwiftEntropySemanticEncoding.histogram(
					counts: counts.map(Int.init),
					logAlphaSize: Int(logAlpha[0]),
					strategy: selectedStrategy)
				#expect(actual.differences(from: fixture.expected).isEmpty)
			}
		}
		let selectedShifts = Set(
			ANSHistogramProofCase.selectedCandidates.compactMap(\.selectedShift))
		#expect(selectedShifts == Set([0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]))
		#expect(!selectedShifts.contains(1))
	}

	@Test
	func fixedShiftHistogramMatchesReferenceRepresentation() throws {
		let histogram = ANSEncodingHistogram.rebalanced(counts: [1, 1], shift: 0)
		#expect(histogram.normalizedCounts == [2048, 2048])
		#expect(histogram.alphabetSize == 2)
		#expect(histogram.method == 1)
		#expect(histogram.omitPosition == 0)
		#expect(histogram.headerBits == 19)
		#expect(histogram.dataBits == 1.9999995)
		#expect(histogram.cost == 21)

		for (name, shift) in [
			("ans_sparse_precise", 0),
			("ans_precision_fast", 6),
			("ans_skewed_approximate", 4),
		] {
			let fixture = try EntropyReferenceFixture.load(name)
			let inputCounts = try fixture.integers(
				fixture.input, "input.histogram.counts"
			).map(UInt32.init)
			let expectedCounts = try fixture.integers(
				fixture.expected, "entropy.histogram.normalized"
			).map(Int.init)
			let expectedHeaderBits = try fixture.integers(
				fixture.expected, "entropy.histogram.bit_count")[0]
			let expectedBytes = try fixture.integers(
				fixture.expected, "entropy.histogram.bytes"
			).map(Int.init)
			let candidate = ANSEncodingHistogram.rebalanced(
				counts: inputCounts, shift: shift)
			var encoded = BitWriter()
			candidate.write(to: &encoded)
			encoded.zeroPadToByte()
			#expect(
				candidate.normalizedCounts == expectedCounts,
				Comment(rawValue: name))
			#expect(candidate.method == shift + 1, Comment(rawValue: name))
			#expect(candidate.headerBits == expectedHeaderBits, Comment(rawValue: name))
			#expect(
				encoded.bytes.map(Int.init) == expectedBytes,
				Comment(rawValue: name))
		}

		for name in [
			"ans_cost_sparse_precise",
			"ans_cost_skewed_approximate",
			"ans_cost_approx_step2_witness",
			"ans_cost_precise_map_witness",
			"ans_cost_scaled_fast", "ans_cost_shift_2", "ans_cost_shift_3",
		] {
			let fixture = try EntropyReferenceFixture.load(name)
			let counts = try fixture.integers(
				fixture.input, "input.histogram.counts"
			).map(UInt32.init)
			let shift = Int(
				try fixture.integers(
					fixture.expected, "entropy.ans_cost.serialized_shift")[0])
			let expectedMethod = try fixture.integers(
				fixture.expected, "entropy.ans_cost.serialized_method")[0]
			let candidate = ANSEncodingHistogram.rebalanced(
				counts: counts, shift: shift)
			let expectedCounts = try fixture.integers(
				fixture.expected, "entropy.ans_cost.normalized"
			).map(Int.init)
			let expectedHeaderBits = try fixture.integers(
				fixture.expected, "entropy.ans_cost.header_bits")[0]
			let expectedBytes = try fixture.integers(
				fixture.expected, "entropy.ans_cost.bytes"
			).map(Int.init)
			guard
				case .floats(let sourceDataBits)? = fixture.expected.fields[
					"entropy.ans_cost.source_data_bits"],
				case .floats(let publicTotalCost)? = fixture.expected.fields[
					"entropy.ans_cost.total_cost"]
			else {
				Issue.record("\(name) is missing a required cost observation")
				continue
			}
			var encoded = BitWriter()
			candidate.write(to: &encoded)
			encoded.zeroPadToByte()
			#expect(
				candidate.normalizedCounts == expectedCounts,
				Comment(rawValue: name))
			#expect(expectedMethod == 2, Comment(rawValue: name))
			#expect(candidate.method == shift + 1, Comment(rawValue: name))
			#expect(candidate.headerBits == expectedHeaderBits, Comment(rawValue: name))
			#expect(
				encoded.bytes.map(Int.init) == expectedBytes,
				Comment(rawValue: name))
			#expect(candidate.dataBits == sourceDataBits[0], Comment(rawValue: name))
			#expect(candidate.cost == publicTotalCost[0], Comment(rawValue: name))
		}

		let tieWeighted = ANSEncodingHistogram.rebalanced(
			counts: [18544, 1426, 11647, 13067, 885, 17633, 13993, 12692, 7158],
			shift: 6)
		var tieWriter = BitWriter()
		tieWeighted.write(to: &tieWriter)
		tieWriter.zeroPadToByte()
		#expect(
			tieWeighted.normalizedCounts == [784, 60, 496, 544, 36, 752, 592, 528, 304])
		#expect(tieWeighted.omitPosition == 0)
		#expect(tieWeighted.headerBits == 74)
		#expect(
			tieWriter.bytes.map(Int.init) == [
				236, 18, 52, 8, 192, 127, 145, 87, 194, 0,
			])

		let scaledStep = ANSEncodingHistogram.rebalanced(
			counts: [9294, 684, 593, 7685, 3091, 9802, 4825, 1107], shift: 6)
		var scaledWriter = BitWriter()
		scaledStep.write(to: &scaledWriter)
		scaledWriter.zeroPadToByte()
		#expect(scaledStep.normalizedCounts == [1024, 80, 64, 848, 336, 1096, 528, 120])
		#expect(scaledStep.headerBits == 72)
		#expect(
			scaledWriter.bytes.map(Int.init) == [236, 42, 148, 224, 0, 4, 132, 90, 225])

		let displacedOmit = ANSEncodingHistogram.rebalanced(
			counts: [1800, 1, 1801], shift: 0)
		var omitWriter = BitWriter()
		displacedOmit.write(to: &omitWriter)
		omitWriter.zeroPadToByte()
		#expect(displacedOmit.normalizedCounts == [2047, 1, 2048])
		#expect(displacedOmit.omitPosition == 0)
		#expect(displacedOmit.headerBits == 22)
		#expect(omitWriter.bytes.map(Int.init) == [16, 216, 0])
	}

	@Test
	func rebalancingPreservesSupportAndTableMass() {
		let distributions: [[UInt32]] = [
			[1, 7, 3, 0], [10_000, 1, 4, 16, 256, 1024],
			[1800, 1, 1801], [1, 1, 1, 1, 1, 1, 1, 1],
		]
		for counts in distributions {
			for shift in 0..<ANSConstants.logTabSize {
				let histogram = ANSEncodingHistogram.rebalanced(
					counts: counts, shift: shift)
				#expect(histogram.normalizedCounts.count == counts.count)
				for index in counts.indices {
					#expect(
						(counts[index] == 0)
							== (histogram.normalizedCounts[index] == 0))
				}
				#expect(
					histogram.normalizedCounts.reduce(0, +)
						== ANSConstants.tabSize)
				#expect(histogram.normalizedCounts[histogram.omitPosition] > 0)
			}
		}
		let denseRounded = ANSEncodingHistogram.rebalanced(
			counts: [UInt32](repeating: 1, count: 248), shift: 11)
		#expect(denseRounded.normalizedCounts.reduce(0, +) == ANSConstants.tabSize)
		#expect(denseRounded.normalizedCounts.allSatisfy { $0 > 0 })
	}

	@Test
	func referenceHistogramCostFixturesRejectMalformedRecords() throws {
		var input = SemanticDump()
		input.record("input.histogram.counts", .integers([1, 2]))
		input.record("input.histogram.log_alpha_size", .integers([7]))
		input.record("input.histogram.strategy", .integers([1]))
		var expected = SemanticDump()
		expected.record("entropy.ans_cost.normalized", .integers([2048, 2048]))
		expected.record("entropy.ans_cost.serialized_method", .integers([2]))
		expected.record("entropy.ans_cost.serialized_shift", .integers([0]))
		expected.record("entropy.ans_cost.header_bits", .integers([24]))
		expected.record("entropy.ans_cost.bytes", .integers([0, 0, 0]))
		expected.record("entropy.ans_cost.total_cost", .floats([2]))
		#expect(throws: SemanticDumpError.self) {
			try EntropyReferenceFixture.validate(
				name: "ans_cost_missing_source_data", input: input,
				expected: expected)
		}
		var twoSymbolExpected = SemanticDump()
		twoSymbolExpected.record("entropy.ans_cost.normalized", .integers([2048, 2048]))
		twoSymbolExpected.record("entropy.ans_cost.serialized_method", .integers([0]))
		twoSymbolExpected.record("entropy.ans_cost.serialized_shift", .integers([-1]))
		twoSymbolExpected.record("entropy.ans_cost.header_bits", .integers([6]))
		twoSymbolExpected.record("entropy.ans_cost.bytes", .integers([6]))
		twoSymbolExpected.record("entropy.ans_cost.total_cost", .floats([8]))
		twoSymbolExpected.record("entropy.ans_cost.source_data_bits", .floats([2]))
		func makeInput(counts: [Int64], logAlpha: Int64 = 7, strategy: Int64 = 2)
			-> SemanticDump
		{
			var dump = SemanticDump()
			dump.record("input.histogram.counts", .integers(counts))
			dump.record("input.histogram.log_alpha_size", .integers([logAlpha]))
			dump.record("input.histogram.strategy", .integers([strategy]))
			return dump
		}
		var boundaryExpected = SemanticDump()
		boundaryExpected.record("entropy.ans_cost.normalized", .integers([4096]))
		boundaryExpected.record("entropy.ans_cost.serialized_method", .integers([1]))
		boundaryExpected.record("entropy.ans_cost.serialized_shift", .integers([-1]))
		boundaryExpected.record("entropy.ans_cost.header_bits", .integers([3]))
		boundaryExpected.record("entropy.ans_cost.bytes", .integers([1]))
		boundaryExpected.record("entropy.ans_cost.total_cost", .floats([3]))
		boundaryExpected.record("entropy.ans_cost.source_data_bits", .floats([0]))
		try EntropyReferenceFixture.validate(
			name: "ans_cost_boundary",
			input: makeInput(counts: [Int64(Int32.max)], logAlpha: 5, strategy: 0),
			expected: boundaryExpected)
		try EntropyReferenceFixture.validate(
			name: "ans_cost_upper_boundary",
			input: makeInput(counts: [Int64(Int32.max)], logAlpha: 8, strategy: 2),
			expected: boundaryExpected)
		try EntropyReferenceFixture.validate(
			name: "ans_cost_control",
			input: makeInput(counts: [1, 1], logAlpha: 5, strategy: 0),
			expected: twoSymbolExpected)
		#expect(throws: SemanticDumpError.self) {
			try EntropyReferenceFixture.validate(
				name: "ans_cost_bad_log_alpha",
				input: makeInput(counts: [1, 1], logAlpha: 4, strategy: 0),
				expected: twoSymbolExpected)
		}
		#expect(throws: SemanticDumpError.self) {
			try EntropyReferenceFixture.validate(
				name: "ans_cost_bad_strategy",
				input: makeInput(counts: [1, 1], logAlpha: 5, strategy: 3),
				expected: twoSymbolExpected)
		}
		#expect(throws: SemanticDumpError.self) {
			try EntropyReferenceFixture.validate(
				name: "ans_cost_negative_count",
				input: makeInput(counts: [-1, 1], logAlpha: 5, strategy: 0),
				expected: twoSymbolExpected)
		}
		#expect(throws: SemanticDumpError.self) {
			try EntropyReferenceFixture.validate(
				name: "ans_cost_overflow_sum",
				input: makeInput(
					counts: [Int64(Int32.max), 1], logAlpha: 5, strategy: 0),
				expected: twoSymbolExpected
			)
		}
		var emptyExpected = SemanticDump()
		emptyExpected.record("entropy.ans_cost.normalized", .integers([]))
		emptyExpected.record("entropy.ans_cost.serialized_method", .integers([1]))
		emptyExpected.record("entropy.ans_cost.serialized_shift", .integers([-1]))
		emptyExpected.record("entropy.ans_cost.header_bits", .integers([3]))
		emptyExpected.record("entropy.ans_cost.bytes", .integers([1]))
		emptyExpected.record("entropy.ans_cost.total_cost", .floats([3]))
		emptyExpected.record("entropy.ans_cost.source_data_bits", .floats([0]))
		#expect(throws: SemanticDumpError.self) {
			try EntropyReferenceFixture.validate(
				name: "ans_cost_oversize_alphabet",
				input: makeInput(
					counts: Array(repeating: 0, count: 257), logAlpha: 8,
					strategy: 0),
				expected: emptyExpected)
		}
		var malformedDimension = SemanticDump()
		malformedDimension.record("input.histogram.counts", .integers([1, 1]))
		malformedDimension.record("input.histogram.log_alpha_size", .integers([5, 8]))
		malformedDimension.record("input.histogram.strategy", .integers([0]))
		#expect(throws: SemanticDumpError.self) {
			try EntropyReferenceFixture.validate(
				name: "ans_cost_log_alpha_dimension",
				input: malformedDimension, expected: twoSymbolExpected)
		}
		for name in [
			"ans_cost_sparse_precise", "ans_cost_flat_alphabet47",
			"ans_cost_skewed_approximate", "ans_cost_approx_step2_witness",
			"ans_cost_precise_map_witness",
			"ans_cost_scaled_fast", "ans_cost_shift_2", "ans_cost_shift_3",
			"ans_cost_shift_5", "ans_cost_shift_7", "ans_cost_shift_8",
			"ans_cost_shift_9", "ans_cost_shift_10", "ans_cost_shift_11",
		] {
			let fixture = try EntropyReferenceFixture.load(name)
			#expect(fixture.expected.fields["entropy.ans_cost.total_cost"] != nil)
		}
	}

	@Test
	func approximateSearchMatchesReferencePrecisionAndCosts() throws {
		let fixture = try EntropyReferenceFixture.load("ans_cost_skewed_approximate")
		#expect(try fixture.integers(fixture.input, "input.histogram.strategy") == [1])
		let counts = try fixture.integers(
			fixture.input, "input.histogram.counts"
		).map(UInt32.init)
		let result = ANSEncodingHistogram.computeBest(
			counts: counts, strategy: .approximate)
		let expectedCounts = try fixture.integers(
			fixture.expected, "entropy.ans_cost.normalized"
		).map(Int.init)
		let expectedShift = try fixture.integers(
			fixture.expected, "entropy.ans_cost.serialized_shift")[0]
		let expectedHeaderBits = try fixture.integers(
			fixture.expected, "entropy.ans_cost.header_bits")[0]
		guard
			case .floats(let sourceDataBits)? = fixture.expected.fields[
				"entropy.ans_cost.source_data_bits"],
			case .floats(let publicTotalCost)? = fixture.expected.fields[
				"entropy.ans_cost.total_cost"]
		else { throw SemanticDumpError.unimplemented }
		#expect(
			Array(result.normalizedCounts.prefix(expectedCounts.count))
				== expectedCounts)
		#expect(result.method == expectedShift + 1)
		#expect(result.headerBits == expectedHeaderBits)
		#expect(result.dataBits == sourceDataBits[0])
		#expect(result.cost == publicTotalCost[0])
	}

	@Test
	func flatCandidateCostMatchesPublicReference() throws {
		let fixture = try EntropyReferenceFixture.load("ans_cost_flat_alphabet47")
		let counts = try fixture.integers(
			fixture.input, "input.histogram.counts"
		).map(UInt32.init)
		let result = ANSEncodingHistogram.computeBest(counts: counts, strategy: .fast)
		let expectedCounts = try fixture.integers(
			fixture.expected, "entropy.ans_cost.normalized"
		).map(Int.init)
		let expectedHeaderBits = try fixture.integers(
			fixture.expected, "entropy.ans_cost.header_bits")[0]
		guard
			case .floats(let expectedDataBits)? = fixture.expected.fields[
				"entropy.ans_cost.source_data_bits"],
			case .floats(let expectedCost)? = fixture.expected.fields[
				"entropy.ans_cost.total_cost"]
		else { throw SemanticDumpError.unimplemented }
		#expect(result.method == 0)
		#expect(
			Array(result.normalizedCounts.prefix(expectedCounts.count))
				== expectedCounts)
		#expect(result.headerBits == expectedHeaderBits)
		#expect(result.dataBits == expectedDataBits[0])
		#expect(result.cost == expectedCost[0])
	}

	@Test
	func preciseSearchRetainsEarlierCandidateOnCostTie() throws {
		let fixture = try EntropyReferenceFixture.load("ans_cost_shift_8")
		let counts = try fixture.integers(
			fixture.input, "input.histogram.counts"
		).map(UInt32.init)
		let earlier = ANSEncodingHistogram.rebalanced(counts: counts, shift: 8)
		for shift in 9...11 {
			let later = ANSEncodingHistogram.rebalanced(counts: counts, shift: shift)
			#expect(later.cost == earlier.cost)
		}
		let selected = ANSEncodingHistogram.computeBest(counts: counts, strategy: .precise)
		#expect(selected.method == 9)
		#expect(selected.normalizedCounts == earlier.normalizedCounts)
	}

	@Test
	func approximateSearchIncludesEveryEvenShift() throws {
		let fixture = try EntropyReferenceFixture.load("ans_cost_approx_step2_witness")
		let counts = try fixture.integers(
			fixture.input, "input.histogram.counts"
		).map(UInt32.init)
		let result = ANSEncodingHistogram.computeBest(
			counts: counts, strategy: .approximate)
		let expectedShift = try fixture.integers(
			fixture.expected, "entropy.ans_cost.serialized_shift")[0]
		let expectedCounts = try fixture.integers(
			fixture.expected, "entropy.ans_cost.normalized"
		).map(Int.init)
		#expect(expectedShift == 6)
		#expect(result.method == expectedShift + 1)
		#expect(
			Array(result.normalizedCounts.prefix(expectedCounts.count))
				== expectedCounts)
	}

	@Test
	func degenerateAndFlatHistogramsMatchReference() throws {
		for name in ["ans_empty", "ans_all_zero", "ans_singleton_precise"] {
			let fixture = try EntropyReferenceFixture.load(name)
			guard
				case .integers(let counts)? = fixture.input.fields[
					"input.histogram.counts"],
				case .integers(let strategyCode)? = fixture.input.fields[
					"input.histogram.strategy"]
			else { throw SemanticDumpError.unimplemented }
			let result = ANSEncodingHistogram.computeBest(
				counts: counts.map(UInt32.init), strategy: strategy(strategyCode[0])
			)
			let expectedNormalized = try fixture.integers(
				fixture.expected, "entropy.histogram.normalized"
			).map(Int.init)
			let expectedBits = try fixture.integers(
				fixture.expected, "entropy.histogram.bit_count")[0]
			let expectedBytes = try fixture.integers(
				fixture.expected, "entropy.histogram.bytes"
			).map(Int.init)
			var writer = BitWriter()
			result.write(to: &writer)
			#expect(
				Array(result.normalizedCounts.prefix(result.alphabetSize))
					== expectedNormalized, Comment(rawValue: name))
			#expect(result.method == 1)
			#expect(result.headerBits == expectedBits)
			#expect(writer.bytes.map(Int.init) == expectedBytes)
			#expect(result.dataBits == 0)
			#expect(result.cost == Float(expectedBits))
		}
	}

	@Test
	func histogramSerializationMatchesReferenceOmitTiesAndRuns() throws {
		for name in [
			"ans_cost_sparse_precise", "ans_cost_skewed_approximate",
			"ans_cost_shift_5", "ans_cost_shift_7", "ans_cost_shift_8",
			"ans_cost_shift_9", "ans_cost_shift_10", "ans_cost_shift_11",
		] {
			let fixture = try EntropyReferenceFixture.load(name)
			let counts = try fixture.integers(
				fixture.input, "input.histogram.counts"
			).map(UInt32.init)
			let strategyCode = try fixture.integers(
				fixture.input, "input.histogram.strategy")[0]
			let histogram = ANSEncodingHistogram.computeBest(
				counts: counts, strategy: strategy(strategyCode))
			var writer = BitWriter()
			histogram.write(to: &writer)
			writer.zeroPadToByte()
			let expectedBits = try fixture.integers(
				fixture.expected, "entropy.ans_cost.header_bits")[0]
			let expectedBytes = try fixture.integers(
				fixture.expected, "entropy.ans_cost.bytes"
			).map(Int.init)
			#expect(histogram.headerBits == expectedBits, Comment(rawValue: name))
			#expect(
				writer.bytes.map(Int.init) == expectedBytes, Comment(rawValue: name)
			)
		}
		// Encode supplies header bits/bytes; omit positions are source-derived from
		// RebalanceHistogram, not captured from private libjxl state.
		for proof in ANSHistogramProofCase.inlineRLE {
			let result = ANSEncodingHistogram.computeBest(
				counts: proof.counts, strategy: .precise)
			var writer = BitWriter()
			result.write(to: &writer)
			writer.zeroPadToByte()
			#expect(
				proof.decisions.isSuperset(of: [.omission, .generalSerialization]))
			#expect(
				Array(result.normalizedCounts.prefix(result.alphabetSize))
					== proof.normalized, Comment(rawValue: proof.name))
			#expect(
				result.omitPosition == proof.sourceDerivedOmitPosition,
				Comment(rawValue: proof.name))
			#expect(
				result.headerBits == proof.headerBits, Comment(rawValue: proof.name)
			)
			#expect(
				writer.bytes.map(Int.init) == proof.bytes,
				Comment(rawValue: proof.name))
		}
	}

	@Test
	func existingHistogramFixturesMatchReferenceWithoutKnownDifferences() throws {
		for name in [
			"ans_empty", "ans_all_zero", "ans_singleton_precise",
			"ans_two_symbol_approximate", "ans_precision_fast", "ans_sparse_precise",
			"ans_skewed_approximate", "ans_alphabet48_fast", "ans_alphabet64_fast",
		] {
			let fixture = try EntropyReferenceFixture.load(name)
			guard
				case .integers(let counts)? = fixture.input.fields[
					"input.histogram.counts"],
				case .integers(let logAlpha)? = fixture.input.fields[
					"input.histogram.log_alpha_size"],
				case .integers(let strategyCode)? = fixture.input.fields[
					"input.histogram.strategy"]
			else { throw SemanticDumpError.unimplemented }
			let actual = SwiftEntropySemanticEncoding.histogram(
				counts: counts.map(Int.init), logAlphaSize: Int(logAlpha[0]),
				strategy: strategy(strategyCode[0]))
			#expect(
				actual.differences(from: fixture.expected).isEmpty,
				Comment(rawValue: name))
		}
	}

	@Test
	func entropyCodeWriterRetainsSelectedHistogramEncoding() throws {
		let fixture = try EntropyReferenceFixture.load("ans_cost_approx_step2_witness")
		let counts = try fixture.integers(
			fixture.input, "input.histogram.counts"
		).map(UInt32.init)
		let selected = ANSEncodingHistogram.computeBest(
			counts: counts, strategy: .approximate)
		let flat = ANSEncodingHistogram.computeBest(
			counts: [UInt32](repeating: 1, count: 47), strategy: .fast)
		let histograms = [selected, flat]
		let code = EntropyCode(
			contextMap: [], prefixCodes: [], ansHistograms: histograms)
		#expect(code.ansHistograms?.map(\.method) == [7, 0])
		#expect(code.ansInfoTables?.count == histograms.count)
		for (histogram, table) in zip(histograms, code.ansInfoTables ?? []) {
			#expect(
				table.map(\.freq)
					== histogram.normalizedCounts.prefix(histogram.alphabetSize)
					.map {
						$0
					})
		}
		var actual = BitWriter()
		EntropyCodeWriter.write(code, writer: &actual)
		var expected = BitWriter()
		expected.write(1, 0)
		expected.write(2, UInt64(ANSConstants.logAlphaSize - 5))
		PrefixCodeWriter.writeUintConfigs(
			count: histograms.count, logAlphaSize: ANSConstants.logAlphaSize,
			writer: &expected)
		for histogram in histograms { histogram.write(to: &expected) }
		var fullPrecision = BitWriter()
		fullPrecision.write(1, 0)
		fullPrecision.write(2, UInt64(ANSConstants.logAlphaSize - 5))
		PrefixCodeWriter.writeUintConfigs(
			count: histograms.count, logAlphaSize: ANSConstants.logAlphaSize,
			writer: &fullPrecision)
		for histogram in histograms {
			ANSHistogramWriter.write(
				counts: histogram.normalizedCounts, writer: &fullPrecision)
		}
		#expect(actual.bitsWritten == expected.bitsWritten)
		#expect(actual.bytes == expected.bytes)
		#expect(actual.bytes != fullPrecision.bytes)
	}

	@Test
	func contextMapHistogramUsesReferenceANSSelection() throws {
		let fixture = try EntropyReferenceFixture.load("context_mtf_ans")
		let entries = try fixture.integers(
			fixture.input, "input.context_map.entries"
		).map(UInt8.init)
		let prepared = ContextMapEncoding.prepare(entries, numHistograms: 4)
		guard case .moveToFront = prepared.representation,
			let selected = prepared.moveToFront
		else { throw SemanticDumpError.unimplemented }
		#expect(!selected.usesPrefixCode)
		#expect(selected.ansHistograms.count == 1)
		var actual = BitWriter()
		ContextMapEncoding.write(prepared, to: &actual)
		#expect(
			actual.bytes.map(Int64.init)
				== (try fixture.integers(
					fixture.expected, "entropy.context_map.bytes")))
	}

	@Test
	func suppliedANSInfoTablesRemainSerializable() {
		let table = ANSInfoTable.build(
			distribution: [1024, 2048, 1024], alphabetSize: 3,
			logAlphaSize: ANSConstants.logAlphaSize)
		let code = EntropyCode(
			contextMap: [0], prefixCodes: [], ansInfoTables: [table])
		#expect(code.ansHistograms == nil)
		var actual = BitWriter()
		EntropyCodeWriter.write(code, writer: &actual)
		var expected = BitWriter()
		EntropyCodeWriter.writeContextMap(code, writer: &expected)
		expected.write(1, 0)
		expected.write(2, UInt64(ANSConstants.logAlphaSize - 5))
		PrefixCodeWriter.writeUintConfigs(
			count: 1, logAlphaSize: ANSConstants.logAlphaSize, writer: &expected)
		ANSHistogramWriter.write(counts: table.map(\.freq), writer: &expected)
		#expect(actual.bitsWritten == expected.bitsWritten)
		#expect(actual.bytes == expected.bytes)
	}
}
