//
//  ANSHistogramWriter.swift
//  JXLEncoder
//
//  Port of `ANSEncodingHistogram::Encode` (enc_ans.cc) — signals the
//  normalized frequency distribution so the decoder can reconstruct the same
//  alias table independently. No tiny counterpart (tiny has no ANS).
//
//  Simplified from the reference in the way ANSCoder.swift documents: always
//  full precision (no bits dropped — real libjxl's own maximum-precision
//  case, `method = ANS_LOG_TAB_SIZE`, not an invented one), so the
//  shift-dependent `GetPopulationCountPrecision` rounding never triggers.
//  `omit_pos` is *not* a size optimisation this port can skip — the decoder
//  identifies the omitted symbol as whichever has the (tied-for-)largest
//  transmitted bit-width, so a valid bitstream requires playing by that
//  convention even without the precision-dropping this port omits.
//

func floorLog2Nonzero(_ n: Int) -> Int {
	precondition(n > 0)
	return Int.bitWidth - 1 - n.leadingZeroBitCount
}

/// `CeilLog2Nonzero` (base/bits.h): `FloorLog2Nonzero`, plus one unless `n`
/// is itself a power of two.
func ceilLog2Nonzero(_ n: Int) -> Int {
	let floor = floorLog2Nonzero(n)
	return (n & (n - 1)) == 0 ? floor : floor + 1
}

enum ANSHistogramWriter {
	private static let maxSymbolsForSmallCode = 2

	private static let bitWidthLengths: [Int] = [5, 4, 4, 4, 4, 4, 3, 3, 3, 3, 3, 6, 7, 7]
	private static let bitWidthSymbols: [UInt64] = [
		17, 11, 15, 3, 9, 7, 4, 2, 5, 6, 0, 33, 1, 65,
	]
	private static let minReps = 5
	private static let repSymbol = ANSConstants.logTabSize + 1  // index 13

	/// The alphabet size the decoder reconstructs for this distribution:
	/// one past the highest symbol actually in use. Shared by `write` and by
	/// `ANSInfoTable.build`'s caller — both must agree, since the decoder
	/// derives the same value from what `write` signals.
	static func alphabetSize(for counts: [Int]) -> Int {
		(counts.indices.filter { counts[$0] > 0 }.max() ?? -1) + 1
	}

	/// `counts` must already sum to `ANSConstants.tabSize`
	/// (`ANSHistogramNormalizer.normalize`'s output) and have one entry per
	/// token alphabet position.
	static func write(counts: [Int], writer: inout BitWriter) {
		let nonZeroSymbols = counts.indices.filter { counts[$0] > 0 }

		if nonZeroSymbols.isEmpty {
			// Unreachable given the >=100-token gate this is only ever called
			// under, but a defined, decodable encoding all the same.
			writer.write(1, 1)
			writer.write(1, 0)
			storeVarLenUint8(0, writer: &writer)
			return
		}

		if nonZeroSymbols.count <= maxSymbolsForSmallCode {
			writer.write(1, 1)  // small tree
			writer.write(1, UInt64(nonZeroSymbols.count - 1))
			for symbol in nonZeroSymbols {
				storeVarLenUint8(symbol, writer: &writer)
			}
			if nonZeroSymbols.count == 2 {
				writer.write(
					ANSConstants.logTabSize, UInt64(counts[nonZeroSymbols[0]]))
			}
			return
		}

		writer.write(1, 0)  // not small tree
		writer.write(1, 0)  // not flat

		// method = ANS_LOG_TAB_SIZE always (full precision); Elias-gamma-like
		// code for `shift = method - 1 = ANS_LOG_TAB_SIZE - 1`.
		let method = ANSConstants.logTabSize
		let upperBoundLog = floorLog2Nonzero(ANSConstants.logTabSize + 1)
		let log = floorLog2Nonzero(method)
		writer.write(log, UInt64((1 << log) - 1))
		if log != upperBoundLog { writer.write(1, 0) }
		writer.write(log, UInt64(((1 << log) - 1) & method))

		let alphabetSize = Self.alphabetSize(for: counts)
		storeVarLenUint8(alphabetSize - 3, writer: &writer)

		// omit_pos: the largest-count symbol. Its value is never transmitted;
		// the decoder infers it as the ANS_TAB_SIZE remainder.
		let omitPos = nonZeroSymbols.max(by: { counts[$0] < counts[$1] })!

		// RLE run lengths: `same[i]` holds the run length starting at `i`,
		// runs broken at omit_pos (its bit_width differs from any real
		// symbol's) and wherever the value changes.
		var same = [Int](repeating: 0, count: alphabetSize)
		var last = 0
		for i in 1...alphabetSize {
			if i == alphabetSize || i == omitPos || i == omitPos + 1
				|| (i < alphabetSize && counts[i] != counts[last])
			{
				same[last] = i - last
				last = i
			}
		}

		// Full precision throughout, so bit_width is exactly log2(count)+1 —
		// no shift-dependent truncation to compute.
		var bitWidth = [Int](repeating: 0, count: alphabetSize)
		var omitWidth = 10
		for i in 0..<alphabetSize where i != omitPos && counts[i] > 0 {
			bitWidth[i] = floorLog2Nonzero(counts[i]) + 1
			omitWidth = max(omitWidth, bitWidth[i] + (i < omitPos ? 1 : 0))
		}
		bitWidth[omitPos] = omitWidth

		var i = 0
		while i < alphabetSize {
			writer.write(bitWidthLengths[bitWidth[i]], bitWidthSymbols[bitWidth[i]])
			if same[i] >= minReps {
				writer.write(bitWidthLengths[repSymbol], bitWidthSymbols[repSymbol])
				storeVarLenUint8(same[i] - minReps, writer: &writer)
				i += same[i] - 1
			}
			i += 1
		}

		// Extra precision bits: at full precision, bitcount == logcount
		// (drop_bits == 0) for every transmitted symbol — see the file header.
		i = 0
		while i < alphabetSize {
			if bitWidth[i] > 1, i != omitPos {
				let bitcount = bitWidth[i] - 1
				writer.write(bitcount, UInt64(counts[i] - (1 << bitcount)))
			}
			if same[i] >= minReps {
				i += same[i] - 1
			}
			i += 1
		}
	}

	private static func storeVarLenUint8(_ n: Int, writer: inout BitWriter) {
		precondition(n <= 255)
		if n == 0 {
			writer.write(1, 0)
		} else {
			writer.write(1, 1)
			let nbits = floorLog2Nonzero(n)
			writer.write(3, UInt64(nbits))
			writer.write(nbits, UInt64(n) - (1 << nbits))
		}
	}
}

/// Substitute for `ANSEncodingHistogram::RebalanceHistogram` — see this
/// file's and ANSCoder.swift's headers for why. Largest-remainder rounding
/// to a distribution summing to exactly `ANSConstants.tabSize`, keeping
/// every originally-nonzero symbol at 1 or more (a real constraint:
/// `BuildAndStoreANSEncodingData`'s own sanity check requires zero/nonzero
/// to match between input and normalized counts).
enum ANSHistogramNormalizer {
	static func normalize(_ counts: [UInt32]) -> [Int] {
		let total = counts.reduce(0) { $0 + Int($1) }
		guard total > 0 else { return [Int](repeating: 0, count: counts.count) }

		var shares = [Int](repeating: 0, count: counts.count)
		var remainders: [(index: Int, remainder: Double)] = []
		var sum = 0
		for (i, c) in counts.enumerated() where c > 0 {
			let exact = Double(c) * Double(ANSConstants.tabSize) / Double(total)
			let share = max(1, Int(exact))
			shares[i] = share
			sum += share
			remainders.append((i, exact - Double(share)))
		}

		if sum > ANSConstants.tabSize {
			// Rare: many low-probability symbols each bumped to 1 overshoot
			// the total. Reduce from the largest shares first, never below 1.
			var excess = sum - ANSConstants.tabSize
			for i in shares.indices.filter({ shares[$0] > 0 }).sorted(by: {
				shares[$0] > shares[$1]
			})
			where excess > 0 {
				let take = min(shares[i] - 1, excess)
				shares[i] -= take
				excess -= take
			}
			precondition(excess == 0, "could not fit alphabet into tabSize")
		} else if sum < ANSConstants.tabSize {
			var deficit = ANSConstants.tabSize - sum
			for r in remainders.sorted(by: { $0.remainder > $1.remainder })
			where deficit > 0 {
				shares[r.index] += 1
				deficit -= 1
			}
			precondition(deficit == 0, "could not distribute remainder into tabSize")
		}
		return shares
	}
}
