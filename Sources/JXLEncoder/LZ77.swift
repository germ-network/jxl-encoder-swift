//
//  LZ77.swift
//  JXLEncoder
//
//  Backward references over a token stream, ported from libjxl enc_lz77.cc
//  (`ApplyLZ77` and its RLE, greedy hash-chain and optimal-parse variants).
//  A length token carries `minSymbol` + the hybrid-uint length symbol; the
//  distance that follows goes in an extra context after the stream's own.
//

enum LZ77 {
	/// `HistogramParams::LZ77Method` (enc_ans_params.h), less `kNone`, which no
	/// caller of the histogram builder selects.
	enum Method: Equatable, Sendable {
		/// Repeat-previous runs only (`ApplyLZ77_RLE`).
		case rle
		/// Greedy hash-chain matching (`ApplyLZ77_LZ77`).
		case lz77
		/// Cost-driven parse seeded by the greedy result (`ApplyLZ77_Optimal`).
		case optimal
	}

	/// libjxl never changes `LZ77Params::min_length` from its default
	/// (dec_ans.cc:313-314).
	static let minLength: UInt32 = 3

	/// The length symbols' uint configuration, written with log alpha 8
	/// (enc_ans.cc:1107-1113).
	static let lengthConfiguration = HybridUintConfiguration(
		splitExponent: 0, msbInToken: 0, lsbInToken: 0)

	/// The serialized `LZ77Params` of an enabled stream (dec_ans.cc:304-315)
	/// plus the distance context, which libjxl keeps unserialized.
	struct Parameters: Equatable, Sendable {
		/// 224, or 512 under forced prefix codes (enc_ans.cc:1090).
		let minSymbol: UInt32
		/// The stream's context count: distances follow every original context.
		let distanceContext: Int
	}

	/// A token after LZ77: a literal, a length, or the distance after a length.
	struct EncodedToken: Equatable, Sendable {
		let token: Token
		let isLength: Bool
	}

	struct Result {
		/// Nil when LZ77 did not pay for itself.
		let parameters: Parameters?
		/// Literals only, in input order, when `parameters` is nil.
		let tokens: [EncodedToken]
	}

	/// Replaces repeats with length/distance pairs by `parameters.lz77Method`.
	/// RLE and greedy keep the result only when it saves more than 0.2 bits
	/// per token plus 16 (enc_lz77.cc:165, :540); the optimal parse runs only
	/// when the greedy pass met that bar (enc_lz77.cc:550-553). Either way a
	/// decoder expanding the result recovers `tokens`. Ports `ApplyLZ77`
	/// (enc_lz77.cc:684-697).
	static func apply(
		_ tokens: [Token], contextCount: Int, parameters: HistogramParameters
	) -> Result {
		precondition(
			contextCount > 0 && tokens.allSatisfy { Int($0.context) < contextCount })
		let lz77 = Parameters(
			minSymbol: parameters.lz77MinSymbol, distanceContext: contextCount)
		let (transformed, bitDecrease) =
			switch parameters.lz77Method {
			case .rle:
				rle(
					tokens, lz77: lz77,
					symbolCosts: symbolCosts(
						tokens, contextCount: contextCount, parameters))
			case .lz77, .optimal: fatalError("unimplemented")
			}
		guard Double(bitDecrease) > Double(tokens.count) * 0.2 + 16 else {
			return Result(
				parameters: nil,
				tokens: tokens.map { EncodedToken(token: $0, isLength: false) })
		}
		return Result(parameters: lz77, tokens: transformed)
	}

	/// `SymbolCostEstimator`'s per-context symbol costs over literal tokens
	/// (enc_lz77.cc:30-74).
	private static func symbolCosts(
		_ tokens: [Token], contextCount: Int, _ parameters: HistogramParameters
	) -> [[Float]] {
		var histograms = [Histogram](repeating: Histogram(), count: contextCount)
		for token in tokens {
			histograms[Int(token.context)].add(
				literalConfiguration.encode(token.value).symbol)
		}
		return histograms.map { histogram in
			let inverseTotal = 1.0 / (Float(histogram.totalCount) + 1e-8)
			return histogram.counts.map { count in
				guard count != 0 else { return Float(ANSConstants.logTabSize) }
				guard Int(count) != histogram.totalCount else { return 0 }
				let cost = -FastMath.log2(Float(count) * inverseTotal)
				return parameters.forcesPrefixCodes ? cost.rounded(.up) : cost
			}
		}
	}

	private static let literalConfiguration = HybridUintConfiguration(
		splitExponent: 4, msbInToken: 2, lsbInToken: 0)

	/// `ApplyLZ77_RLE` (enc_lz77.cc:97-169) without image-width distances.
	private static func rle(
		_ tokens: [Token], lz77: Parameters, symbolCosts: [[Float]]
	) -> ([EncodedToken], Float) {
		var cumulative = [Float](repeating: 0, count: tokens.count + 1)
		for (index, token) in tokens.enumerated() {
			let encoded = literalConfiguration.encode(token.value)
			cumulative[index + 1] =
				symbolCosts[Int(token.context)][Int(encoded.symbol)]
				+ Float(encoded.bitCount) + cumulative[index]
		}
		var transformed: [EncodedToken] = []
		transformed.reserveCapacity(tokens.count)
		var bitDecrease: Float = 0
		var index = 0
		while index < tokens.count {
			var copyCount = 0
			if index > 0 {
				while index + copyCount < tokens.count,
					tokens[index + copyCount].value == tokens[index - 1].value
				{
					copyCount += 1
				}
			}
			let cost = cumulative[index + copyCount] - cumulative[index]
			let length = copyCount - Int(minLength)
			let lengthCost =
				copyCount >= Int(minLength)
				? Float(ceilLog2Nonzero(length + 1) + 1) : 0
			if copyCount < Int(minLength) || cost <= lengthCost {
				let end = index + max(copyCount, 1)
				transformed += tokens[index..<end].map {
					EncodedToken(token: $0, isLength: false)
				}
				index = end
				continue
			}
			transformed.append(
				EncodedToken(
					token: Token(
						context: tokens[index].context,
						value: UInt32(length)),
					isLength: true))
			transformed.append(
				EncodedToken(
					token: Token(
						context: UInt32(lz77.distanceContext), value: 0),
					isLength: false))
			bitDecrease += cost - lengthCost
			index += copyCount
		}
		return (transformed, bitDecrease)
	}
}
