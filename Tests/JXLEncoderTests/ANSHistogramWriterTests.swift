import Testing

@testable import JXLEncoder

@Suite("Upstream ANS histogram translation")
struct ANSHistogramWriterTests {
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
			"ans_cost_sparse_precise", "ans_cost_skewed_approximate",
			"ans_cost_scaled_fast", "ans_cost_shift_2", "ans_cost_shift_3",
			"ans_cost_shift_5", "ans_cost_shift_7", "ans_cost_shift_8",
			"ans_cost_shift_9", "ans_cost_shift_10", "ans_cost_shift_11",
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
		for name in [
			"ans_cost_sparse_precise", "ans_cost_skewed_approximate",
			"ans_cost_scaled_fast", "ans_cost_shift_2", "ans_cost_shift_3",
			"ans_cost_shift_5", "ans_cost_shift_7", "ans_cost_shift_8",
			"ans_cost_shift_9", "ans_cost_shift_10", "ans_cost_shift_11",
		] {
			let fixture = try EntropyReferenceFixture.load(name)
			#expect(fixture.expected.fields["entropy.ans_cost.total_cost"] != nil)
		}
	}

	@Test(.disabled("Pending implementation"))
	func approximateSearchMatchesReferencePrecisionAndCosts() {
		Issue.record(
			"The e4 shift sequence and strict cost comparison select the upstream candidate"
		)
	}

	@Test(.disabled("Pending implementation"))
	func degenerateAndFlatHistogramsMatchReference() {
		Issue.record(
			"Empty, all-zero, singleton and flat selections retain exact encoding and costs"
		)
	}

	@Test(.disabled("Pending implementation"))
	func histogramSerializationMatchesReferenceOmitTiesAndRuns() {
		Issue.record(
			"Selected omission, precision and RLE boundaries produce upstream bits")
	}

	@Test(.disabled("Pending implementation"))
	func existingHistogramFixturesMatchReferenceWithoutKnownDifferences() {
		Issue.record(
			"Every inherited histogram fixture matches with its actual upstream strategy"
		)
	}

	@Test(.disabled("Pending implementation"))
	func sectionOptimizerUsesApproximateANSSelection() {
		Issue.record(
			"Production alias tables and retained histograms share the e4 selected counts"
		)
	}

	@Test(.disabled("Pending implementation"))
	func entropyCodeWriterRetainsSelectedHistogramEncoding() {
		Issue.record(
			"Serialized headers consume retained choices instead of reconstructing them from frequencies"
		)
	}

	@Test(.disabled("Pending implementation"))
	func contextMapHistogramUsesReferenceANSSelection() {
		Issue.record(
			"The existing direct map ANS path uses the reference histogram strategy")
	}

	@Test(.disabled("Pending implementation"))
	func suppliedANSInfoTablesRemainSerializable() {
		Issue.record(
			"The public frequency-only initializer preserves valid supplied-table serialization"
		)
	}
}
