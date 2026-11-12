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

	private func prefixCode(_ depths: [UInt8]) -> EntropyCode {
		EntropyCode(
			contextMap: [0],
			prefixCodes: [
				PrefixCode(depths: depths, bits: [UInt16](repeating: 0, count: 64))
			])
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
		let malformedANS = EntropyCode(
			contextMap: [0], prefixCodes: [], ansInfoTables: [[ANSEncSymbolInfo()]])
		#expect(throws: ACEntropyCaptureError.invalidANSTable(0)) {
			try dump.recordACEntropyCode(malformedANS)
		}
		let malformedPrefix = EntropyCode(
			contextMap: [0], prefixCodes: [PrefixCode(depths: [0], bits: [0])])
		#expect(throws: ACEntropyCaptureError.invalidPrefixTable(0)) {
			try dump.recordACEntropyCode(malformedPrefix)
		}
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
