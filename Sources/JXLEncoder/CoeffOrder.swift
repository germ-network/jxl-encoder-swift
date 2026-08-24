//
//  CoeffOrder.swift
//  JXLEncoder
//
//  Port of the DCT8 subset of `enc_coeff_order.cc`/`coeff_order.cc`: a
//  per-frame, per-channel permutation of the AC scan order, computed from
//  the frame's own zero/nonzero statistics per coefficient position and
//  transmitted as a Lehmer (factorial-base) code. No tiny counterpart —
//  active at the named target (`-e 4` is `SpeedTier::kCheetah`, whose own
//  source comment reads "enables coefficient reordering"). See
//  docs/gap-closure-plan.md's "Scoped: coefficient reordering" section.
//
//  Narrowed from the reference by DCT8-only content: one order bucket
//  instead of 13, so `used_orders` is only ever 0 or 1, and the natural
//  order turns out to already exist in this port — `ComputeNaturalCoeffOrder`
//  for an 8x8, single-covered-block transform is, position for position,
//  `ACTokenizer.coeffOrder`.
//
//  One deliberate simplification: the reference samples only half the
//  frame's blocks at this speed tier, via a seeded PRNG, purely as a speed
//  optimisation. This port counts every block — no PRNG state to carry,
//  strictly better statistics, and the counting pass is cheap next to the
//  DCT/quantize work it rides alongside.
//

enum CoeffOrder {
	/// `ComputeNaturalCoeffOrder`'s output for DCT8 — verified identical to
	/// this table by running the reference's index arithmetic in isolation.
	static let natural = ACTokenizer.coeffOrder

	/// `ComputeNaturalCoeffOrderLut`'s output: the inverse of `natural`, i.e.
	/// `lut[rasterPosition] = scanRank`.
	static let inverseNatural: [Int] = {
		var lut = [Int](repeating: 0, count: DCT.blockSize)
		for rank in 0..<DCT.blockSize { lut[natural[rank]] = rank }
		return lut
	}()

	static let permutationContexts = 8

	/// `CoeffOrderContext`: `HybridUintConfig(0, 0, 0).Encode(val).token`,
	/// clamped to `permutationContexts - 1`. Traced from the general formula
	/// rather than reimplemented generically, since split_exponent=0 collapses
	/// it to `floorLog2Nonzero(val) + 1`.
	static func context(_ value: Int) -> Int {
		value == 0 ? 0 : min(floorLog2Nonzero(value) + 1, permutationContexts - 1)
	}

	/// Per-channel accumulator: how often each raster position held a zero
	/// coefficient, across every block in the frame.
	public struct ZeroCounts: Sendable {
		var counts = [Int64](repeating: 0, count: DCT.blockSize)

		public init() {}

		mutating func add(_ block: ArraySlice<Int32>) {
			let base = block.startIndex
			for k in 0..<DCT.blockSize where block[base + k] == 0 {
				counts[k] += 1
			}
		}

		/// Adds every block in a flat, block-major coefficient array (as
		/// `ACGroupEncoder.computeGroup` returns per channel).
		public mutating func addAll(_ flat: [Int32]) {
			var start = 0
			while start < flat.count {
				add(flat[start..<start + DCT.blockSize])
				start += DCT.blockSize
			}
		}

		/// Combines another group's (or channel's) counts into this one, so
		/// counting can run per-group and reduce afterwards.
		mutating func merge(_ other: ZeroCounts) {
			for k in 0..<DCT.blockSize { counts[k] += other.counts[k] }
		}
	}

	struct ChannelOrder {
		let order: [Int]
		let isDefault: Bool
	}

	/// Sorts scan ranks 1..<64 by (quantised) zero count ascending — positions
	/// more often nonzero move earlier — ties broken by original scan rank.
	/// Rank 0 (raster position 0, the LLF slot) always stays fixed: it is
	/// never transmitted regardless (`TokenizePermutation`'s `skip`), so there
	/// is nothing to gain from sorting it, and the reference's own mechanism
	/// for forcing it first relies on an unsigned cast of a negative float
	/// that is undefined behaviour in C++ — not worth reproducing when fixing
	/// the slot directly gives the identical transmitted permutation.
	static func computeOrder(counts: [Int64]) -> ChannelOrder {
		let invSqrtSize = 1.0 / Double(DCT.blockSize).squareRoot()
		func key(rank: Int) -> Int64 {
			Int64(Double(counts[natural[rank]]) * invSqrtSize + 0.1)
		}
		let sortedRanks = (1..<DCT.blockSize).sorted { a, b in
			let ka = key(rank: a)
			let kb = key(rank: b)
			return ka == kb ? a < b : ka < kb
		}
		var order = [Int](repeating: 0, count: DCT.blockSize)
		order[0] = natural[0]
		for (slot, rank) in sortedRanks.enumerated() { order[1 + slot] = natural[rank] }
		return ChannelOrder(order: order, isDefault: order == natural)
	}

	/// Port of `ComputeLehmerCode` (lehmer_code.h): a Fenwick-tree-based
	/// encode of a permutation into factorial-base digits. Encode direction
	/// only — nothing here ever needs to decode one back.
	static func computeLehmerCode(_ permutation: [Int]) -> [Int] {
		let n = permutation.count
		var temp = [Int](repeating: 0, count: n + 1)
		var code = [Int](repeating: 0, count: n)
		for idx in 0..<n {
			let s = permutation[idx]
			var penalty = 0
			var i = s + 1
			while i != 0 {
				penalty += temp[i]
				i &= i - 1
			}
			code[idx] = s - penalty
			i = s + 1
			while i < n + 1 {
				temp[i] += 1
				i += i & (-i)
			}
		}
		return code
	}

	/// Port of `TokenizePermutation`: the Lehmer code of `order` re-expressed
	/// relative to scan rank (`natural_order_lut[order[i]]`), trimmed of
	/// trailing zero digits, and tokenized as a length followed by chained
	/// digits. `skip = 1` (DCT8's `covered_blocks`) — the LLF slot is never
	/// transmitted.
	static func tokens(forChannelOrder order: [Int]) -> [Token] {
		let zigzagOrder = order.map { inverseNatural[$0] }
		let lehmer = computeLehmerCode(zigzagOrder)
		var end = DCT.blockSize
		while end > 1 && lehmer[end - 1] == 0 { end -= 1 }
		var result = [Token(context: UInt32(context(DCT.blockSize)), value: UInt32(end - 1))]
		var last = 0
		for i in 1..<end {
			result.append(Token(context: UInt32(context(last)), value: UInt32(lehmer[i])))
			last = lehmer[i]
		}
		return result
	}

	/// The frame-global outcome: one order per channel (always `natural` when
	/// reordering isn't worthwhile, matching `used_orders == 0`) plus whether
	/// any channel actually differs — the reference transmits all three
	/// permutations together once any one of them is non-default.
	public struct Result: Sendable {
		public let orders: [[Int]]
		public let isCustom: Bool

		public static let identity = Result(
			orders: [CoeffOrder.natural, CoeffOrder.natural, CoeffOrder.natural],
			isCustom: false)
	}

	/// `ComputeUsedOrders`' size floor: frames narrower than 5 blocks on both
	/// axes keep the default order, matching the reference's "use default
	/// orders for small images."
	static func isFrameTooSmall(widthInBlocks: Int, heightInBlocks: Int) -> Bool {
		widthInBlocks < 5 && heightInBlocks < 5
	}

	public static func compute(
		counts: [ZeroCounts], widthInBlocks: Int, heightInBlocks: Int
	) -> Result {
		guard !isFrameTooSmall(widthInBlocks: widthInBlocks, heightInBlocks: heightInBlocks)
		else { return .identity }
		let perChannel = counts.map { computeOrder(counts: $0.counts) }
		guard perChannel.contains(where: { !$0.isDefault }) else { return .identity }
		return Result(orders: perChannel.map(\.order), isCustom: true)
	}

	/// Port of `EncodeGlobalACInfo`'s `used_orders` + `EncodeCoeffOrders`
	/// sequence. The `used_orders` field is `U32Enc(Val(0x5F), Val(0x13),
	/// Val(0), Bits(kNumOrders))`; with one order bucket the value is only
	/// ever 0 or 1, both of which the existing `Bits(13)` branch already
	/// encodes correctly (matches the selector `writeACGlobal` already sends
	/// for the always-0 case this replaces), so this is a direct value write
	/// rather than a general U32Enc port.
	public static func write(_ result: Result, writer: inout BitWriter) {
		writer.write(13, result.isCustom ? 1 : 0)
		guard result.isCustom else { return }

		let allTokens = result.orders.flatMap { tokens(forChannelOrder: $0) }
		let code = HistogramCluster.optimizeEntropyCode(
			tokens: allTokens, contextCount: permutationContexts)
		writer.write(1, 0)  // no lz77
		EntropyCodeWriter.write(code, writer: &writer)
		for token in allTokens {
			writer.write(token: token, code: code)
		}
	}
}
