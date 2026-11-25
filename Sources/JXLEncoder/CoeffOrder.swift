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
//  Statistics use the source's frame-wide sample stream, so ordering follows
//  the same groups and coefficient cursor as the encoder's coded data.
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

	struct Sampler {
		private var state: (UInt64, UInt64) = (0x94D0_49BB_1331_11EB, 0xBF58_476D_1CE4_E5B9)

		mutating func next() -> Bool {
			let first = state.0
			let second = state.1
			let sample = first &+ second
			var next = first
			state.0 = second
			next ^= next &<< 23
			next ^= second ^ (next >> 18) ^ (second >> 5)
			state.1 = next
			return (sample >> 32) <= 0x7FFF_FFFF
		}
	}

	static func accumulateGroup(
		_ coefficients: [[Int32]], widthInBlocks: Int, heightInBlocks: Int,
		sampler: inout Sampler, counts: inout [ZeroCounts]
	) {
		precondition(coefficients.count == 3 && counts.count == 3)
		precondition(widthInBlocks >= 0 && heightInBlocks >= 0)
		var coefficientOffset = 0
		for _ in 0..<(widthInBlocks * heightInBlocks) where sampler.next() {
			for channel in 0..<3 {
				precondition(
					coefficientOffset + DCT.blockSize
						<= coefficients[channel].count)
				counts[channel].add(
					coefficients[channel][
						coefficientOffset..<(coefficientOffset
							+ DCT.blockSize)])
			}
			coefficientOffset += DCT.blockSize
		}
	}

	/// `CoeffOrderContext`: `HybridUintConfig(0, 0, 0).Encode(val).token`,
	/// clamped to `permutationContexts - 1`. Traced from the general formula
	/// rather than reimplemented generically, since split_exponent=0 collapses
	/// it to `floorLog2Nonzero(val) + 1`.
	static func context(_ value: Int) -> Int {
		value == 0 ? 0 : min(floorLog2Nonzero(value) + 1, permutationContexts - 1)
	}

	/// Per-channel accumulator: how often each raster position held a zero
	/// coefficient in sampled blocks.
	public struct ZeroCounts: Sendable {
		var counts = [Int64](repeating: 0, count: DCT.blockSize)

		public init() {}

		mutating func add(_ block: ArraySlice<Int32>) {
			let base = block.startIndex
			for k in 0..<DCT.blockSize where block[base + k] == 0 {
				counts[k] += 1
			}
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
	/// is nothing to gain from sorting it. The source's key for this rank is
	/// Float(-0.125) + 0.1; conversion to UInt truncates toward zero, yielding
	/// the same zero key, so fixing the slot directly preserves its order.
	static func computeOrder(counts: [Int64]) -> ChannelOrder {
		let invSqrtSize = 1.0 / Float(DCT.blockSize).squareRoot()
		func key(rank: Int) -> Int64 {
			Int64(Float(counts[natural[rank]]) * invSqrtSize + 0.1)
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
		var result = [
			Token(context: UInt32(context(DCT.blockSize)), value: UInt32(end - 1))
		]
		var last = 0
		for i in 1..<end {
			result.append(
				Token(context: UInt32(context(last)), value: UInt32(lehmer[i])))
			last = lehmer[i]
		}
		return result
	}

	/// The frame-global outcome: one order per channel (always `natural` when
	/// reordering isn't worthwhile, matching `used_orders == 0`) plus whether
	/// any channel actually differs — the reference transmits all three
	/// permutations together once any one of them is non-default.
	///
	/// One value computed once per frame has to reach two places: `.orders`
	/// tokenizes the AC groups, and the whole `Result` is what
	/// `FrameAssembly.writeACGlobal` transmits. Both consumers must see the
	/// *same* `Result` for a given encode — the tokenized order and the
	/// signalled order are unrelated to the decoder otherwise.
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

	/// Writes the `Bits(13)` value selected by FrameAssembly for custom DCT8
	/// orders. The default `Val(0)` branch has no payload.
	public static func write(_ result: Result, writer: inout BitWriter) {
		guard result.isCustom else { return }
		writer.write(13, 1)

		let allTokens = result.orders.flatMap { tokens(forChannelOrder: $0) }
		EntropyCodeWriter.write(
			EntropyCodeWriter.prepare(
				allTokens, contextCount: permutationContexts,
				parameters: HistogramParameters()), writer: &writer)
	}
}
