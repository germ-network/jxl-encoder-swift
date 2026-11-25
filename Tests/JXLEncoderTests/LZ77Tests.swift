import Testing

@testable import JXLEncoder

/// The `ApplyLZ77` port: each method expands back to its input and enables
/// itself only past the source's gain threshold.
@Suite("LZ77")
struct LZ77Tests {
	@Test("RLE codes a run of the previous value as a length then distance 0")
	func rleCopiesThePreviousValue() {
		let values =
			(0..<128).map { UInt32($0 % 64) } + [UInt32](repeating: 63, count: 40)
			+ [5, 5, 5, 5, 9, 9, 9]
		let tokens = values.enumerated().map {
			Token(context: UInt32($0.offset % 2), value: $0.element)
		}
		let result = LZ77.apply(tokens, contextCount: 2, parameters: HistogramParameters())
		#expect(result.parameters == LZ77.Parameters(minSymbol: 224, distanceContext: 2))
		func literal(_ index: Int) -> LZ77.EncodedToken {
			LZ77.EncodedToken(token: tokens[index], isLength: false)
		}
		func copy(context: UInt32, length: UInt32) -> [LZ77.EncodedToken] {
			[
				LZ77.EncodedToken(
					token: Token(context: context, value: length),
					isLength: true),
				LZ77.EncodedToken(
					token: Token(context: 2, value: 0), isLength: false),
			]
		}
		let expected =
			(0..<128).map(literal) + copy(context: 0, length: 37) + [literal(168)]
			+ copy(context: 1, length: 0) + (172..<175).map(literal)
		#expect(result.tokens == expected)
		#expect(Self.expand(result.tokens) == values)
	}

	/// A decoder's view: a length copies `value + minLength` symbols from the
	/// distance that follows it, where distance symbol d means d + 1 back.
	static func expand(_ tokens: [LZ77.EncodedToken]) -> [UInt32] {
		var output: [UInt32] = []
		var index = 0
		while index < tokens.count {
			guard tokens[index].isLength else {
				output.append(tokens[index].token.value)
				index += 1
				continue
			}
			let distance = Int(tokens[index + 1].token.value) + 1
			for _ in 0..<(Int(tokens[index].token.value) + Int(LZ77.minLength)) {
				output.append(output[output.count - distance])
			}
			index += 2
		}
		return output
	}

	@Test(
		"greedy LZ77 replaces a repeated substring with a length and distance",
		.disabled("pending implementation"))
	func lz77FindsRepeatedSubstring() {}

	@Test(
		"RLE and greedy LZ77 stay disabled unless they save 0.2 bits per token plus 16",
		.disabled("pending implementation"))
	func lz77RequiresMinimumGain() {}

	@Test(
		"the optimal parse disables LZ77 when the greedy pass finds no gain",
		.disabled("pending implementation"))
	func optimalDisablesWithoutGain() {}

	@Test(
		"every method's output expands back to its input tokens",
		.disabled("pending implementation"),
		arguments: [LZ77.Method.rle, .lz77, .optimal])
	func expansionRecoversInput(method: LZ77.Method) {}
}
