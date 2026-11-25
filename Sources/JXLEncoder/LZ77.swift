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
	/// The struct moves here from `ContextMapEntropy` when that type is
	/// replaced by `EntropyCodeWriter.prepare`.
	typealias EncodedToken = ContextMapEntropy.EncodedToken

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
		fatalError("unimplemented")
	}
}
