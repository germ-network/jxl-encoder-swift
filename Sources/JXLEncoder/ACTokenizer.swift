//
//  ACTokenizer.swift
//  JXLEncoder
//
//  Port of the AC tokenization in libjxl-tiny's encoder/enc_group.cc: turns
//  quantized coefficients into entropy-coded tokens.
//
//  Each block emits a count of non-zero coefficients, then the coefficients
//  themselves in scan order, stopping as soon as the remaining count reaches
//  zero. The decoder tracks the same count, so trailing zeros cost nothing.
//

public enum ACTokenizer {
	/// Zig-zag scan order for an 8x8 block, from `kCoeffOrders`.
	public static let coeffOrder: [Int] = [
		0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4,
		5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14,
		21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30,
		37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54,
		47, 55, 62, 63,
	]

	/// `AcStrategy::StrategyCode()` for DCT8, the only strategy this port emits.
	public static let dct8StrategyCode = 0

	/// Channels are coded Y, X, B — Y first because the others are
	/// decorrelated against it.
	public static let channelOrder = [1, 0, 2]

	/// Non-zero coefficients in a block, excluding DC.
	public static func nonZeroCountExcludingDC(_ block: ArraySlice<Int32>) -> Int {
		let base = block.startIndex
		var count = 0
		for i in 1..<DCT.blockSize where block[base + i] != 0 { count += 1 }
		return count
	}

	/// Predicts a block's non-zero count from its already-coded neighbours.
	/// `top` is nil on the first block row of a group, which is what keeps
	/// groups independently decodable.
	public static func predictFromTopAndLeft(
		top: ArraySlice<UInt8>?, row: ArraySlice<UInt8>, x: Int, defaultValue: Int
	) -> Int {
		guard x > 0 else {
			guard let top else { return defaultValue }
			return Int(top[top.startIndex])
		}
		let left = Int(row[row.startIndex + x - 1])
		guard let top else { return left }
		return (Int(top[top.startIndex + x]) + left + 1) / 2
	}

	/// Emits the tokens for one block of one channel.
	///
	/// `nonZeroRow` is this block row's running non-zero counts for the channel,
	/// updated in place so later blocks can predict from it.
	public static func writeBlock(
		quantized: ArraySlice<Int32>,
		channel: Int,
		blockX: Int,
		nonZeroRow: inout [UInt8],
		nonZeroRowAbove: [UInt8]?,
		code: EntropyCode,
		writer: inout BitWriter
	) {
		var nonZeros = nonZeroCountExcludingDC(quantized)
		nonZeroRow[blockX] = UInt8(nonZeros)

		let predicted = predictFromTopAndLeft(
			top: nonZeroRowAbove?[...], row: nonZeroRow[...], x: blockX,
			defaultValue: 32)
		let blockContext = ACContext.blockContext(
			channel: channel, acStrategyCode: dct8StrategyCode)
		let nonZeroContext = ACContext.nonZeroContext(
			nonZeros: predicted, blockContext: blockContext)
		let histogramOffset = ACContext.zeroDensityContextsOffset(
			blockContext: blockContext)

		writer.write(
			token: Token(context: UInt32(nonZeroContext), value: UInt32(nonZeros)),
			code: code)

		let base = quantized.startIndex
		// Coefficient 0 is DC, carried by the separate DC image.
		var previous = nonZeros > DCT.blockSize / 16 ? 0 : 1
		var k = 1
		while k < DCT.blockSize && nonZeros != 0 {
			let coefficient = quantized[base + coeffOrder[k]]
			let context =
				histogramOffset
				+ ACContext.zeroDensityContext(
					nonzerosLeft: nonZeros, k: k,
					coveredBlocks: 1, log2CoveredBlocks: 0, previous: previous)
			writer.write(
				token: Token(
					context: UInt32(context), value: packSigned(coefficient)),
				code: code)
			previous = coefficient != 0 ? 1 : 0
			nonZeros -= previous
			k += 1
		}
	}
}
