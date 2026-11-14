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

import Foundation

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

	static func write(counts: [Int], writer: inout BitWriter) {
		let alphabetSize = Self.alphabetSize(for: counts)
		let nonzero = counts.indices.filter { counts[$0] > 0 }
		let omit = nonzero.max(by: { counts[$0] < counts[$1] }) ?? -1
		write(
			counts: counts, alphabetSize: alphabetSize,
			method: ANSConstants.logTabSize, omitPosition: omit,
			shift: ANSConstants.logTabSize - 1, writer: &writer)
	}

	static func write(
		counts: [Int], alphabetSize: Int, method: Int, omitPosition: Int,
		shift: Int, writer: inout BitWriter
	) {
		let nonZeroSymbols = counts.indices.filter { counts[$0] > 0 }

		if nonZeroSymbols.isEmpty {
			// Unreachable given the >=100-token gate this is only ever called
			// under, but a defined, decodable encoding all the same.
			writer.write(1, 1)
			writer.write(1, 0)
			storeVarLenUint8(0, writer: &writer)
			return
		}

		if method != 0 && nonZeroSymbols.count <= maxSymbolsForSmallCode {
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

		// Elias-gamma-like code for the selected precision method.
		let upperBoundLog = floorLog2Nonzero(ANSConstants.logTabSize + 1)
		let log = floorLog2Nonzero(method)
		writer.write(log, UInt64((1 << log) - 1))
		if log != upperBoundLog { writer.write(1, 0) }
		writer.write(log, UInt64(((1 << log) - 1) & method))

		storeVarLenUint8(alphabetSize - 3, writer: &writer)

		// omit_pos: the largest-count symbol. Its value is never transmitted;
		// the decoder infers it as the ANS_TAB_SIZE remainder.
		let omitPos = omitPosition

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

		if shift != 0 {
			i = 0
			while i < alphabetSize {
				if bitWidth[i] > 1, i != omitPos {
					let logCount = bitWidth[i] - 1
					let bitCount = ANSFixedShift.precision(
						logCount, shift: shift)
					let dropBits = logCount - bitCount
					writer.write(
						bitCount,
						UInt64((counts[i] >> dropBits) - (1 << bitCount)))
				}
				if same[i] >= minReps { i += same[i] - 1 }
				i += 1
			}
		}
	}

	static func write(histogram: ANSEncodingHistogram, writer: inout BitWriter) {
		write(
			counts: histogram.normalizedCounts,
			alphabetSize: histogram.alphabetSize,
			method: histogram.method,
			omitPosition: histogram.omitPosition,
			shift: max(0, histogram.method - 1),
			writer: &writer)
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

private struct ANSAllowedCount {
	let count: Int
	let stepLog: Int
	let deltaLog: Int32
}

private struct ANSEntropyDelta {
	let frequency: Int64
	let bin: Int
	var countIndex: Int
}

private enum ANSFixedShift {
	static let allowedTables = (0..<ANSConstants.logTabSize).map(buildTable)
	static let log2Table: [UInt32] = (0...ANSConstants.tabSize).map { value in
		guard value > 0 else { return 0 }
		let scaled = Foundation.log2(Double(value)) / Double(ANSConstants.logTabSize)
		return UInt32((scaled * Double(1 << 31)).rounded(.toNearestOrAwayFromZero))
	}

	static func precision(_ logCount: Int, shift: Int) -> Int {
		max(0, min(logCount, shift - ((ANSConstants.logTabSize - logCount) >> 1)))
	}

	static func table(_ shift: Int) -> (counts: [ANSAllowedCount], index: [Int]) {
		allowedTables[shift]
	}

	private static func buildTable(_ shift: Int) -> (counts: [ANSAllowedCount], index: [Int]) {
		var counts: [ANSAllowedCount] = []
		var index = [Int](repeating: 0, count: ANSConstants.tabSize)
		var slotByCount: [Int: Int] = [:]
		var previous = -1
		for raw in stride(from: ANSConstants.tabSize - 1, through: 0, by: -1) {
			let bits = raw == 0 ? 0 : floorLog2Nonzero(raw)
			let dropBits = bits - precision(bits, shift: shift)
			let count = raw & ~((1 << dropBits) - 1)
			guard count != previous else { continue }
			previous = count
			let stepLog: Int
			let deltaLog: Int32
			if count == 0 {
				stepLog = 0
				deltaLog = Int32.max
			} else if let prior = counts.last {
				stepLog = floorLog2Nonzero(prior.count - count)
				let delta = Foundation.log2(Double(prior.count) / Double(count))
				let scaled =
					delta / Double(ANSConstants.logTabSize) * Double(1 << 31)
				deltaLog = Int32(scaled.rounded(.toNearestOrAwayFromZero))
			} else {
				stepLog = 0
				deltaLog = 0
			}
			counts.append(
				ANSAllowedCount(count: count, stepLog: stepLog, deltaLog: deltaLog))
			slotByCount[count] = counts.count - 1
		}
		for value in 0..<ANSConstants.tabSize {
			let bits = value == 0 ? 0 : floorLog2Nonzero(value)
			let dropBits = bits - precision(bits, shift: shift)
			let allowed = value & ~((1 << dropBits) - 1)
			index[value] = slotByCount[allowed]!
		}
		return (counts, index)
	}
}

enum ANSHistogramStrategy: Sendable {
	case precise
	case approximate
	case fast
}

struct ANSEncodingHistogram: Sendable {
	let normalizedCounts: [Int]
	let alphabetSize: Int
	let method: Int
	let omitPosition: Int
	let headerBits: Int
	let dataBits: Float
	let cost: Float

	private init(
		normalizedCounts: [Int], alphabetSize: Int, method: Int, omitPosition: Int,
		headerBits: Int, dataBits: Float, cost: Float
	) {
		self.normalizedCounts = normalizedCounts
		self.alphabetSize = alphabetSize
		self.method = method
		self.omitPosition = omitPosition
		self.headerBits = headerBits
		self.dataBits = dataBits
		self.cost = cost
	}

	static func rebalanced(counts: [UInt32], shift: Int) -> Self {
		precondition((0..<ANSConstants.logTabSize).contains(shift))
		precondition(counts.count <= 256)
		let total = counts.reduce(Int64(0)) { $0 + Int64($1) }
		precondition(total > 0 && total <= Int64(Int32.max))
		let alphabetSize = counts.lastIndex(where: { $0 > 0 }).map { $0 + 1 } ?? 0
		let symbols = counts.prefix(alphabetSize).filter { $0 > 0 }.count
		precondition(symbols >= 2)

		let table = ANSFixedShift.table(shift)
		let norm = Double(ANSConstants.tabSize) / Double(total)
		var normalized = [Int](repeating: 0, count: counts.count)
		var bins: [ANSEntropyDelta] = []
		var balancingPosition = 0
		var maximumFrequency: Int64 = 0
		var rest = ANSConstants.tabSize
		for index in 0..<alphabetSize {
			let frequency = Int64(counts[index])
			if frequency > maximumFrequency {
				balancingPosition = index
				maximumFrequency = frequency
			}
			let target = Double(frequency) * norm
			var count = min(
				ANSConstants.tabSize - 1,
				max(
					Int((target).rounded(.toNearestOrAwayFromZero)),
					frequency > 0 ? 1 : 0))
			let bits = count == 0 ? 0 : floorLog2Nonzero(count)
			let dropBits = bits - ANSFixedShift.precision(bits, shift: shift)
			let stepLog = dropBits
			let increment = 1 << stepLog
			count &= ~(increment - 1)
			normalized[index] = count
			rest -= count
			if target > 1 {
				bins.append(
					ANSEntropyDelta(
						frequency: frequency, bin: index,
						countIndex: table.index[count]))
			}
		}
		if let balanceIndex = bins.firstIndex(where: { $0.bin == balancingPosition }) {
			bins.remove(at: balanceIndex)
		}
		rest += normalized[balancingPosition]

		if !bins.isEmpty {
			let maxLog = table.counts[1].stepLog
			while true {
				var balanceInc = [Int64](repeating: 0, count: maxLog + 1)
				var balanceDec = [Int64](repeating: 0, count: maxLog + 1)
				for log in 0...maxLog {
					let delta = 1 << log
					if rest >= ANSConstants.tabSize {
						continue
					} else if rest > 1 {
						balanceInc[log] =
							rest > delta
							? maximumFrequency
								* Int64(
									ANSFixedShift.log2Table[
										rest]
										- ANSFixedShift
										.log2Table[
											rest - delta
										])
							: Int64.max
						balanceDec[log] =
							rest + delta < ANSConstants.tabSize
							? maximumFrequency
								* Int64(
									ANSFixedShift.log2Table[
										rest + delta]
										- ANSFixedShift
										.log2Table[rest])
							: 0
					} else {
						balanceInc[log] = Int64.max
						balanceDec[log] = Int64.max
					}
				}
				func incDelta(_ bin: ANSEntropyDelta) -> Int64 {
					Int64(bin.frequency)
						* Int64(table.counts[bin.countIndex].deltaLog)
						- balanceInc[table.counts[bin.countIndex].stepLog]
				}
				func decDelta(_ bin: ANSEntropyDelta) -> Int64 {
					Int64(bin.frequency)
						* Int64(table.counts[bin.countIndex + 1].deltaLog)
						- balanceDec[
							table.counts[bin.countIndex + 1].stepLog]
				}
				func incRank(_ bin: ANSEntropyDelta) -> Int64 {
					incDelta(bin) >> table.counts[bin.countIndex].stepLog
				}
				func decRank(_ bin: ANSEntropyDelta) -> Int64 {
					decDelta(bin) >> table.counts[bin.countIndex + 1].stepLog
				}
				var bestInc = 0
				for index in bins.indices.dropFirst()
				where incRank(bins[index]) > incRank(bins[bestInc]) {
					bestInc = index
				}
				if incDelta(bins[bestInc]) > 0 {
					let stepLog = table.counts[bins[bestInc].countIndex].stepLog
					bins[bestInc].countIndex -= 1
					rest -= 1 << stepLog
					continue
				}
				var bestDec = 0
				for index in bins.indices.dropFirst()
				where decRank(bins[index]) < decRank(bins[bestDec]) {
					bestDec = index
				}
				if decDelta(bins[bestDec]) >= 0 { break }
				bins[bestDec].countIndex += 1
				rest += 1 << table.counts[bins[bestDec].countIndex].stepLog
			}
			for bin in bins { normalized[bin.bin] = table.counts[bin.countIndex].count }
			for index in 0..<balancingPosition
			where normalized[index] >= ANSConstants.tabSize / 2 {
				let displaced = normalized[index]
				normalized[balancingPosition] = displaced
				balancingPosition = index
				break
			}
		}
		normalized[balancingPosition] = rest
		precondition(rest > 0)

		var writer = BitWriter()
		let method = shift + 1
		let omit = balancingPosition
		ANSHistogramWriter.write(
			counts: normalized, alphabetSize: alphabetSize,
			method: method, omitPosition: omit, shift: shift, writer: &writer)
		let dataBits = estimateDataBits(
			counts: counts, normalized: normalized, alphabetSize: alphabetSize)
		let headerBits = writer.bitsWritten
		let cost = Float(headerBits) + dataBits
		return Self(
			normalizedCounts: normalized, alphabetSize: alphabetSize,
			method: method, omitPosition: omit, headerBits: headerBits,
			dataBits: dataBits, cost: cost)
	}

	static func computeBest(counts: [UInt32], strategy: ANSHistogramStrategy) -> Self {
		fatalError("ANS precision selection is not implemented")
	}

	func write(to writer: inout BitWriter) {
		ANSHistogramWriter.write(histogram: self, writer: &writer)
	}

	private static func estimateDataBits(
		counts: [UInt32], normalized: [Int], alphabetSize: Int
	) -> Float {
		var sum: Int64 = 0
		for index in 0..<alphabetSize {
			sum +=
				Int64(counts[index])
				* Int64(ANSFixedShift.log2Table[normalized[index]])
		}
		let scaled = Float(sum) * Float(1.0 / Double(1 << 31))
		return (Float(counts.reduce(Int64(0)) { $0 + Int64($1) }) - scaled)
			* Float(ANSConstants.logTabSize)
	}
}
