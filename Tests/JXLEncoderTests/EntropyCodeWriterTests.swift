import Testing

@testable import JXLEncoder

/// The general histogram builder signals forced prefix codes the way libjxl
/// does.
@Suite("EntropyCodeWriter")
struct EntropyCodeWriterTests {
	@Test(
		"forced prefix codes write LZ77 min_symbol 512 and use_prefix_code",
		arguments: [LZ77.Method.rle, .lz77, .optimal])
	func forcedPrefixCodesUseMinSymbol512(method: LZ77.Method) {
		let values =
			Array(1...40) + Array(1...40) + Array(1...40)
			+ [UInt32](repeating: 40, count: 60)
		let prepared = EntropyCodeWriter.prepare(
			values.map { Token(context: 0, value: $0) }, contextCount: 1,
			parameters: HistogramParameters(lz77Method: method, forcesPrefixCodes: true)
		)
		#expect(prepared.code.lz77 == LZ77.Parameters(minSymbol: 512, distanceContext: 1))
		#expect(prepared.code.ansInfoTables == nil)
		var writer = BitWriter()
		EntropyCodeWriter.write(prepared, writer: &writer)
		#expect(prepared.code.ansHistograms == nil)
		#expect(writer.bytes[0] == 0b000_00_01_1)
	}

	@Test(
		"kBest prices histograms past 256 symbols at FLT_MAX: length contexts merge (inf saving), the distance context stays apart",
		arguments: [LZ77.Method.rle, .lz77, .optimal])
	func forcedPrefixLengthContextsMerge(method: LZ77.Method) {
		let prepared = EntropyCodeWriter.prepare(
			LZ77Tests.mixed, contextCount: 3,
			parameters: HistogramParameters(lz77Method: method, forcesPrefixCodes: true)
		)
		#expect(
			Set(prepared.tokens.filter { $0.isLength }.map { $0.token.context }) == [
				0, 1, 2,
			])
		#expect(prepared.code.contextMap == [0, 0, 0, 1], "\(prepared.code.contextMap)")
	}

	@Test("the LZ77 header picks the U32 selector for each min_symbol")
	func lz77HeaderMinSymbolSelectors() {
		func header(_ minSymbol: UInt32) -> (UInt64, Int) {
			var writer = BitWriter()
			EntropyCodeWriter.writeLZ77Header(
				LZ77.Parameters(minSymbol: minSymbol, distanceContext: 1),
				writer: &writer)
			var value: UInt64 = 0
			for (index, byte) in writer.bytes.enumerated() {
				value |= UInt64(byte) << (8 * index)
			}
			return (value & ((1 << writer.bitsWritten) - 1), writer.bitsWritten)
		}
		#expect(header(224) == (0b0000_00_00_1, 9))
		#expect(header(512) == (0b0000_00_01_1, 9))
		#expect(header(4096) == (0b0000_00_10_1, 9))
		#expect(header(8 + 300) == (0b0000_00_000000100101100_11_1, 24))
	}

	@Test("forced prefix codes override the cost-based ANS choice")
	func forcedPrefixCodesSkipANS() {
		let tokens = (0..<200).map { Token(context: 0, value: UInt32(($0 * 37) % 61)) }
		var parameters = HistogramParameters()
		let costBased = EntropyCodeWriter.prepare(
			tokens, contextCount: 1, parameters: parameters)
		#expect(costBased.code.ansInfoTables != nil)
		parameters.forcesPrefixCodes = true
		let forced = EntropyCodeWriter.prepare(
			tokens, contextCount: 1, parameters: parameters)
		#expect(forced.code.lz77 == nil)
		#expect(forced.code.ansInfoTables == nil)
	}

	@Test("kBest keeps literal symbols below the LZ77 length symbols")
	func bestUintStaysBelowMinSymbol() {
		let values =
			(0..<200).map { UInt32($0 % 2 == 0 ? 0 : 250) }
			+ [UInt32](repeating: 250, count: 300)
		let prepared = EntropyCodeWriter.prepare(
			values.map { Token(context: 0, value: $0) }, contextCount: 1,
			parameters: HistogramParameters())
		let code = prepared.code
		#expect(code.lz77?.minSymbol == 224)
		for encoded in prepared.tokens where !encoded.isLength {
			let histogram = Int(code.contextMap[Int(encoded.token.context)])
			#expect(
				code.uintConfigurations![histogram].encode(encoded.token.value)
					.symbol < 224)
		}
	}

	@Test("kBest chooses the uint configuration from literals alone")
	func bestUintIgnoresLengthTokens() {
		var values: [UInt32] = []
		for run in 0..<6 {
			values += (0..<40).map { UInt32($0 % 4) }
			values += [UInt32](repeating: 1_000, count: 1_000 + 500 * run)
		}
		let prepared = EntropyCodeWriter.prepare(
			values.map { Token(context: 0, value: $0) }, contextCount: 1,
			parameters: HistogramParameters())
		#expect(prepared.tokens.filter(\.isLength).count == 6)
		#expect(prepared.code.contextMap == [0, 0])
		#expect(
			prepared.code.uintConfigurations == [
				HybridUintConfiguration(
					splitExponent: 5, msbInToken: 2, lsbInToken: 3)
			])
	}
}
