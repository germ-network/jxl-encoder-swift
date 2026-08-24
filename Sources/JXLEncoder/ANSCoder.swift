//
//  ANSCoder.swift
//  JXLEncoder
//
//  Port of full libjxl's rANS entropy back-end — `ans_common.cc`'s alias
//  table, `enc_ans.h`'s `ANSCoder`, and `enc_ans.cc`'s reverse-order token
//  writer. libjxl-tiny has no ANS at all (prefix codes only); no tiny
//  counterpart. See docs/gap-closure-plan.md, Phase B.
//
//  Deliberately narrower than the reference in two ways, both justified by
//  the plan's own non-goals (byte-exactness against cjxl is explicitly not a
//  gate — decode-exactness and size corridors are):
//
//  - Histogram *normalization* uses a standard largest-remainder rounding to
//    a fixed exact-precision distribution, not `RebalanceHistogram`'s greedy
//    bin-by-bin size search over a precomputed 12x4096 allowed-counts table.
//    That search chooses *how many bits to drop* per count to shrink the
//    header; skipping it means always transmitting full precision (real
//    libjxl's own `shift = ANS_LOG_TAB_SIZE` case, not an invented one) —
//    larger headers, same wire *shape*, same decodability.
//  - `ANSCoder` uses plain integer division, not `enc_ans.h`'s
//    mult-by-reciprocal trick — that trick exists purely to avoid a division
//    instruction and is bit-exact-equivalent to the division it replaces.
//
//  The alias table construction and the rANS state recursion themselves are
//  zero-tolerance: unlike the above, they are never transmitted, so encoder
//  and decoder must reconstruct byte-for-byte the same table independently
//  from the signaled frequencies alone. Both are ported verbatim.
//

enum ANSConstants {
	static let logTabSize = 12
	static let tabSize = 1 << logTabSize  // 4096
	/// `ANS_MAX_ALPHABET_SIZE`; our token alphabet (64) sits well under it.
	static let maxAlphabetSize = 256
	/// `CeilLog2Nonzero(StaticEntropyCodes.alphabetSize)`, pinned as a
	/// constant rather than computed per histogram: our token alphabet is
	/// fixed-size, not data-narrowed the way full libjxl's is.
	static let logAlphaSize = 6
}

/// One entry of the alias table used only to *construct* `reverseMap` below;
/// nothing else reads it once built, so it carries none of
/// `AliasTable::Entry`'s bit-packing or the XOR-encoded `freq` full libjxl
/// keeps for its own (unneeded here) branchless decoder lookup.
struct ANSAliasEntry {
	var cutoff = 0
	var rightValue = 0
	var offsets1 = 0
}

enum ANSAliasTable {
	/// Port of `InitAliasTable` (ans_common.cc). `distribution` must already
	/// sum to `ANSConstants.tabSize`.
	static func build(distribution rawDistribution: [Int], logAlphaSize: Int) -> [ANSAliasEntry] {
		var distribution = rawDistribution
		while let last = distribution.last, last == 0 {
			distribution.removeLast()
		}
		if distribution.isEmpty {
			distribution.append(ANSConstants.tabSize)
		}

		let tableSize = 1 << logAlphaSize
		let entrySize = ANSConstants.tabSize >> logAlphaSize
		var table = [ANSAliasEntry](repeating: ANSAliasEntry(), count: tableSize)

		var singleSymbol = -1
		var sum = 0
		for (sym, v) in distribution.enumerated() {
			sum += v
			if v == ANSConstants.tabSize { singleSymbol = sym }
		}
		precondition(sum == ANSConstants.tabSize, "distribution must sum to tabSize")

		if singleSymbol != -1 {
			for i in 0..<tableSize {
				table[i].rightValue = singleSymbol
				table[i].cutoff = 0
				table[i].offsets1 = entrySize * i
			}
			return table
		}

		var underfull: [Int] = []
		var overfull: [Int] = []
		var cutoffs = [Int](repeating: 0, count: tableSize)
		for i in 0..<distribution.count {
			cutoffs[i] = distribution[i]
			if cutoffs[i] > entrySize {
				overfull.append(i)
			} else if cutoffs[i] < entrySize {
				underfull.append(i)
			}
		}
		for i in distribution.count..<tableSize {
			cutoffs[i] = 0
			underfull.append(i)
		}

		while !overfull.isEmpty {
			let overfullI = overfull.removeLast()
			precondition(!underfull.isEmpty, "overfull without underfull — invalid distribution")
			let underfullI = underfull.removeLast()
			let underfullBy = entrySize - cutoffs[underfullI]
			cutoffs[overfullI] -= underfullBy
			table[underfullI].rightValue = overfullI
			table[underfullI].offsets1 = cutoffs[overfullI]
			if cutoffs[overfullI] < entrySize {
				underfull.append(overfullI)
			} else if cutoffs[overfullI] > entrySize {
				overfull.append(overfullI)
			}
		}

		for i in 0..<tableSize {
			if cutoffs[i] == entrySize {
				table[i].rightValue = i
				table[i].offsets1 = 0
				table[i].cutoff = 0
			} else {
				table[i].offsets1 -= cutoffs[i]
				table[i].cutoff = cutoffs[i]
			}
		}
		return table
	}

	/// Port of `AliasTable::Lookup`, minus the branchless bit-packing tricks
	/// that exist only for decoder speed.
	static func lookup(
		_ table: [ANSAliasEntry], value: Int, logEntrySize: Int, entrySizeMinus1: Int
	) -> (symbol: Int, offset: Int) {
		let i = value >> logEntrySize
		let pos = value & entrySizeMinus1
		let entry = table[i]
		if pos >= entry.cutoff {
			return (entry.rightValue, entry.offsets1 + pos)
		}
		return (i, pos)
	}
}

/// Port of `ANSEncSymbolInfo`, minus prefix-coding fields (unused here) and
/// `ifreq_` (the reciprocal-multiplication trick this port skips).
public struct ANSEncSymbolInfo: Sendable {
	var freq = 0
	var reverseMap: [UInt16] = []
}

enum ANSInfoTable {
	/// Port of `ANSEncodingHistogram::ANSBuildInfoTable`. `alphabetSize` is
	/// the full token alphabet (every symbol gets an entry, even ones with
	/// zero count), not `distribution`'s length after trailing-zero trim —
	/// those are different sizes in the reference too.
	static func build(distribution: [Int], alphabetSize: Int, logAlphaSize: Int) -> [ANSEncSymbolInfo] {
		let table = ANSAliasTable.build(distribution: distribution, logAlphaSize: logAlphaSize)
		var info = [ANSEncSymbolInfo](repeating: ANSEncSymbolInfo(), count: alphabetSize)
		for s in 0..<alphabetSize {
			let freq = s < distribution.count ? distribution[s] : 0
			info[s].freq = freq
			info[s].reverseMap = [UInt16](repeating: 0, count: freq)
		}
		let logEntrySize = ANSConstants.logTabSize - logAlphaSize
		let entrySizeMinus1 = (1 << logEntrySize) - 1
		for i in 0..<ANSConstants.tabSize {
			let (symbol, offset) = ANSAliasTable.lookup(
				table, value: i, logEntrySize: logEntrySize, entrySizeMinus1: entrySizeMinus1)
			info[symbol].reverseMap[offset] = UInt16(i)
		}
		return info
	}
}

/// Port of `ANSCoder` (enc_ans.h): the rANS state recursion itself. Encodes
/// in reverse token order — see `ANSTokenWriter`.
struct ANSState {
	private var state: UInt32 = 0x13 << 16  // ANS_SIGNATURE << 16

	/// Returns renormalization bits to emit (0 or 16 of them, low-to-high).
	mutating func putSymbol(_ info: ANSEncSymbolInfo) -> (bits: UInt32, nbits: Int) {
		var bits: UInt32 = 0
		var nbits = 0
		if (state >> (32 - UInt32(ANSConstants.logTabSize))) >= UInt32(info.freq) {
			bits = state & 0xffff
			state >>= 16
			nbits = 16
		}
		let freq = UInt32(info.freq)
		let v = state / freq
		let offset = Int(state - v * freq)
		state = (v << ANSConstants.logTabSize) | UInt32(info.reverseMap[offset])
		return (bits, nbits)
	}

	var currentState: UInt32 { state }
}
