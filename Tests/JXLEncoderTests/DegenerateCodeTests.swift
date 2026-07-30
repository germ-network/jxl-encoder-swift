import Testing

@testable import JXLEncoder

/// A prefix code over a single reachable symbol is degenerate: there is nothing
/// to distinguish, so the codeword is zero bits long and the decoder consumes
/// none. `CreateHuffmanTree` marks that symbol depth 1 as a placeholder — the
/// reference calls it "fake, fixed up on the upper level" — and serialization
/// still needs it, because both the symbol index and the alphabet size are read
/// back out of the depth table. Only the token writer must ignore it.
///
/// Getting this wrong emits one stray bit per token and desynchronises the
/// stream. Per-image clustering reaches it easily: a bucket holding a single
/// token value is common once contexts are merged.
@Suite("Degenerate prefix codes")
struct DegenerateCodeTests {
	static func code(symbol: UInt32, count: Int) -> EntropyCode {
		var histogram = Histogram()
		for _ in 0..<count { histogram.add(symbol) }
		return EntropyCode(
			contextMap: [0], prefixCodes: HistogramCluster.buildPrefixCodes([histogram])
		)
	}

	/// Smallest token value that encodes to `symbol`, with the extra bits it
	/// carries. Symbols past the hybrid-uint split always carry some.
	static func value(for symbol: UInt32) -> (value: UInt32, extraBits: Int)? {
		for value: UInt32 in 0..<(1 << 20) {
			let (encoded, bitCount, _) = UintCoder.encode(value)
			if encoded == symbol { return (value, Int(bitCount)) }
		}
		return nil
	}

	/// The codeword contributes nothing, so a token costs exactly its extra bits.
	@Test("one used symbol yields a zero-length codeword", arguments: [0, 1, 8, 30])
	func zeroLengthCodeword(symbol: Int) throws {
		let code = Self.code(symbol: UInt32(symbol), count: 100)
		#expect(code.prefixCodes[0].isDegenerate)

		let (value, extraBits) = try #require(Self.value(for: UInt32(symbol)))
		var writer = BitWriter()
		writer.write(token: Token(context: 0, value: value), code: code)
		#expect(writer.bitsWritten == extraBits)
	}

	/// Extra bits are not part of the codeword, so they must still be written.
	@Test("extra bits survive a degenerate codeword")
	func extraBitsKept() {
		let value: UInt32 = 1000
		let (symbol, bitCount, _) = UintCoder.encode(value)
		#expect(bitCount > 0)
		let code = Self.code(symbol: symbol, count: 50)
		#expect(code.prefixCodes[0].isDegenerate)

		var writer = BitWriter()
		writer.write(token: Token(context: 0, value: value), code: code)
		#expect(writer.bitsWritten == bitCount)
	}

	/// The placeholder depth has to stay in the table: `writePrefixCode` recovers
	/// the symbol from it, and a zeroed table would name symbol 0 instead.
	@Test("serialization still sees the symbol")
	func symbolPreserved() {
		let code = Self.code(symbol: 8, count: 100)
		#expect(code.prefixCodes[0].depths[8] == 1)
		#expect(code.prefixCodes[0].depths.filter { $0 != 0 }.count == 1)
	}

	@Test("a code over several symbols is not degenerate")
	func multiSymbol() {
		var histogram = Histogram()
		for symbol in 0..<5 { for _ in 0...symbol { histogram.add(UInt32(symbol)) } }
		let codes = HistogramCluster.buildPrefixCodes([histogram])
		#expect(!codes[0].isDegenerate)
	}
}
