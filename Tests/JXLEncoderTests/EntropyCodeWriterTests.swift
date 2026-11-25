import Testing

@testable import JXLEncoder

/// The general histogram builder signals forced prefix codes the way libjxl
/// does.
@Suite("EntropyCodeWriter")
struct EntropyCodeWriterTests {
	@Test(
		"forced prefix codes write LZ77 min_symbol 512 and use_prefix_code",
		.disabled("pending implementation"))
	func forcedPrefixCodesUseMinSymbol512() {}

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
