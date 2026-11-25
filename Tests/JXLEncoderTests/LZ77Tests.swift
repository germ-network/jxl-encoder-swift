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

	static func literals(_ values: [UInt32]) -> [Token] {
		values.map { Token(context: 0, value: $0) }
	}

	static func apply(_ tokens: [Token], _ method: LZ77.Method, contextCount: Int = 1)
		-> LZ77.Result
	{
		LZ77.apply(
			tokens, contextCount: contextCount,
			parameters: HistogramParameters(lz77Method: method))
	}

	/// Literals for `tokens[range]`, then one copy coded in context 0.
	static func copied(
		_ tokens: [Token], literals range: Range<Int>, length: UInt32,
		distanceSymbol: UInt32
	) -> [LZ77.EncodedToken] {
		tokens[range].map { LZ77.EncodedToken(token: $0, isLength: false) } + [
			LZ77.EncodedToken(token: Token(context: 0, value: length), isLength: true),
			LZ77.EncodedToken(
				token: Token(context: 1, value: distanceSymbol), isLength: false),
		]
	}

	static let tripled = literals(Array(1...40) + Array(1...40) + Array(1...40))
	static let lazy = literals(
		[200, 201, 202, 250] + [201, 202] + Array(1...40) + [200, 201, 202]
			+ Array(1...40))

	@Test("greedy LZ77 replaces a repeated substring with a length and distance")
	func lz77FindsRepeatedSubstring() {
		let result = Self.apply(Self.tripled, .lz77)
		#expect(result.parameters == LZ77.Parameters(minSymbol: 224, distanceContext: 1))
		#expect(
			result.tokens
				== Self.copied(
					Self.tripled, literals: 0..<40, length: 77,
					distanceSymbol: 39))
	}

	@Test(
		"greedy LZ77 follows the hash chain past the nearest short match to the longest: length 30 - 3, distance 34 - 1"
	)
	func lz77SearchesDeepInTheChain() {
		let tokens = Self.literals(
			Array(1000...1029) + [1000, 1001, 1002, 5] + Array(1000...1029))
		let result = Self.apply(tokens, .lz77)
		#expect(
			result.tokens
				== Self.copied(
					tokens, literals: 0..<30, length: 0, distanceSymbol: 29)
				+ Self.copied(
					tokens, literals: 33..<34, length: 27, distanceSymbol: 33))
	}

	@Test(
		"greedy LZ77 prices a copy with AddSymbolCost: 6 bits in a zero-entropy context rejects the short copy, so only the long one is coded"
	)
	func lz77ChargesAddSymbolCost() {
		var tokens: [Token] = []
		for value in UInt32(100)..<160 {
			tokens += [Token(context: 0, value: value), Token(context: 1, value: 7)]
		}
		tokens += tokens[115..<120] + [Token(context: 0, value: 999)] + tokens[0..<40]
		let result = Self.apply(tokens, .lz77, contextCount: 2)
		#expect(
			result.tokens
				== tokens[0..<126].map {
					LZ77.EncodedToken(token: $0, isLength: false)
				} + [
					LZ77.EncodedToken(
						token: Token(context: 0, value: 37), isLength: true),
					LZ77.EncodedToken(
						token: Token(context: 2, value: 125),
						isLength: false),
				])
	}

	@Test(
		"the optimal parse searches only the first and last 8 positions of a run, so the far copy starts 8 before the run's end, not 12"
	)
	func optimalSkipsInsideRuns() {
		let tail = [UInt32](200..<230)
		let tokens = Self.literals(
			[50] + [UInt32](repeating: 9, count: 12) + tail + [51]
				+ [UInt32](repeating: 9, count: 40) + tail)
		let result = Self.apply(tokens, .optimal)
		#expect(Self.expand(result.tokens) == tokens.map(\.value))
		#expect(
			result.tokens.suffix(4) == [
				LZ77.EncodedToken(
					token: Token(context: 0, value: 28), isLength: true),
				LZ77.EncodedToken(
					token: Token(context: 1, value: 0), isLength: false),
				LZ77.EncodedToken(
					token: Token(context: 0, value: 35), isLength: true),
				LZ77.EncodedToken(
					token: Token(context: 1, value: 70), isLength: false),
			])
	}

	@Test(
		"greedy LZ77 takes the longer match one token later: a literal, length 42 - 3, distance 43 - 1"
	)
	func lz77LazyMatchAtNextToken() {
		let result = Self.apply(Self.lazy, .lz77)
		#expect(
			result.tokens
				== Self.copied(
					Self.lazy, literals: 0..<47, length: 39, distanceSymbol: 42)
		)
	}

	@Test(
		"RLE and greedy LZ77 stay disabled unless they save 0.2 bits per token plus 16",
		arguments: [
			(LZ77.Method.lz77, [UInt32](1...5), [UInt32](1...15)),
			(
				.rle, [UInt32](repeating: 100, count: 4),
				[UInt32](repeating: 100, count: 30)
			),
		])
	func lz77RequiresMinimumGain(method: LZ77.Method, short: [UInt32], long: [UInt32]) {
		let small = Self.literals(Array(1...100) + short)
		let disabled = Self.apply(small, method)
		#expect(disabled.parameters == nil)
		#expect(
			disabled.tokens
				== small.map { LZ77.EncodedToken(token: $0, isLength: false) })
		let enabled = Self.apply(Self.literals(Array(1...100) + long), method)
		#expect(enabled.parameters != nil)
		#expect(enabled.tokens.contains { $0.isLength })
	}

	@Test("the optimal parse disables LZ77 when the greedy pass finds no gain")
	func optimalDisablesWithoutGain() {
		let tokens = Self.literals(Array(1...100) + Array(1...5))
		let result = Self.apply(tokens, .optimal)
		#expect(result.parameters == nil)
		#expect(
			result.tokens
				== tokens.map { LZ77.EncodedToken(token: $0, isLength: false) })
	}

	@Test(
		"the optimal parse, costed by the greedy result, codes one copy where literals cost more"
	)
	func optimalCodesHandTracedCopies() {
		#expect(
			Self.apply(Self.tripled, .optimal).tokens
				== Self.copied(
					Self.tripled, literals: 0..<40, length: 77,
					distanceSymbol: 39))
		#expect(
			Self.apply(Self.lazy, .optimal).tokens
				== Self.copied(
					Self.lazy, literals: 0..<47, length: 39, distanceSymbol: 42)
		)
	}

	/// Literal runs, zero runs, overlapping and distant copies over three
	/// contexts.
	static let mixed: [Token] = {
		var state: UInt32 = 12_345
		func next(_ bound: UInt32) -> UInt32 {
			state = state &* 1_103_515_245 &+ 12_345
			return (state >> 16) % bound
		}
		var values: [UInt32] = []
		while values.count < 6_000 {
			switch next(4) {
			case 0:
				values += (0..<(1 + next(20))).map { _ in next(300) }
			case 1:
				values += [UInt32](repeating: 0, count: Int(1 + next(40)))
			case 2:
				values += [UInt32](repeating: next(8), count: Int(1 + next(12)))
			default:
				guard values.count > 2 else { continue }
				let start = Int(next(UInt32(values.count - 1)))
				for offset in 0..<Int(3 + next(60)) {
					values.append(values[start + offset])
				}
			}
		}
		return values.enumerated().map {
			Token(context: UInt32($0.offset % 3), value: $0.element)
		}
	}()

	@Test(
		"every method's output expands back to its input tokens",
		arguments: [LZ77.Method.rle, .lz77, .optimal])
	func expansionRecoversInput(method: LZ77.Method) {
		let result = Self.apply(Self.mixed, method, contextCount: 3)
		#expect(result.parameters == LZ77.Parameters(minSymbol: 224, distanceContext: 3))
		#expect(Self.expand(result.tokens) == Self.mixed.map(\.value))
		var position = 0
		var index = 0
		while index < result.tokens.count {
			let encoded = result.tokens[index]
			#expect(encoded.token.context == Self.mixed[position].context)
			guard encoded.isLength else {
				position += 1
				index += 1
				continue
			}
			#expect(result.tokens[index + 1].token.context == 3)
			#expect(!result.tokens[index + 1].isLength)
			position += Int(encoded.token.value + LZ77.minLength)
			index += 2
		}
	}
}
