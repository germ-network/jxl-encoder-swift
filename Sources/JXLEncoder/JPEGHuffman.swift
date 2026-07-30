//
//  JPEGHuffman.swift
//  JXLEncoder
//
//  Huffman tables and the entropy-coded bit reader for baseline JPEG —
//  ISO/IEC 10918-1 Annex F.
//

/// Canonical Huffman decoder built from a DHT segment's per-length code counts
/// and value list.
struct JPEGHuffmanTable {
	/// First code of each length, indexed 1...16.
	private let minCode: [Int32]
	/// Last code of each length, `-1` when the length carries no codes. Held as
	/// signed so an unused length can never match a code.
	private let maxCode: [Int32]
	private let valueOffset: [Int]
	private let values: [UInt8]

	/// Codes of 8 bits or fewer, keyed by the next 8 bits of the stream, so the
	/// common case skips the per-length walk. A zero length means the prefix
	/// belongs to a longer code.
	private let fastLength: [UInt8]
	private let fastValue: [UInt8]

	/// Fails on an over-subscribed table — one whose codes cannot fit the code
	/// space — or on a value count that disagrees with the length counts.
	init?(counts: [Int], values: [UInt8]) {
		guard counts.count == 16, values.count == counts.reduce(0, +) else {
			return nil
		}

		var minCode = [Int32](repeating: 0, count: 17)
		var maxCode = [Int32](repeating: -1, count: 17)
		var valueOffset = [Int](repeating: 0, count: 17)
		var fastLength = [UInt8](repeating: 0, count: 256)
		var fastValue = [UInt8](repeating: 0, count: 256)

		var code: Int32 = 0
		var valueIndex = 0
		for length in 1...16 {
			let count = counts[length - 1]
			minCode[length] = code
			valueOffset[length] = valueIndex
			if count > 0 {
				maxCode[length] = code + Int32(count) - 1
				if length <= 8 {
					let fill = 1 << (8 - length)
					for i in 0..<count {
						let prefix = Int(code + Int32(i)) << (8 - length)
						let value = values[valueIndex + i]
						for j in 0..<fill {
							fastLength[prefix + j] = UInt8(length)
							fastValue[prefix + j] = value
						}
					}
				}
			}
			code += Int32(count)
			valueIndex += count
			guard code <= 1 << length else { return nil }
			code <<= 1
		}

		self.minCode = minCode
		self.maxCode = maxCode
		self.valueOffset = valueOffset
		self.values = values
		self.fastLength = fastLength
		self.fastValue = fastValue
	}

	func decode(_ reader: inout JPEGBitReader) throws -> UInt8 {
		let prefix = Int(reader.peek(8))
		let length = fastLength[prefix]
		if length != 0 {
			reader.skip(Int(length))
			return fastValue[prefix]
		}

		var code = Int32(prefix)
		reader.skip(8)
		for length in 9...16 {
			code = (code << 1) | Int32(reader.read(1))
			if code <= maxCode[length] {
				return values[valueOffset[length] + Int(code - minCode[length])]
			}
		}
		throw JPEGParseError.invalidHuffmanCode
	}
}

/// Bit-level reader over entropy-coded data.
///
/// Entropy data carries `FF 00` wherever the compressed bits produce a literal
/// `FF`; any other `FF xx` is the marker that ends the segment. Once the reader
/// reaches a marker — or the end of the input — it hands out zero bits and
/// counts them, so a caller decoding past the end sees `paddedBytes` grow
/// instead of reading whatever follows the marker.
struct JPEGBitReader {
	private let data: [UInt8]
	/// Next unread byte. After `reachedMarker` this is the marker's `FF`.
	private(set) var index: Int
	private var buffer: UInt32 = 0
	private var bitCount = 0
	private(set) var paddedBytes = 0
	private(set) var reachedMarker = false

	init(data: [UInt8], index: Int) {
		self.data = data
		self.index = index
	}

	/// Resumes at `index` after a restart marker: the bit buffer does not carry
	/// across the marker, and neither does the padding budget.
	mutating func restart(at index: Int) {
		self.index = index
		buffer = 0
		bitCount = 0
		paddedBytes = 0
		reachedMarker = false
	}

	/// `n` must be at most 16, which keeps `bitCount` under 32 bits.
	mutating func peek(_ n: Int) -> UInt32 {
		fill(n)
		return (buffer >> (bitCount - n)) & ((1 << n) - 1)
	}

	mutating func skip(_ n: Int) {
		fill(n)
		bitCount -= n
	}

	mutating func read(_ n: Int) -> UInt32 {
		let value = peek(n)
		bitCount -= n
		return value
	}

	private mutating func fill(_ n: Int) {
		while bitCount < n {
			buffer = (buffer << 8) | UInt32(nextByte())
			bitCount += 8
		}
	}

	private mutating func nextByte() -> UInt8 {
		guard !reachedMarker, index < data.count else {
			paddedBytes += 1
			return 0
		}
		let byte = data[index]
		guard byte == 0xFF else {
			index += 1
			return byte
		}
		if index + 1 < data.count, data[index + 1] == 0x00 {
			index += 2
			return 0xFF
		}
		reachedMarker = true
		paddedBytes += 1
		return 0
	}
}
