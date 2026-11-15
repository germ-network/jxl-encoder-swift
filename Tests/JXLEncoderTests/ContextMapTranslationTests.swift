import Testing

@testable import JXLEncoder

struct ContextMapProofCase: Sendable {
	let fixture: String
	let decisions: Set<String>
	let category: String

	init(fixture: String, decisions: Set<String>, category: String = "context_map") {
		self.fixture = fixture
		self.decisions = decisions
		self.category = category
	}

	var reference: String {
		"Tests/JXLEncoderTests/Fixtures/entropy/\(fixture).expected.sem#\(category)"
	}

	static let all: [ContextMapProofCase] = [
		.init(
			fixture: "context_single_histogram",
			decisions: ["EW-01", "EW-02", "EW-04", "EW-09"]),
		.init(fixture: "context_simple_two_histograms", decisions: ["EW-02", "EW-04"]),
		.init(fixture: "context_simple_profitability", decisions: ["EW-02"]),
		.init(fixture: "context_tie_raw_mtf", decisions: ["EW-02"]),
		.init(
			fixture: "context_mtf_ans",
			decisions: ["EW-02", "EW-03", "EW-08", "EW-09"]),
		.init(fixture: "context_raw_ans", decisions: ["EW-03", "EW-08"]),
		.init(fixture: "context_prefix_99", decisions: ["EW-03", "EW-04"]),
		.init(fixture: "context_ans_100", decisions: ["EW-03", "EW-08"]),
		.init(fixture: "context_raw_rle", decisions: ["EW-06", "EW-07"]),
		.init(
			fixture: "context_entropy_rle", decisions: ["EW-06", "EW-07"],
			category: "context_entropy"),
		.init(
			fixture: "context_entropy_prefix_99", decisions: ["EW-03", "EW-04"],
			category: "context_entropy"),
		.init(
			fixture: "context_entropy_ans_100", decisions: ["EW-03", "EW-08"],
			category: "context_entropy"),
		.init(
			fixture: "context_entropy_rle_prefix_two_hist",
			decisions: ["EW-03", "EW-04", "EW-06", "EW-07"],
			category: "context_entropy"),
		.init(
			fixture: "context_entropy_singleton_contexts",
			decisions: ["EW-03"], category: "context_entropy"),
		.init(
			fixture: "context_entropy_rle_cumulative_rounding",
			decisions: ["EW-07"], category: "context_entropy"),
		.init(
			fixture: "context_entropy_rle_threshold_21",
			decisions: ["EW-07"], category: "context_entropy"),
		.init(
			fixture: "context_entropy_rle_threshold_22",
			decisions: ["EW-07"], category: "context_entropy"),
		.init(fixture: "context_full_256", decisions: ["EW-02", "EW-04"]),
	]

	static func proves(_ reference: DecisionInventory.FixtureReference, decision: String)
		-> Bool
	{
		all.contains {
			$0.reference == "\(reference.path)#\(reference.category ?? "")"
				&& $0.decisions.contains(decision)
		}
	}
}

@Suite("Upstream context-map encoding")
struct ContextMapTranslationTests {
	@Test
	func fixedUintMatchesPinnedReference() throws {
		let configuration = HybridUintConfiguration(
			splitExponent: 2, msbInToken: 0, lsbInToken: 1)
		let witnesses: [(UInt32, UInt32, UInt32, UInt32)] = [
			(0, 0, 0, 0), (3, 3, 0, 0), (4, 4, 1, 0),
			(5, 5, 1, 0), (6, 4, 1, 1), (7, 5, 1, 1),
			(8, 6, 2, 0), (UInt32.max, 63, 30, 1_073_741_823),
		]
		for (value, symbol, bitCount, bits) in witnesses {
			let encoded = configuration.encode(value)
			#expect(encoded.symbol == symbol)
			#expect(encoded.bitCount == bitCount)
			#expect(encoded.bits == bits)
		}

		let noSplit = HybridUintConfiguration(
			splitExponent: 0, msbInToken: 0, lsbInToken: 0)
		#expect(noSplit.encode(0).symbol == 0)
		#expect(noSplit.encode(0).bitCount == 0)
		#expect(noSplit.encode(1).symbol == 1)
		#expect(noSplit.encode(1).bitCount == 0)
		#expect(noSplit.encode(2).symbol == 2)
		#expect(noSplit.encode(2).bitCount == 1)
		#expect(noSplit.encode(2).bits == 0)
		#expect(noSplit.encode(UInt32.max).symbol == 32)
		#expect(noSplit.encode(UInt32.max).bitCount == 31)
		#expect(noSplit.encode(UInt32.max).bits == UInt32.max >> 1)

		let length = HybridUintConfiguration(splitExponent: 4, msbInToken: 2, lsbInToken: 0)
		#expect(length.encode(15).symbol == 15)
		#expect(length.encode(16).symbol == 16)
		#expect(length.encode(16).bitCount == 2)
		#expect(length.encode(UInt32.max).symbol == 127)
		#expect(length.encode(UInt32.max).bitCount == 29)
	}

	@Test
	func runLengthsAndDistanceContextsMatchPinnedReference() throws {
		let result = ContextMapEntropy.runLengthEncode(
			Array(repeating: 0, count: 100) + Array(repeating: 1, count: 100))
		#expect(result.enabled)
		#expect(result.tokens.contains { $0.isLength && $0.token.context == 0 })
		#expect(
			result.tokens.contains {
				!$0.isLength && $0.token.context == 1 && $0.token.value == 0
			})

		let shortRuns = ContextMapEntropy.runLengthEncode([0, 1, 1, 2, 2, 2])
		#expect(!shortRuns.enabled)
		#expect(shortRuns.tokens.allSatisfy { !$0.isLength })

		for name in [
			"context_entropy_rle_threshold_21",
			"context_entropy_rle_threshold_22",
		] {
			let fixture = try EntropyReferenceFixture.load(name)
			let entries = try fixture.integers(
				fixture.input, "input.context_entropy.entries"
			).map(UInt8.init)
			let native = fixture.expected
			let actual = ContextMapEntropy.runLengthEncode(entries)
			#expect(
				actual.enabled
					== (try fixture.integers(
						native, "entropy.context_entropy.rle_enabled")[0]
						== 1))
			var tokens = [Int64]()
			for item in actual.tokens {
				tokens.append(contentsOf: [
					Int64(item.token.context), Int64(item.token.value),
					item.isLength ? 1 : 0,
				])
			}
			#expect(
				tokens
					== (try fixture.integers(
						native, "entropy.context_entropy.tokens")))
		}
	}

	@Test
	func cumulativeRunCostMatchesLargeNativeWitness() throws {
		let fixture = try EntropyReferenceFixture.load(
			"context_entropy_rle_cumulative_rounding")
		let pattern = try fixture.integers(
			fixture.input, "input.context_entropy.rle_pattern"
		).map(Int.init)
		var entries = [UInt8]()
		entries.reserveCapacity(1_260_004)
		for _ in 0..<pattern[0] {
			entries.append(contentsOf: repeatElement(0, count: pattern[1]))
			entries.append(contentsOf: (1...pattern[2]).map(UInt8.init))
		}
		entries.append(contentsOf: repeatElement(0, count: pattern[3]))
		let actual = ContextMapEntropy.runLengthEncode(entries)
		let expected = fixture.expected
		#expect(actual.enabled)
		#expect(
			actual.tokens.count
				== (try fixture.integers(
					expected, "entropy.context_entropy.token_count")[0]))
		var hash: UInt32 = 2_166_136_261
		for token in actual.tokens {
			for value in [
				UInt32(token.token.context), token.token.value,
				token.isLength ? 1 : 0,
			] {
				hash = (hash ^ value) &* 16_777_619
			}
		}
		#expect(
			Int64(hash)
				== (try fixture.integers(
					expected, "entropy.context_entropy.token_hash")[0]))
	}

	@Test
	func bestClusteringMatchesPinnedReference() throws {
		let fixture = try EntropyReferenceFixture.load("context_entropy_rle")
		let entries = try fixture.integers(
			fixture.input, "input.context_entropy.entries"
		).map(UInt8.init)
		let prepared = ContextMapEntropy.prepare(entries)
		#expect(
			prepared.contextMap.map(Int64.init)
				== (try fixture.integers(
					fixture.expected, "entropy.context_entropy.context_map")))
		#expect(
			prepared.histograms.count
				== Int(
					try fixture.integers(
						fixture.expected,
						"entropy.context_entropy.histogram_count")[0]))
		#expect(prepared.histograms.count == 1)
		#expect(prepared.histograms[0].totalCount == prepared.runLength.tokens.count)
		let prefixFixture = try EntropyReferenceFixture.load(
			"context_entropy_rle_prefix_two_hist")
		let prefixEntries = try prefixFixture.integers(
			prefixFixture.input, "input.context_entropy.entries"
		).map(UInt8.init)
		let prefixCandidate = ContextMapEntropy.prepare(prefixEntries)
		var prefixTokens = [Int64]()
		for item in prefixCandidate.runLength.tokens {
			prefixTokens.append(contentsOf: [
				Int64(item.token.context), Int64(item.token.value),
				item.isLength ? 1 : 0,
			])
		}
		#expect(
			prefixTokens
				== (try prefixFixture.integers(
					prefixFixture.expected, "entropy.context_entropy.tokens")))
		#expect(prefixCandidate.runLength.enabled)
		#expect(prefixCandidate.histograms.count == 2)
		#expect(prefixCandidate.contextMap.map(Int64.init) == [0, 1])
		let prefixLengths = prefixCandidate.histograms.map { histogram in
			(histogram.counts.lastIndex(where: { $0 != 0 }) ?? -1) + 1
		}
		#expect(
			prefixLengths.map(Int64.init)
				== (try prefixFixture.integers(
					prefixFixture.expected,
					"entropy.context_entropy.histogram_lengths")))
		#expect(
			prefixCandidate.histograms.enumerated().flatMap { index, histogram in
				histogram.counts.prefix(prefixLengths[index]).map(Int64.init)
			}
				== (try prefixFixture.integers(
					prefixFixture.expected,
					"entropy.context_entropy.histogram_counts")))
		let prefixNativeCost = try prefixFixture.integers(
			prefixFixture.expected, "entropy.context_entropy.cost")[0]
		#expect(prefixCandidate.estimatedCost == Int(prefixNativeCost))
		#expect(prefixCandidate.usesPrefixCode)
		var prefixWriter = BitWriter()
		ContextMapEntropy.write(prefixCandidate, to: &prefixWriter)
		#expect(
			prefixWriter.bitsWritten
				== (try prefixFixture.integers(
					prefixFixture.expected, "entropy.context_entropy.bit_count")[
						0]))
		#expect(
			prefixWriter.bytes.map(Int64.init)
				== (try prefixFixture.integers(
					prefixFixture.expected, "entropy.context_entropy.bytes")))
		let mergeFixture = try EntropyReferenceFixture.load("clusters_best_pair_merge")
		let mergeLengths = try mergeFixture.integers(
			mergeFixture.input, "input.clusters.lengths")
		let mergeCounts = try mergeFixture.integers(
			mergeFixture.input, "input.clusters.counts")
		var mergeOffset = 0
		let mergeSources = mergeLengths.map { length -> Histogram in
			var histogram = Histogram()
			for symbol in 0..<Int(length) {
				for _ in 0..<Int(mergeCounts[mergeOffset + symbol]) {
					histogram.add(UInt32(symbol))
				}
			}
			mergeOffset += Int(length)
			return histogram
		}
		let merged = ContextMapEntropy.cluster(mergeSources)
		#expect(
			merged.contextMap.map(Int64.init)
				== (try mergeFixture.integers(
					mergeFixture.expected, "entropy.clusters.map")))
		#expect(merged.histograms.count == 1)

		let survivorFixture = try EntropyReferenceFixture.load("clusters_best_survive")
		let lengths = try survivorFixture.integers(
			survivorFixture.input, "input.clusters.lengths")
		let counts = try survivorFixture.integers(
			survivorFixture.input, "input.clusters.counts")
		var offset = 0
		let sourceHistograms = lengths.map { length -> Histogram in
			var histogram = Histogram()
			for symbol in 0..<Int(length) {
				for _ in 0..<Int(counts[offset + symbol]) {
					histogram.add(UInt32(symbol))
				}
			}
			offset += Int(length)
			return histogram
		}
		let survivors = ContextMapEntropy.cluster(sourceHistograms)
		#expect(
			survivors.contextMap.map(Int64.init)
				== (try survivorFixture.integers(
					survivorFixture.expected, "entropy.clusters.map")))
		#expect(survivors.histograms.count == 2)
		let survivorLengths = try survivorFixture.integers(
			survivorFixture.expected, "entropy.clusters.alphabet_lengths")
		let survivorCounts = survivors.histograms.enumerated().flatMap { index, histogram in
			histogram.counts.prefix(Int(survivorLengths[index])).map(Int64.init)
		}
		#expect(
			survivorCounts
				== (try survivorFixture.integers(
					survivorFixture.expected,
					"entropy.clusters.histogram_counts")))
	}

	@Test
	func candidateCostsMatchPinnedReference() throws {
		let prepared = ContextMapEntropy.prepare([0, 1, 0, 1])
		#expect(
			prepared.uintConfigurations.allSatisfy {
				$0
					== HybridUintConfiguration(
						splitExponent: 2, msbInToken: 0, lsbInToken: 1)
			})
		#expect(prepared.contextMap.count == (prepared.runLength.enabled ? 2 : 1))
		#expect(prepared.usesPrefixCode)
		#expect(prepared.logAlphabetSize == PrefixCodeWriter.prefixMaxBits)
		var writer = BitWriter()
		ContextMapEntropy.write(prepared, to: &writer)
		#expect(prepared.estimatedCost > 0)
		#expect(writer.bitsWritten > 0)

		let rlePrepared = ContextMapEntropy.prepare(
			Array(repeating: 0, count: 100) + Array(repeating: 1, count: 100))
		var rleWriter = BitWriter()
		ContextMapEntropy.write(rlePrepared, to: &rleWriter)
		#expect(rlePrepared.runLength.enabled)
		#expect(rlePrepared.estimatedCost != rleWriter.bitsWritten)
		#expect(rlePrepared.runLength.tokens.filter(\.isLength).count == 2)
		#expect(rlePrepared.contextMap.count == 2)
		#expect(
			rlePrepared.histograms.contains {
				$0.counts.dropFirst(224).contains { $0 > 0 }
			}
		)

		let fixture = try EntropyReferenceFixture.load("context_raw_rle")
		let nativeRawEntries = try fixture.integers(
			fixture.input, "input.context_map.entries"
		).map(UInt8.init)
		let nativeMTFEntries = try fixture.integers(
			fixture.input, "input.context_map.mtf_entries"
		).map(UInt8.init)
		let nativeRaw = ContextMapEntropy.prepare(nativeRawEntries)
		let nativeMTF = ContextMapEntropy.prepare(nativeMTFEntries)
		#expect(
			nativeRaw.estimatedCost
				== Int(
					try fixture.integers(
						fixture.expected, "entropy.context_map.raw_cost")[0]
				))
		#expect(
			nativeMTF.estimatedCost
				== Int(
					try fixture.integers(
						fixture.expected, "entropy.context_map.mtf_cost")[0]
				))

		let state = try EntropyReferenceFixture.load("context_entropy_rle")
		let entries = try state.integers(
			state.input, "input.context_entropy.entries"
		).map(UInt8.init)
		let native = state.expected
		let candidate = ContextMapEntropy.prepare(entries)
		let nativeTokens = try state.integers(native, "entropy.context_entropy.tokens")
		let swiftTokens = candidate.runLength.tokens.flatMap { token -> [Int64] in
			[
				Int64(token.token.context), Int64(token.token.value),
				Int64(token.isLength ? 1 : 0),
			]
		}
		#expect(swiftTokens == nativeTokens)
		#expect(candidate.runLength.enabled)
		#expect(
			candidate.contextMap.map(Int64.init)
				== (try state.integers(
					native, "entropy.context_entropy.context_map")))
		#expect(
			candidate.estimatedCost
				== Int(
					try state.integers(native, "entropy.context_entropy.cost")[
						0]))
		#expect(
			candidate.uintConfigurations.flatMap {
				[
					Int64($0.splitExponent), Int64($0.msbInToken),
					Int64($0.lsbInToken),
				]
			}
				== (try state.integers(
					native, "entropy.context_entropy.uint_configs")))
		#expect(
			try state.integers(native, "entropy.context_entropy.length_uint_config")
				== [0, 0, 0])
		#expect(
			try state.integers(native, "entropy.context_entropy.min_length_symbol") == [
				224
			])
		#expect(try state.integers(native, "entropy.context_entropy.min_length") == [3])
		#expect(
			try state.integers(native, "entropy.context_entropy.distance_context") == [
				1
			])
		#expect(
			candidate.histograms.count
				== Int(
					try state.integers(
						native, "entropy.context_entropy.histogram_count")[
							0]))
		let lengths = try state.integers(
			native, "entropy.context_entropy.histogram_lengths")
		let histogramCounts = candidate.histograms.flatMap { histogram in
			let alphabetSize = (histogram.counts.lastIndex(where: { $0 > 0 }) ?? 0) + 1
			return histogram.counts.prefix(alphabetSize).map(Int64.init)
		}
		#expect(
			histogramCounts
				== (try state.integers(
					native, "entropy.context_entropy.histogram_counts")))
		let tables: [Int64] = candidate.prefixCodes.enumerated().flatMap { index, code in
			(0..<Int(lengths[index])).flatMap { symbol in
				[Int64(code.depths[symbol]), Int64(0)]
			}
		}
		#expect(tables == (try state.integers(native, "entropy.context_entropy.tables")))
		#expect(
			try state.integers(native, "entropy.context_entropy.use_prefix_code") == [1]
		)
		#expect(
			try state.integers(native, "entropy.context_entropy.log_alpha_size") == [15]
		)
		var serialized = BitWriter()
		ContextMapEntropy.write(candidate, to: &serialized)
		#expect(
			serialized.bitsWritten
				== Int(
					try state.integers(
						native, "entropy.context_entropy.bit_count")[0]))
		#expect(
			serialized.bytes.map(Int64.init)
				== (try state.integers(native, "entropy.context_entropy.bytes")))

		for (name, expectedPrefix, expectedLogAlpha) in [
			("context_entropy_prefix_99", 1, 15),
			("context_entropy_ans_100", 0, 7),
		] {
			let boundary = try EntropyReferenceFixture.load(name)
			let boundaryEntries = try boundary.integers(
				boundary.input, "input.context_entropy.entries"
			).map(UInt8.init)
			let boundaryCandidate = ContextMapEntropy.prepare(boundaryEntries)
			let boundaryTokens = boundaryCandidate.runLength.tokens.flatMap {
				[
					Int64($0.token.context), Int64($0.token.value),
					Int64($0.isLength ? 1 : 0),
				]
			}
			#expect(
				boundaryTokens
					== (try boundary.integers(
						boundary.expected, "entropy.context_entropy.tokens"))
			)
			#expect(boundaryCandidate.usesPrefixCode == (expectedPrefix == 1))
			#expect(
				boundaryCandidate.logAlphabetSize == expectedLogAlpha)
			#expect(
				boundaryCandidate.estimatedCost
					== Int(
						try boundary.integers(
							boundary.expected,
							"entropy.context_entropy.cost")[0]))
			var boundaryWriter = BitWriter()
			ContextMapEntropy.write(boundaryCandidate, to: &boundaryWriter)
			let expectedBits = try boundary.integers(
				boundary.expected, "entropy.context_entropy.bit_count")[0]
			let expectedBytes = try boundary.integers(
				boundary.expected, "entropy.context_entropy.bytes")
			#expect(boundaryWriter.bitsWritten == Int(expectedBits))
			#expect(boundaryWriter.bytes.map(Int64.init) == expectedBytes)
		}
	}

	@Test
	func ansContextCandidateMatchesPinnedProductionState() throws {
		let fixture = try EntropyReferenceFixture.load("context_entropy_ans_100")
		let native = fixture.expected
		let entries = try fixture.integers(
			fixture.input, "input.context_entropy.entries"
		).map(UInt8.init)
		let candidate = ContextMapEntropy.prepare(entries)
		let nativeTokens = try fixture.integers(native, "entropy.context_entropy.tokens")
		var swiftTokens = [Int64]()
		for item in candidate.runLength.tokens {
			swiftTokens.append(contentsOf: [
				Int64(item.token.context), Int64(item.token.value),
				item.isLength ? 1 : 0,
			])
		}
		#expect(swiftTokens == nativeTokens)
		#expect(
			candidate.runLength.enabled
				== (try fixture.integers(
					native, "entropy.context_entropy.rle_enabled")[0] == 1))
		#expect(
			candidate.contextMap.map(Int64.init)
				== (try fixture.integers(
					native, "entropy.context_entropy.context_map")))
		#expect(
			candidate.uintConfigurations.flatMap {
				[
					Int64($0.splitExponent), Int64($0.msbInToken),
					Int64($0.lsbInToken),
				]
			}
				== (try fixture.integers(
					native, "entropy.context_entropy.uint_configs")))
		#expect(
			candidate.usesPrefixCode
				== (try fixture.integers(
					native, "entropy.context_entropy.use_prefix_code")[0] == 1))
		#expect(
			candidate.logAlphabetSize
				== Int(
					try fixture.integers(
						native, "entropy.context_entropy.log_alpha_size")[0]
				))
		#expect(
			candidate.histograms.count
				== (try fixture.integers(
					native, "entropy.context_entropy.histogram_count")[0]))
		let lengths = candidate.histograms.map { histogram in
			(histogram.counts.lastIndex(where: { $0 > 0 }) ?? -1) + 1
		}
		#expect(
			lengths.map(Int64.init)
				== (try fixture.integers(
					native, "entropy.context_entropy.histogram_lengths")))
		#expect(
			candidate.histograms.enumerated().flatMap { index, histogram in
				histogram.counts.prefix(lengths[index]).map(Int64.init)
			}
				== (try fixture.integers(
					native, "entropy.context_entropy.histogram_counts")))
		let swiftTables = candidate.ansHistograms.enumerated().flatMap {
			index, histogram in
			let table = ANSInfoTable.build(
				distribution: histogram.normalizedCounts,
				alphabetSize: lengths[index],
				logAlphaSize: candidate.logAlphabetSize)
			return (0..<lengths[index]).flatMap { symbol in
				[
					Int64(
						candidate.usesPrefixCode
							? candidate.prefixCodes[index].depths[
								symbol] : 0),
					Int64(table[symbol].freq),
				]
			}
		}
		#expect(
			swiftTables
				== (try fixture.integers(native, "entropy.context_entropy.tables")))
		#expect(
			candidate.estimatedCost
				== Int(
					try fixture.integers(
						native, "entropy.context_entropy.cost")[0]))
		var writer = BitWriter()
		ContextMapEntropy.write(candidate, to: &writer)
		#expect(
			writer.bitsWritten
				== (try fixture.integers(
					native, "entropy.context_entropy.bit_count")[0]))
		#expect(
			writer.bytes.map(Int64.init)
				== (try fixture.integers(
					native, "entropy.context_entropy.bytes")))
	}

	@Test
	func absoluteEntropyRuleMatchesSkewedNativeWitness() throws {
		let fixture = try EntropyReferenceFixture.load(
			"context_entropy_singleton_contexts")
		var majority = Histogram()
		for _ in 0..<102 { majority.add(0) }
		majority.computeBitCost()
		var minority = Histogram()
		minority.add(1)
		minority.computeBitCost()
		let expected =
			try fixture.integers(
				fixture.expected, "entropy.context_entropy.use_prefix_code")[0] == 1
		#expect(expected)
		#expect(
			ContextMapEntropy.shouldUsePrefixCode(
				tokenCount: 103, histograms: [majority, minority]) == expected)
	}

	@Test
	func representationAndSerializationMatchPinnedReference() throws {
		let prepared = ContextMapEncoding.prepare([0, 1], numHistograms: 2)
		#expect(prepared.representation == .simple(entryBits: 1))
		#expect(prepared.raw != nil && prepared.moveToFront != nil)
		#expect(prepared.entries == [0, 1])
		var writer = BitWriter()
		ContextMapEncoding.write(prepared, to: &writer)
		#expect(writer.bitsWritten == 5)

		for name in [
			"context_single_histogram",
			"context_simple_two_histograms",
			"context_full_256",
			"context_simple_profitability", "context_simple_tie_candidate",
			"context_tie_raw_mtf", "context_mtf_ans", "context_raw_ans",
			"context_prefix_99", "context_ans_100", "context_raw_rle",
		] {
			let fixture = try EntropyReferenceFixture.load(name)
			let entries = try fixture.integers(
				fixture.input, "input.context_map.entries"
			).map(UInt8.init)
			let numHistograms = Int(
				try fixture.integers(
					fixture.input, "input.context_map.num_histograms")[0])
			let candidate = ContextMapEncoding.prepare(
				entries, numHistograms: numHistograms)
			let expected = fixture.expected
			#expect(candidate.entries == entries)
			let semantic = try SwiftEntropySemanticEncoding.contextMap(
				entries: entries, numHistograms: numHistograms)
			#expect(
				semantic.fields["entropy.context_map.bit_count"]
					== expected.fields["entropy.context_map.bit_count"])
			#expect(
				semantic.fields["entropy.context_map.bytes"]
					== expected.fields["entropy.context_map.bytes"])
			#expect(
				semantic.fields["entropy.context_map.use_mtf"]
					== expected.fields["entropy.context_map.use_mtf"])
			#expect(
				semantic.fields["entropy.context_map.simple"]
					== expected.fields["entropy.context_map.simple"])
			for field in [
				"entry_bits", "token_count", "token_count_status",
				"raw_token_count", "mtf_token_count",
			] where expected.fields["entropy.context_map.\(field)"] != nil {
				#expect(
					semantic.fields["entropy.context_map.\(field)"]
						== expected.fields["entropy.context_map.\(field)"],
					"\(name): \(field)")
			}
			if expected.fields["entropy.context_map.use_prefix_code"] != .integers([-1])
			{
				#expect(
					semantic.fields["entropy.context_map.use_prefix_code"]
						== expected.fields[
							"entropy.context_map.use_prefix_code"],
					"\(name): use_prefix_code")
			}
			for field in ["raw_cost", "mtf_cost", "simple_cost", "mtf_entries"] {
				if expected.fields["entropy.context_map.\(field)"] != nil {
					#expect(
						semantic.fields["entropy.context_map.\(field)"]
							== expected.fields[
								"entropy.context_map.\(field)"],
						"\(name): \(field)")
				}
			}
			if expected.fields["entropy.context_map.mtf_entries"] != nil {
				#expect(
					candidate.transformedEntries.map(Int64.init)
						== (try fixture.integers(
							expected, "entropy.context_map.mtf_entries"))
				)
			}
			if numHistograms == 1 {
				#expect(candidate.raw == nil && candidate.moveToFront == nil)
			} else {
				#expect(candidate.raw != nil && candidate.moveToFront != nil)
			}
			if expected.fields["entropy.context_map.raw_cost"] != nil,
				let raw = candidate.raw, let moveToFront = candidate.moveToFront
			{
				#expect(
					raw.estimatedCost
						== Int(
							try fixture.integers(
								expected,
								"entropy.context_map.raw_cost")[0]))
				#expect(
					moveToFront.estimatedCost
						== Int(
							try fixture.integers(
								expected,
								"entropy.context_map.mtf_cost")[0]))
			}
			let expectedSimple =
				try fixture.integers(
					expected, "entropy.context_map.simple")[0] == 1
			let expectedMTF =
				try fixture.integers(
					expected, "entropy.context_map.use_mtf")[0] == 1
			switch candidate.representation {
			case .simple(let bits):
				#expect(expectedSimple)
				#expect(
					bits
						== Int(
							try fixture.integers(
								expected,
								"entropy.context_map.entry_bits")[0]
						))
			case .raw:
				#expect(!expectedSimple && !expectedMTF)
			case .moveToFront:
				#expect(!expectedSimple && expectedMTF)
			}
			var serialized = BitWriter()
			ContextMapEncoding.write(candidate, to: &serialized)
			#expect(
				serialized.bitsWritten
					== Int(
						try fixture.integers(
							expected, "entropy.context_map.bit_count")[
								0]))
			#expect(
				serialized.bytes.map(Int64.init)
					== (try fixture.integers(
						expected, "entropy.context_map.bytes")))
		}
	}

	@Test
	func productionUsesPreparedContextMaps() throws {
		let prepared = ContextMapEncoding.prepare([0, 1], numHistograms: 2)
		var direct = BitWriter()
		ContextMapEncoding.write(prepared, to: &direct)
		var production = BitWriter()
		EntropyCodeWriter.writeContextMapEntries(
			[0, 1], numHistograms: 2, writer: &production)
		#expect(production.bitsWritten == direct.bitsWritten)
		#expect(production.bytes == direct.bytes)

		for name in [
			"context_mtf_ans", "context_prefix_99", "context_ans_100",
			"context_raw_rle", "context_full_256",
		] {
			let fixture = try EntropyReferenceFixture.load(name)
			let entries = try fixture.integers(
				fixture.input, "input.context_map.entries"
			).map(UInt8.init)
			let numHistograms = Int(
				try fixture.integers(
					fixture.input, "input.context_map.num_histograms")[0])
			let prepared = ContextMapEncoding.prepare(
				entries, numHistograms: numHistograms)
			var expected = BitWriter()
			ContextMapEncoding.write(prepared, to: &expected)
			var actual = BitWriter()
			EntropyCodeWriter.writeContextMapEntries(
				entries, numHistograms: numHistograms, writer: &actual)
			#expect(actual.bitsWritten == expected.bitsWritten)
			#expect(actual.bytes == expected.bytes)
		}

		for code in [EntropyCode.staticDC, EntropyCode.staticAC] {
			let entries =
				code.originalContextMap.map { original in
					original.map { code.contextMap[Int($0)] }
				} ?? code.contextMap
			let numHistograms =
				code.ansHistograms?.count
				?? code.ansInfoTables?.count ?? code.prefixCodeCount
			var expected = BitWriter()
			ContextMapEncoding.write(
				ContextMapEncoding.prepare(entries, numHistograms: numHistograms),
				to: &expected)
			var actual = BitWriter()
			EntropyCodeWriter.writeContextMap(code, writer: &actual)
			#expect(actual.bitsWritten == expected.bitsWritten)
			#expect(actual.bytes == expected.bytes)
		}

		let composed = EntropyCode(
			contextMap: [0, 1],
			prefixCodes: [
				EntropyCode.staticDC.prefixCodes[0],
				EntropyCode.staticDC.prefixCodes[0],
			],
			originalContextMap: [1, 0, 1])
		var composedExpected = BitWriter()
		ContextMapEncoding.write(
			ContextMapEncoding.prepare([1, 0, 1], numHistograms: 2),
			to: &composedExpected)
		var composedActual = BitWriter()
		EntropyCodeWriter.writeContextMap(composed, writer: &composedActual)
		#expect(composedActual.bitsWritten == composedExpected.bitsWritten)
		#expect(composedActual.bytes == composedExpected.bytes)
	}

	@Test
	func inventoryReferencesHaveContextMapProofs() throws {
		let inventory = try DecisionInventoryTests.committed()
		#expect(inventory.parseViolations.isEmpty)
		let translated = Set(
			["EW-01", "EW-02", "EW-03", "EW-04", "EW-06", "EW-07", "EW-08", "EW-09"])
		for row in inventory.rows where translated.contains(row.id) {
			let references =
				row.fixture == "-" ? [] : row.fixture.components(separatedBy: ",")
			#expect(!references.isEmpty, "\(row.id) needs bounded context-map evidence")
			let contextReferences = references.filter {
				$0.hasSuffix("#context_map") || $0.hasSuffix("#context_entropy")
			}
			#expect(
				!contextReferences.isEmpty,
				"\(row.id) needs context-map proof references")
			for text in contextReferences {
				guard let reference = DecisionInventory.FixtureReference(text)
				else {
					Issue.record(
						"malformed context-map proof reference: \(text)")
					continue
				}
				#expect(
					ContextMapProofCase.proves(reference, decision: row.id),
					"\(text) does not prove \(row.id)")
			}
		}
	}
}
