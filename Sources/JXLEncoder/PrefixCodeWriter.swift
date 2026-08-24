//
//  PrefixCodeWriter.swift
//  JXLEncoder
//
//  Port of the prefix-code serialization in libjxl-tiny's
//  encoder/enc_entropy_code.cc: `WriteHuffmanTree`, `StoreHuffmanTree`,
//  `StoreSimpleHuffmanTree`, `WritePrefixCode` and `WritePrefixCodes`.
//
//  A code is transmitted as its depth table, which is itself run-length coded
//  and then Huffman coded again — hence "the Huffman tree of the Huffman tree".
//  Codes over four or fewer symbols take a simpler fixed form instead.
//

enum PrefixCodeWriter {
	static let codeLengthCodes = 18

	/// Storage order for the code-length alphabet, so the common lengths come
	/// first and trailing entries can be dropped.
	static let storageOrder: [Int] = [
		1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15,
	]

	/// Fixed code compressing the bit lengths of the code-length alphabet.
	static let lengthCodeSymbols: [UInt8] = [0, 7, 3, 2, 1, 15]
	static let lengthCodeBitLengths: [Int] = [2, 4, 3, 2, 2, 4]

	// MARK: - Depth table to run-length representation

	private struct TreeBuffer {
		var tree: [UInt8] = []
		var extraBits: [UInt8] = []

		mutating func append(_ value: UInt8, extra: UInt8 = 0) {
			tree.append(value)
			extraBits.append(extra)
		}

		mutating func reverse(from start: Int) {
			tree[start...].reverse()
			extraBits[start...].reverse()
		}
	}

	private static func writeRepetitions(
		previousValue: UInt8, value: UInt8, repetitions: Int, into buffer: inout TreeBuffer
	) {
		var repetitions = repetitions
		if previousValue != value {
			buffer.append(value)
			repetitions -= 1
		}
		if repetitions == 7 {
			buffer.append(value)
			repetitions -= 1
		}
		if repetitions < 3 {
			for _ in 0..<repetitions { buffer.append(value) }
			return
		}
		repetitions -= 3
		let start = buffer.tree.count
		while true {
			buffer.append(16, extra: UInt8(repetitions & 0x3))
			repetitions >>= 2
			if repetitions == 0 { break }
			repetitions -= 1
		}
		buffer.reverse(from: start)
	}

	private static func writeZeroRepetitions(
		repetitions: Int, into buffer: inout TreeBuffer
	) {
		var repetitions = repetitions
		if repetitions == 11 {
			buffer.append(0)
			repetitions -= 1
		}
		if repetitions < 3 {
			for _ in 0..<repetitions { buffer.append(0) }
			return
		}
		repetitions -= 3
		let start = buffer.tree.count
		while true {
			buffer.append(17, extra: UInt8(repetitions & 0x7))
			repetitions >>= 3
			if repetitions == 0 { break }
			repetitions -= 1
		}
		buffer.reverse(from: start)
	}

	/// Run-length coding only pays off on longer tables, and separately for zero
	/// and non-zero runs.
	private static func decideOverRleUse(
		depth: [UInt8], length: Int
	) -> (nonZero: Bool, zero: Bool) {
		var totalZero = 0
		var totalNonZero = 0
		var countZero = 1
		var countNonZero = 1
		var i = 0
		while i < length {
			let value = depth[i]
			var reps = 1
			var k = i + 1
			while k < length && depth[k] == value {
				reps += 1
				k += 1
			}
			if reps >= 3 && value == 0 {
				totalZero += reps
				countZero += 1
			}
			if reps >= 4 && value != 0 {
				totalNonZero += reps
				countNonZero += 1
			}
			i += reps
		}
		return (totalNonZero > countNonZero * 2, totalZero > countZero * 2)
	}

	static func huffmanTreeRepresentation(
		depth: [UInt8], length: Int
	) -> (tree: [UInt8], extraBits: [UInt8]) {
		var previousValue: UInt8 = 8

		// Trailing zeros carry no information.
		var newLength = length
		for i in 0..<length {
			if depth[length - i - 1] == 0 { newLength -= 1 } else { break }
		}

		var useRleNonZero = false
		var useRleZero = false
		if length > 50 {
			(useRleNonZero, useRleZero) = decideOverRleUse(
				depth: depth, length: newLength)
		}

		var buffer = TreeBuffer()
		var i = 0
		while i < newLength {
			let value = depth[i]
			var reps = 1
			if (value != 0 && useRleNonZero) || (value == 0 && useRleZero) {
				var k = i + 1
				while k < newLength && depth[k] == value {
					reps += 1
					k += 1
				}
			}
			if value == 0 {
				writeZeroRepetitions(repetitions: reps, into: &buffer)
			} else {
				writeRepetitions(
					previousValue: previousValue, value: value,
					repetitions: reps,
					into: &buffer)
				previousValue = value
			}
			i += reps
		}
		return (buffer.tree, buffer.extraBits)
	}

	// MARK: - Bitstream

	static func storeTreeOfTree(
		numCodes: Int, codeLengthBitDepth: [UInt8], writer: inout BitWriter
	) {
		var codesToStore = codeLengthCodes
		if numCodes > 1 {
			while codesToStore > 0 {
				if codeLengthBitDepth[storageOrder[codesToStore - 1]] != 0 { break }
				codesToStore -= 1
			}
		}
		var skipSome = 0
		if codeLengthBitDepth[storageOrder[0]] == 0
			&& codeLengthBitDepth[storageOrder[1]] == 0
		{
			skipSome = codeLengthBitDepth[storageOrder[2]] == 0 ? 3 : 2
		}
		writer.write(2, UInt64(skipSome))
		for i in skipSome..<codesToStore {
			let l = Int(codeLengthBitDepth[storageOrder[i]])
			writer.write(lengthCodeBitLengths[l], UInt64(lengthCodeSymbols[l]))
		}
	}

	static func storeHuffmanTree(depth: [UInt8], length: Int, writer: inout BitWriter) {
		let (tree, extraBits) = huffmanTreeRepresentation(depth: depth, length: length)

		var histogram = [UInt32](repeating: 0, count: codeLengthCodes)
		for entry in tree { histogram[Int(entry)] += 1 }

		var numCodes = 0
		var singleCode = 0
		for i in 0..<codeLengthCodes where histogram[i] != 0 {
			if numCodes == 0 {
				singleCode = i
				numCodes = 1
			} else {
				numCodes = 2
				break
			}
		}

		var codeLengthBitDepth = HuffmanTree.createTree(
			counts: histogram, length: codeLengthCodes, treeLimit: 5)
		let codeLengthSymbols = HuffmanTree.convertBitDepthsToSymbols(
			depth: codeLengthBitDepth, length: codeLengthCodes)

		storeTreeOfTree(
			numCodes: numCodes, codeLengthBitDepth: codeLengthBitDepth, writer: &writer)

		// With a single code the decoder infers its length, so it is not sent.
		if numCodes == 1 { codeLengthBitDepth[singleCode] = 0 }

		for i in 0..<tree.count {
			let index = Int(tree[i])
			writer.write(
				Int(codeLengthBitDepth[index]), UInt64(codeLengthSymbols[index]))
			switch index {
			case 16: writer.write(2, UInt64(extraBits[i]))
			case 17: writer.write(3, UInt64(extraBits[i]))
			default: break
			}
		}
	}

	static func storeSimpleHuffmanTree(
		depths: [UInt8], symbols: [Int], count: Int, maxBits: Int,
		writer: inout BitWriter
	) {
		writer.write(2, 1)  // simple code
		writer.write(2, UInt64(count - 1))

		// Insertion order by depth, matching the reference's selection sort.
		var symbols = symbols
		for i in 0..<count {
			for j in (i + 1)..<count where depths[symbols[j]] < depths[symbols[i]] {
				symbols.swapAt(i, j)
			}
		}

		for i in 0..<count { writer.write(maxBits, UInt64(symbols[i])) }
		if count == 4 {
			writer.write(1, depths[symbols[0]] == 1 ? 1 : 0)  // tree-select
		}
	}

	static func writePrefixCode(_ code: PrefixCode, writer: inout BitWriter) {
		var count = 0
		var firstFour = [Int](repeating: 0, count: 4)
		var length = 0
		for i in 0..<StaticEntropyCodes.alphabetSize where code.depths[i] != 0 {
			if count < 4 { firstFour[count] = i }
			count += 1
			length = i + 1
		}

		var maxBitsCounter = length - 1
		var maxBits = 0
		while maxBitsCounter != 0 {
			maxBitsCounter >>= 1
			maxBits += 1
		}

		if count <= 1 {
			writer.write(4, 1)
			writer.write(maxBits, UInt64(firstFour[0]))
			return
		}
		if count <= 4 {
			storeSimpleHuffmanTree(
				depths: code.depths, symbols: firstFour, count: count,
				maxBits: maxBits, writer: &writer)
		} else {
			storeHuffmanTree(depth: code.depths, length: length, writer: &writer)
		}
	}

	static func storeVarLenUInt16(_ n: Int, writer: inout BitWriter) {
		if n == 0 {
			writer.write(1, 0)
			return
		}
		writer.write(1, 1)
		let bitCount = 31 - UInt32(n).leadingZeroBitCount
		writer.write(4, UInt64(bitCount))
		writer.write(bitCount, UInt64(n) - (UInt64(1) << UInt64(bitCount)))
	}

	/// The hybrid-uint configuration `UintCoder.encode` matches, written once
	/// per histogram regardless of which serializer follows — real libjxl's
	/// `EncodeUintConfigs`. Both the prefix and ANS paths share it, since
	/// both share `UintCoder.encode` itself.
	static func writeUintConfigs(count: Int, writer: inout BitWriter) {
		for _ in 0..<count {
			writer.write(4, 4)  // split_exponent
			writer.write(3, 2)  // msb_in_token
			writer.write(2, 0)  // lsb_in_token
		}
	}

	/// Writes a set of prefix codes: the hybrid-uint configuration for each,
	/// then their alphabet sizes, then the codes themselves. The caller
	/// writes `use_prefix_code` — this only ever runs for the prefix path.
	static func writePrefixCodes(_ codes: [PrefixCode], writer: inout BitWriter) {
		writeUintConfigs(count: codes.count, writer: &writer)
		func symbolCount(_ code: PrefixCode) -> Int {
			var count = 1
			for i in 0..<StaticEntropyCodes.alphabetSize where code.depths[i] != 0 {
				count = i + 1
			}
			return count
		}
		for code in codes {
			storeVarLenUInt16(symbolCount(code) - 1, writer: &writer)
		}
		for code in codes where symbolCount(code) > 1 {
			writePrefixCode(code, writer: &writer)
		}
	}
}
