import Testing

@testable import JXLEncoder

@Suite("AC entropy semantic records")
struct ACEntropySemanticDumpTests {
	private func ansCode(_ firstFrequency: Int = 1024) -> EntropyCode {
		func table(_ first: Int, _ second: Int) -> [ANSEncSymbolInfo] {
			[first, second].map { frequency in
				var info = ANSEncSymbolInfo()
				info.freq = frequency
				info.reverseMap = [UInt16](repeating: 0, count: frequency)
				return info
			}
		}
		return EntropyCode(
			contextMap: [1, 0],
			prefixCodes: [],
			ansInfoTables: [
				table(firstFrequency, 4096 - firstFrequency),
				table(4096 - firstFrequency, firstFrequency),
			])
	}

	private func ansCode(
		_tables tables: [[Int]], reverseMapLengths: [[Int]]? = nil,
		contextMap: [UInt8]? = nil
	) -> EntropyCode {
		let infoTables = tables.enumerated().map { tableIndex, frequencies in
			frequencies.enumerated().map { symbol, frequency in
				var info = ANSEncSymbolInfo()
				info.freq = frequency
				let reverseCount =
					reverseMapLengths?[tableIndex][symbol] ?? frequency
				info.reverseMap = [UInt16](repeating: 0, count: reverseCount)
				return info
			}
		}
		return EntropyCode(
			contextMap: contextMap ?? Array(repeating: 0, count: tables.count),
			prefixCodes: [], ansInfoTables: infoTables)
	}

	private func prefixCode(_ depths: [UInt8]) -> EntropyCode {
		EntropyCode(
			contextMap: [0],
			prefixCodes: [
				PrefixCode(depths: depths, bits: [UInt16](repeating: 0, count: 64))
			])
	}

	private func integerValues(_ field: String, in dump: SemanticDump) -> [Int64]? {
		guard case .integers(let values)? = dump.fields[field] else { return nil }
		return values
	}

	@Test
	func acEntropyMatchesActualReferenceCodeShapes() throws {
		let ans = try SemanticDump(fixture: "edge")
		#expect(integerValues("ac_entropy.kind", in: ans) == [1])
		#expect(integerValues("ac_entropy_alphabet.ans_log_alpha_size", in: ans) == [7])
		let lengths = try #require(
			integerValues("ac_entropy.ans.alphabet_lengths", in: ans))
		let frequencies = try #require(integerValues("ac_entropy.ans.frequencies", in: ans))
		var cursor = 0
		for length in lengths {
			let end = cursor + Int(length)
			#expect(frequencies[cursor..<end].reduce(0, +) == 4096)
			cursor = end
		}
		#expect(cursor == frequencies.count)

		let prefix = try SemanticDump(fixture: "ac_entropy_static_prefix")
		#expect(integerValues("ac_entropy.kind", in: prefix) == [0])
		let depths = try #require(
			integerValues("ac_entropy.prefix.depths", in: prefix))
		#expect(depths.contains { $0 > 8 })
		var staticCode = SemanticDump()
		try staticCode.recordACEntropyCode(.staticAC)
		#expect(
			prefix.restricted(to: ["ac_entropy", "ac_entropy_alphabet"])
				.differences(from: staticCode).isEmpty)

		let singleton = try SemanticDump(fixture: "ac_entropy_flat_singleton")
		#expect(integerValues("ac_entropy.kind", in: singleton) == [0])
		#expect(integerValues("ac_entropy.prefix.alphabet_lengths", in: singleton) == [1])
		#expect(integerValues("ac_entropy.prefix.singleton_symbols", in: singleton) == [0])
		#expect(integerValues("ac_entropy.prefix.depths", in: singleton) == [0])
	}

	@Test
	func acEntropyTablesMatchReference() throws {
		var dump = SemanticDump()
		try dump.recordACEntropyCode(ansCode())
		#expect(dump.fields["ac_entropy.kind"] == .integers([1]))
		#expect(dump.fields["ac_entropy.table_count"] == .integers([2]))
		#expect(dump.fields["ac_entropy.ans.alphabet_lengths"] == .integers([2, 2]))
		#expect(
			dump.fields["ac_entropy.ans.frequencies"]
				== .integers([1024, 3072, 3072, 1024]))
		var prefixDump = SemanticDump()
		try prefixDump.recordACEntropyCode(
			prefixCode([1, 1] + [UInt8](repeating: 0, count: 62)))
		#expect(prefixDump.fields["ac_entropy.kind"] == .integers([0]))
		#expect(
			prefixDump.fields["ac_entropy_alphabet.ans_log_alpha_size"] == .integers([])
		)
		#expect(prefixDump.fields["ac_entropy.prefix.singleton_symbols"] == .integers([-1]))
		#expect(prefixDump.fields["ac_entropy.prefix.depths"] == .integers([1, 1]))
	}

	@Test
	func acEntropyPreservesTransmittedTableOrder() throws {
		var dump = SemanticDump()
		try dump.recordACEntropyCode(ansCode())
		#expect(
			dump.fields["ac_entropy.ans.frequencies"]
				== .integers([1024, 3072, 3072, 1024]))
		#expect(dump.fields["ac_entropy.uint_config"] == .integers([4, 2, 0, 4, 2, 0]))
	}

	@Test
	func acEntropyCanonicalizesPrefixSingletons() throws {
		var depths = [UInt8](repeating: 0, count: 64)
		depths[7] = 1
		var dump = SemanticDump()
		try dump.recordACEntropyCode(prefixCode(depths))
		#expect(dump.fields["ac_entropy.prefix.alphabet_lengths"] == .integers([8]))
		#expect(dump.fields["ac_entropy.prefix.singleton_symbols"] == .integers([7]))
		#expect(
			dump.fields["ac_entropy.prefix.depths"]
				== .integers([0, 0, 0, 0, 0, 0, 0, 0]))
		var allZeroDump = SemanticDump()
		try allZeroDump.recordACEntropyCode(
			prefixCode([UInt8](repeating: 0, count: 64)))
		#expect(allZeroDump.fields["ac_entropy.prefix.alphabet_lengths"] == .integers([1]))
		#expect(allZeroDump.fields["ac_entropy.prefix.singleton_symbols"] == .integers([0]))
		#expect(allZeroDump.fields["ac_entropy.prefix.depths"] == .integers([0]))
	}

	@Test
	func acEntropyRejectsMalformedCapturesAtomically() throws {
		var dump = SemanticDump()
		dump.record("sentinel.value", .integers([17]))
		let original = dump
		let invalid = EntropyCode(
			contextMap: [1],
			prefixCodes: [
				PrefixCode(
					depths: [UInt8](repeating: 0, count: 64),
					bits: [UInt16](repeating: 0, count: 64))
			])
		#expect(throws: ACEntropyCaptureError.invalidContextMap) {
			try dump.recordACEntropyCode(invalid)
		}
		#expect(dump == original)
		#expect(throws: ACEntropyCaptureError.invalidTableCount) {
			try dump.recordACEntropyCode(EntropyCode(contextMap: [], prefixCodes: []))
		}
		#expect(dump == original)
		let invalidOriginalMap = EntropyCode(
			contextMap: [0],
			prefixCodes: [
				PrefixCode(
					depths: [UInt8](repeating: 0, count: 64),
					bits: [UInt16](repeating: 0, count: 64))
			],
			originalContextMap: [1])
		#expect(throws: ACEntropyCaptureError.invalidContextMap) {
			try dump.recordACEntropyCode(invalidOriginalMap)
		}
		#expect(dump == original)
		let invalidFrequency = ansCode(_tables: [[4097]], reverseMapLengths: [[4097]])
		#expect(throws: ACEntropyCaptureError.invalidANSTable(0)) {
			try dump.recordACEntropyCode(invalidFrequency)
		}
		#expect(dump == original)
		let invalidReverseMap = ansCode(
			_tables: [[2048, 2048]], reverseMapLengths: [[2048, 2047]])
		#expect(throws: ACEntropyCaptureError.invalidANSTable(0)) {
			try dump.recordACEntropyCode(invalidReverseMap)
		}
		#expect(dump == original)
		let laterInvalidTable = ansCode(
			_tables: [[2048, 2048], [4096]], reverseMapLengths: [[2048, 2048], [4095]])
		#expect(throws: ACEntropyCaptureError.invalidANSTable(1)) {
			try dump.recordACEntropyCode(laterInvalidTable)
		}
		#expect(dump == original)
		let malformedPrefix = EntropyCode(
			contextMap: [0], prefixCodes: [PrefixCode(depths: [0], bits: [0])])
		#expect(throws: ACEntropyCaptureError.invalidPrefixTable(0)) {
			try dump.recordACEntropyCode(malformedPrefix)
		}
		#expect(dump == original)
		var invalidDepths = [UInt8](repeating: 0, count: 64)
		invalidDepths[3] = 16
		let invalidDepth = prefixCode(invalidDepths)
		#expect(throws: ACEntropyCaptureError.invalidPrefixTable(0)) {
			try dump.recordACEntropyCode(invalidDepth)
		}
		#expect(dump == original)
		dump.record("ac_entropy.kind", .integers([0]))
		let collisionSnapshot = dump
		#expect(throws: ACEntropyCaptureError.duplicateField("ac_entropy.kind")) {
			try dump.recordACEntropyCode(ansCode())
		}
		#expect(dump == collisionSnapshot)
	}

	@Test
	func acEntropyMutationIsReportedByItsExactField() throws {
		var baseline = SemanticDump()
		var changed = SemanticDump()
		try baseline.recordACEntropyCode(ansCode())
		try changed.recordACEntropyCode(ansCode(2048))
		#expect(
			changed.differences(from: baseline).map(\.field) == [
				"ac_entropy.ans.frequencies"
			])
	}

	@Test
	func alphabetDivergenceDoesNotMaskEntropyMutation() throws {
		let baseline = try SemanticDump(
			parsing: """
				jxl-semantic-dump 1
				ac_entropy.ans.frequencies i 2 1024 3072
				ac_entropy_alphabet.ans_log_alpha_size i 1 6
				""")
		let changed = try SemanticDump(
			parsing: """
				jxl-semantic-dump 1
				ac_entropy.ans.frequencies i 2 2048 2048
				ac_entropy_alphabet.ans_log_alpha_size i 1 7
				""")
		#expect(
			changed.differences(from: baseline).map(\.field) == [
				"ac_entropy.ans.frequencies",
				"ac_entropy_alphabet.ans_log_alpha_size",
			])
	}
}
