//
//  JPEGHuffman.swift
//  JXLEncoder
//
//  Huffman tables and the entropy-coded bit reader for baseline JPEG —
//  ISO/IEC 10918-1 Annex F.
//

/// Two-level lookup built from a DHT segment's per-length code counts.
struct JPEGHuffmanTable {
	static let lutSize = 1024
	private static let rootBits = 8

	struct Entry: Equatable {
		var bits: UInt8
		var value: UInt16
	}

	private(set) var entries: [Entry]

	init?(counts: [Int], values: [UInt8]) {
		guard counts.count == 16, counts.allSatisfy({ (0...255).contains($0) }),
			values.count == counts.reduce(0, +), values.count <= 256
		else {
			return nil
		}

		var counts = counts
		var maxDepth = 1
		var space = 1 << 16
		var total = 0
		for length in 1...16 {
			let count = counts[length - 1]
			if count > 0 { maxDepth = length }
			total += count
			space -= count * (1 << (16 - length))
		}
		counts[maxDepth - 1] += 1
		space -= 1 << (16 - maxDepth)
		guard space >= 0 else { return nil }

		var symbols = values.map(UInt16.init)
		symbols.append(256)
		var table = [Entry](repeating: Entry(bits: 0, value: 65535), count: Self.lutSize)
		if total + 1 == 1 {
			for key in 0..<(1 << Self.rootBits) {
				table[key] = Entry(bits: 0, value: symbols[0])
			}
			entries = table
			return
		}

		var remaining = [0] + counts
		var key = 0
		var symbolIndex = 0
		for length in 1...Self.rootBits {
			while remaining[length] > 0 {
				let entry = Entry(bits: UInt8(length), value: symbols[symbolIndex])
				symbolIndex += 1
				let repetitions = 1 << (Self.rootBits - length)
				for index in key..<(key + repetitions) { table[index] = entry }
				key += repetitions
				remaining[length] -= 1
			}
		}

		var tableBase = 1 << Self.rootBits
		var tableBits = Self.rootBits
		var tableSize = 0
		var low = 0
		for length in (Self.rootBits + 1)...16 {
			while remaining[length] > 0 {
				if low >= tableSize {
					tableBase += tableSize
					tableBits = Self.nextTableBitSize(remaining, length: length)
					tableSize = 1 << tableBits
					low = 0
					table[key] = Entry(
						bits: UInt8(tableBits + Self.rootBits),
						value: UInt16(tableBase - key))
					key += 1
				}
				let leafBits = length - Self.rootBits
				let entry = Entry(
					bits: UInt8(leafBits), value: symbols[symbolIndex])
				symbolIndex += 1
				let repetitions = 1 << (tableBits - leafBits)
				for index in low..<(low + repetitions) {
					table[tableBase + index] = entry
				}
				low += repetitions
				remaining[length] -= 1
			}
		}
		entries = table
	}

	func decode(_ reader: inout JPEGBitReader) throws -> UInt8 {
		let rootIndex = Int(reader.peek(Self.rootBits))
		var entry = entries[rootIndex]
		guard entry.value != 65535 else { throw JPEGParseError.invalidHuffmanCode }
		if entry.bits > Self.rootBits {
			let subtableBits = Int(entry.bits) - Self.rootBits
			let subtableOffset = rootIndex + Int(entry.value)
			reader.skip(Self.rootBits)
			entry = entries[subtableOffset + Int(reader.peek(subtableBits))]
		}
		guard entry.value < 256 else { throw JPEGParseError.invalidHuffmanCode }
		reader.skip(Int(entry.bits))
		return UInt8(entry.value)
	}

	private static func nextTableBitSize(_ counts: [Int], length: Int) -> Int {
		var remaining = 1 << (length - rootBits)
		var length = length
		while length < 16 {
			remaining -= counts[length]
			if remaining <= 0 { break }
			length += 1
			remaining <<= 1
		}
		return length - rootBits
	}
}

/// Bit-level reader over entropy-coded data.
struct JPEGBitReader {
	private let data: [UInt8]
	private(set) var index: Int
	private var buffer: UInt32 = 0
	private var bitCount = 0
	private var markerBoundary: Int

	init(data: [UInt8], index: Int) {
		self.data = data
		self.index = index
		markerBoundary = max(data.count - 2, 0)
	}

	/// Resumes at `index` after a restart marker: the bit buffer does not carry
	/// across the marker.
	mutating func restart(at index: Int) {
		self.index = index
		buffer = 0
		bitCount = 0
		markerBoundary = max(data.count - 2, 0)
	}

	mutating func finish() throws -> Int {
		var unusedBytes = bitCount >> 3
		while unusedBytes > 0 {
			index -= 1
			if index < markerBoundary, index > 0,
				data[index] == 0, data[index - 1] == 0xFF
			{
				index -= 1
			}
			unusedBytes -= 1
		}
		guard index <= markerBoundary else {
			throw JPEGParseError.truncatedEntropyData
		}
		return index
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
		guard index < markerBoundary, index < data.count else {
			index += 1
			return 0
		}
		let byte = data[index]
		index += 1
		guard byte == 0xFF else { return byte }
		if index < data.count, data[index] == 0x00 {
			index += 1
			return 0xFF
		}
		markerBoundary = index - 1
		return 0xFF
	}
}
