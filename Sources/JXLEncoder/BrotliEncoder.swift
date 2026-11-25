//
//  BrotliEncoder.swift
//  JXLEncoder
//
//  RFC 7932 Brotli compression for the JPEG reconstruction box. libjxl selects
//  quality 5 there at effort 4; this encoder does not reproduce libbrotli's
//  output. It
//  writes one block type and one prefix tree per category, with no block
//  splitting, literal context modeling or static-dictionary references, so its
//  compression ratio is lower than libbrotli's at that quality. Every stream it
//  writes is RFC 7932-conformant and decodes back to the input byte for byte.
//

/// Compresses bytes into a complete RFC 7932 Brotli stream.
enum BrotliEncoder {
	/// RFC 7932 §9.1: "window size = (1 << WBITS) - 16".
	static let windowBits = 22

	/// Largest backward distance a copy may use under ``windowBits``.
	static let windowSize = (1 << windowBits) - 16

	/// Uncompressed bytes per meta-block. At this size MLEN - 1 always fits the
	/// four-nibble form of RFC 7932 §9.2.
	static let maxMetaBlockLength = 1 << 16

	/// A stream that decodes to exactly `input`, including the empty input.
	static func compress(_ input: [UInt8]) -> [UInt8] {
		var writer = BitWriter()
		BrotliMetaBlock.writeStreamHeader(to: &writer)
		var finder = BrotliMatchFinder(input: input, windowSize: windowSize)
		var ring = BrotliDistanceRing()
		var start = 0
		while start < input.count {
			let end = min(start + maxMetaBlockLength, input.count)
			let commands = finder.commands(for: start..<end)
			BrotliMetaBlock.writeSmaller(
				input: input, range: start..<end, commands: commands,
				isLast: end == input.count, ring: &ring, to: &writer)
			start = end
		}
		if input.isEmpty { BrotliMetaBlock.writeEmptyLast(to: &writer) }
		writer.zeroPadToByte()
		return writer.take()
	}
}

/// One LZ77 command: `insertLength` literals, then `copyLength` bytes copied
/// from `distance` bytes back.
struct BrotliCommand: Equatable, Sendable {
	var insertLength: Int
	/// Zero only for a meta-block's trailing insert-only command, whose copy
	/// RFC 7932 §9.3 says "is ignored and will not produce any uncompressed output".
	var copyLength: Int
	/// Ignored when `copyLength` is zero.
	var distance: Int
}

/// Finds backward references in one input. Its hash chains span the whole
/// input, so copies may reach into earlier meta-blocks within the window.
///
/// The search parameters are this encoder's choices, not RFC 7932 requirements:
/// 4-byte hashing, a bounded chain and lazy matching that keeps deferring
/// while the next position gains enough, in the spirit of a mid-quality
/// libbrotli hasher.
struct BrotliMatchFinder {
	private static let hashBits = 15
	private static let minimumMatch = 4
	private static let maximumChainLength = 16
	/// A match at the next position must beat the current one by this much to
	/// defer it; the deferred byte costs a literal.
	private static let lazyGain = 2

	private let input: [UInt8]
	private let windowSize: Int
	private var heads = [Int32](repeating: -1, count: 1 << hashBits)
	private var previous: [Int32]
	private var nextToHash = 0

	init(input: [UInt8], windowSize: Int) {
		precondition(input.count < Int(Int32.max), "input too large for 32-bit chains")
		self.input = input
		self.windowSize = windowSize
		previous = [Int32](repeating: -1, count: input.count)
	}

	private func hash(at position: Int) -> Int {
		let word =
			UInt32(input[position]) | UInt32(input[position + 1]) << 8
			| UInt32(input[position + 2]) << 16 | UInt32(input[position + 3]) << 24
		return Int((word &* 0x1E35_A7BD) >> UInt32(32 - Self.hashBits))
	}

	private mutating func hashPositions(before limit: Int) {
		while nextToHash < limit {
			if nextToHash + Self.minimumMatch <= input.count {
				let slot = hash(at: nextToHash)
				previous[nextToHash] = heads[slot]
				heads[slot] = Int32(nextToHash)
			}
			nextToHash += 1
		}
	}

	private func matchLength(_ position: Int, _ distance: Int, limit: Int) -> Int {
		var length = 0
		while position + length < limit
			&& input[position + length] == input[position + length - distance]
		{
			length += 1
		}
		return length
	}

	/// The longest match at `position` that ends by `limit`, or length 0.
	private func bestMatch(at position: Int, limit: Int) -> (length: Int, distance: Int) {
		guard position + Self.minimumMatch <= limit else { return (0, 0) }
		var best = (length: 0, distance: 0)
		var candidate = Int(heads[hash(at: position)])
		var steps = 0
		while candidate >= 0 && steps < Self.maximumChainLength {
			let distance = position - candidate
			if distance > windowSize { break }
			let length = matchLength(position, distance, limit: limit)
			if length > best.length { best = (length, distance) }
			candidate = Int(previous[candidate])
			steps += 1
		}
		return best.length >= Self.minimumMatch ? best : (0, 0)
	}

	/// Commands covering exactly `range`, whose copies never reach before the
	/// start of the input or further back than the window.
	mutating func commands(for range: Range<Int>) -> [BrotliCommand] {
		var commands = [BrotliCommand]()
		var position = range.lowerBound
		var literalStart = position
		while position < range.upperBound {
			hashPositions(before: position)
			var match = bestMatch(at: position, limit: range.upperBound)
			guard match.length > 0 else {
				position += 1
				continue
			}
			while position + 1 < range.upperBound {
				hashPositions(before: position + 1)
				let next = bestMatch(at: position + 1, limit: range.upperBound)
				guard next.length >= match.length + Self.lazyGain else { break }
				position += 1
				match = next
			}
			commands.append(
				BrotliCommand(
					insertLength: position - literalStart,
					copyLength: match.length,
					distance: match.distance))
			position += match.length
			literalStart = position
		}
		if literalStart < range.upperBound {
			commands.append(
				BrotliCommand(
					insertLength: range.upperBound - literalStart,
					copyLength: 0, distance: 0))
		}
		return commands
	}
}

/// A prefix-coded symbol and the fixed-width extra bits that follow it.
struct BrotliCodedValue: Equatable, Sendable {
	var code: Int
	var extraBitCount: Int
	var extraBits: Int
}

/// The insert-and-copy length alphabet of RFC 7932 §5.
enum BrotliLengthCodes {
	/// Per code, the smallest length and the extra-bit count, from the §5 tables.
	private static let insertBase = [
		0, 1, 2, 3, 4, 5, 6, 8, 10, 14, 18, 26, 34, 50, 66, 98,
		130, 194, 322, 578, 1090, 2114, 6210, 22594,
	]
	private static let insertExtraBits = [
		0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5,
		6, 7, 8, 9, 10, 12, 14, 24,
	]
	private static let copyBase = [
		2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 18, 22, 30, 38, 54,
		70, 102, 134, 198, 326, 582, 1094, 2118,
	]
	private static let copyExtraBits = [
		0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4,
		5, 5, 6, 7, 8, 9, 10, 24,
	]

	private static func codedValue(
		length: Int, base: [Int], extraBits: [Int]
	) -> BrotliCodedValue {
		var code = base.count - 1
		while base[code] > length { code -= 1 }
		return BrotliCodedValue(
			code: code, extraBitCount: extraBits[code], extraBits: length - base[code])
	}

	static func insertCode(forLength length: Int) -> BrotliCodedValue {
		precondition(length >= 0, "insert length \(length) is negative")
		return codedValue(length: length, base: insertBase, extraBits: insertExtraBits)
	}

	/// `length` is at least 2, the shortest copy §5 can express.
	static func copyCode(forLength length: Int) -> BrotliCodedValue {
		precondition(length >= 2, "copy length \(length) is below 2")
		return codedValue(length: length, base: copyBase, extraBits: copyExtraBits)
	}

	/// The insert-and-copy symbol. With `reusesLastDistance`, it is one of the
	/// codes 0...127, after which §5 says "the distance code of the command is
	/// set to zero" and no distance is written. Those codes exist only for
	/// insert codes 0...7 and copy codes 0...15, so a caller reusing the last
	/// distance outside that range writes distance symbol 0 explicitly instead.
	static func insertAndCopySymbol(
		insertCode: Int, copyCode: Int, reusesLastDistance: Bool
	) -> Int {
		precondition((0..<24).contains(insertCode) && (0..<24).contains(copyCode))
		let cell: Int
		if reusesLastDistance {
			precondition(insertCode < 8 && copyCode < 16, "no implicit-distance symbol")
			cell = (copyCode >> 3) << 6
		} else {
			// Cell bases of the §5 table, indexed by insert code / 8 and copy code / 8.
			let bases = [[128, 192, 384], [256, 320, 512], [448, 576, 640]]
			cell = bases[insertCode >> 3][copyCode >> 3]
		}
		return cell + ((insertCode & 7) << 3) + (copyCode & 7)
	}
}

/// The stream-wide ring of the four last distances (RFC 7932 §4), with
/// NPOSTFIX = 0 and NDIRECT = 0.
struct BrotliDistanceRing: Equatable, Sendable {
	/// Most recent first.
	private var distances: [Int]

	/// RFC 7932 §4: "the fourth-to-last is set to 16, the third-to-last to 15,
	/// the second-to-last to 11, and the last distance to 4".
	init() {
		distances = [4, 11, 15, 16]
	}

	/// The distance symbol and extra bits that encode `distance` now: a special
	/// symbol 0...15 if one resolves to it, otherwise a symbol of 16 or more.
	func code(forDistance distance: Int) -> BrotliCodedValue {
		precondition(distance >= 1, "distance \(distance) is not positive")
		for symbol in 0..<16 where special(symbol) == distance {
			return BrotliCodedValue(code: symbol, extraBitCount: 0, extraBits: 0)
		}
		// §4 with NPOSTFIX = NDIRECT = 0: distance = offset + dextra + 1, where
		// offset = ((2 + (hcode & 1)) << ndistbits) - 4. Adding 3 to the distance
		// puts its leading two bits at the top of (2 + (hcode & 1)) << ndistbits.
		let shifted = distance + 3
		let ndistbits = (Int.bitWidth - shifted.leadingZeroBitCount) - 2
		let low = (shifted >> ndistbits) & 1
		return BrotliCodedValue(
			code: 16 + 2 * (ndistbits - 1) + low, extraBitCount: ndistbits,
			extraBits: shifted - ((2 + low) << ndistbits))
	}

	/// The distance a special symbol 0...15 stands for, which may not be positive.
	private func special(_ symbol: Int) -> Int {
		let deltas = [0, 0, 0, 0, -1, 1, -2, 2, -3, 3]
		if symbol < 4 { return distances[symbol] }
		return distances[symbol < 10 ? 0 : 1] + deltas[symbol < 10 ? symbol : symbol - 6]
	}

	/// Advances the ring after a copy written with `code`. §4: "When a distance
	/// symbol 0 appears, the distance it represents ... is not pushed".
	mutating func record(distance: Int, code: Int) {
		guard code != 0 else { return }
		distances = [distance, distances[0], distances[1], distances[2]]
	}
}

/// Prefix codes over a Brotli alphabet, written with the shared
/// ``PrefixCodeWriter`` tree writers. A simple code's symbols take the bit
/// width of the whole alphabet, not of the highest symbol used.
enum BrotliPrefixCode {
	/// A code with lengths of at most 15 bits for `counts`. With one used
	/// symbol, or none (every category needs a code even when unused), the code
	/// is degenerate: its single symbol costs no bits in the data.
	static func build(counts: [UInt32]) -> PrefixCode {
		let used = counts.reduce(0) { $0 + ($1 == 0 ? 0 : 1) }
		var depths: [UInt8]
		if used == 0 {
			depths = [UInt8](repeating: 0, count: counts.count)
			depths[0] = 1
		} else {
			depths = HuffmanTree.createTree(
				counts: counts, length: counts.count, treeLimit: maxCodeLength)
		}
		let bits = HuffmanTree.convertBitDepthsToSymbols(
			depth: depths, length: counts.count)
		return PrefixCode(depths: depths, bits: bits)
	}

	/// Longest code §3.5 can describe: code lengths are "0..15".
	private static let maxCodeLength = 15

	static func write(_ code: PrefixCode, alphabetSize: Int, to writer: inout BitWriter) {
		precondition(
			code.depths.count == alphabetSize, "depth table must span the alphabet")
		let symbols = code.depths.indices.filter { code.depths[$0] != 0 }
		if symbols.count <= 4 {
			// §3.4: ALPHABET_BITS is "the smallest number of bits that can represent
			// all symbols in the alphabet".
			let alphabetBits = Int.bitWidth - (alphabetSize - 1).leadingZeroBitCount
			PrefixCodeWriter.storeSimpleHuffmanTree(
				depths: code.depths, symbols: symbols, count: symbols.count,
				maxBits: alphabetBits, writer: &writer)
		} else {
			PrefixCodeWriter.storeHuffmanTree(
				depth: code.depths, length: alphabetSize, writer: &writer)
		}
	}
}

/// Stream header and meta-block serialization (RFC 7932 §9).
enum BrotliMetaBlock {
	static func writeStreamHeader(to writer: inout BitWriter) {
		// §9.1 lists WBITS 22 as bit pattern "1011", "parsed from right to left".
		writer.write(4, 0b1011)
	}

	/// A non-last meta-block holding `bytes` verbatim. §9.2 says ISUNCOMPRESSED
	/// is "only present if the ISLAST bit is not set".
	static func writeUncompressed(_ bytes: ArraySlice<UInt8>, to writer: inout BitWriter) {
		precondition(
			(1...BrotliEncoder.maxMetaBlockLength).contains(bytes.count),
			"meta-block length \(bytes.count) out of range")
		writer.write(1, 0)  // ISLAST
		writer.write(2, 0)  // MNIBBLES = 4
		writer.write(16, UInt64(bytes.count - 1))
		writer.write(1, 1)  // ISUNCOMPRESSED
		writer.zeroPadToByte()
		for byte in bytes { writer.write(8, UInt64(byte)) }
	}

	/// A compressed meta-block for `input[range]` built from `commands`, with one
	/// block type and one prefix tree per category, NPOSTFIX = 0 and NDIRECT = 0.
	/// `ring` advances only through what this meta-block writes; a caller that
	/// may discard the result passes a copy.
	static func writeCompressed(
		input: [UInt8], range: Range<Int>, commands: [BrotliCommand],
		isLast: Bool, ring: inout BrotliDistanceRing, to writer: inout BitWriter
	) {
		precondition(
			(1...BrotliEncoder.maxMetaBlockLength).contains(range.count),
			"meta-block length \(range.count) out of range")

		struct Coded {
			var symbol: Int
			var insert: BrotliCodedValue
			var copy: BrotliCodedValue
			var literals: Range<Int>
			var distance: BrotliCodedValue?
		}
		var literalCounts = [UInt32](repeating: 0, count: 256)
		var commandCounts = [UInt32](repeating: 0, count: 704)
		var distanceCounts = [UInt32](repeating: 0, count: 64)
		var coded = [Coded]()
		var position = range.lowerBound
		for command in commands {
			let insert = BrotliLengthCodes.insertCode(forLength: command.insertLength)
			let literals = position..<position + command.insertLength
			for index in literals { literalCounts[Int(input[index])] += 1 }
			position = literals.upperBound
			let copy: BrotliCodedValue
			var distance: BrotliCodedValue?
			var reusesLastDistance = false
			if command.copyLength == 0 {
				precondition(
					command.insertLength > 0 && position == range.upperBound,
					"only a non-empty trailing insert may omit its copy")
				// The copy of a meta-block's last command is ignored (§9.3), so any
				// copy code will do.
				copy = BrotliCodedValue(code: 0, extraBitCount: 0, extraBits: 0)
			} else {
				copy = BrotliLengthCodes.copyCode(forLength: command.copyLength)
				let distanceCode = ring.code(forDistance: command.distance)
				ring.record(distance: command.distance, code: distanceCode.code)
				reusesLastDistance =
					distanceCode.code == 0 && insert.code < 8 && copy.code < 16
				if !reusesLastDistance {
					distance = distanceCode
					distanceCounts[distanceCode.code] += 1
				}
				position += command.copyLength
			}
			let symbol = BrotliLengthCodes.insertAndCopySymbol(
				insertCode: insert.code, copyCode: copy.code,
				reusesLastDistance: reusesLastDistance)
			commandCounts[symbol] += 1
			coded.append(
				Coded(
					symbol: symbol, insert: insert, copy: copy,
					literals: literals,
					distance: distance))
		}
		precondition(position == range.upperBound, "commands must cover the range")

		writer.write(1, isLast ? 1 : 0)  // ISLAST
		if isLast { writer.write(1, 0) }  // ISLASTEMPTY
		writer.write(2, 0)  // MNIBBLES = 4
		writer.write(16, UInt64(range.count - 1))
		if !isLast { writer.write(1, 0) }  // ISUNCOMPRESSED
		writer.write(3, 0)  // NBLTYPESL, NBLTYPESI, NBLTYPESD = 1
		writer.write(2, 0)  // NPOSTFIX
		writer.write(4, 0)  // NDIRECT
		writer.write(2, 0)  // context mode of the one literal block type
		writer.write(2, 0)  // NTREESL, NTREESD = 1

		let literalCode = BrotliPrefixCode.build(counts: literalCounts)
		let commandCode = BrotliPrefixCode.build(counts: commandCounts)
		let distanceCode = BrotliPrefixCode.build(counts: distanceCounts)
		BrotliPrefixCode.write(literalCode, alphabetSize: 256, to: &writer)
		BrotliPrefixCode.write(commandCode, alphabetSize: 704, to: &writer)
		BrotliPrefixCode.write(distanceCode, alphabetSize: 64, to: &writer)

		func emit(_ symbol: Int, _ code: PrefixCode) {
			if !code.isDegenerate {
				writer.write(Int(code.depths[symbol]), UInt64(code.bits[symbol]))
			}
		}
		for command in coded {
			emit(command.symbol, commandCode)
			writer.write(command.insert.extraBitCount, UInt64(command.insert.extraBits))
			writer.write(command.copy.extraBitCount, UInt64(command.copy.extraBits))
			for index in command.literals { emit(Int(input[index]), literalCode) }
			if let distance = command.distance {
				emit(distance.code, distanceCode)
				writer.write(distance.extraBitCount, UInt64(distance.extraBits))
			}
		}
	}

	/// `input[range]` as whichever of the compressed and uncompressed meta-block
	/// is fewer bits. The compressed trial runs on a copy of `ring`, which is
	/// kept only if that form wins; uncompressed data pushes no distances. A
	/// last meta-block written uncompressed is followed by ``writeEmptyLast``.
	static func writeSmaller(
		input: [UInt8], range: Range<Int>, commands: [BrotliCommand],
		isLast: Bool, ring: inout BrotliDistanceRing, to writer: inout BitWriter
	) {
		var trialRing = ring
		var trial = BitWriter()
		writeCompressed(
			input: input, range: range, commands: commands, isLast: isLast,
			ring: &trialRing, to: &trial)

		// Bit position after each form, starting from the writer's current bit.
		// A last meta-block ends on a byte boundary, which the uncompressed form
		// reaches only after its empty last meta-block.
		let start = writer.bitsWritten % 8
		var compressedEnd = start + trial.bitsWritten
		var uncompressedEnd = (start + 20 + 7) / 8 * 8 + 8 * range.count
		if isLast {
			compressedEnd = (compressedEnd + 7) / 8 * 8
			uncompressedEnd = (uncompressedEnd + 2 + 7) / 8 * 8
		}

		if compressedEnd <= uncompressedEnd {
			writer.append(trial)
			ring = trialRing
		} else {
			writeUncompressed(input[range], to: &writer)
			if isLast { writeEmptyLast(to: &writer) }
		}
	}

	/// The empty last meta-block: ISLAST = 1, ISLASTEMPTY = 1, zero fill.
	static func writeEmptyLast(to writer: inout BitWriter) {
		writer.write(2, 0b11)
		writer.zeroPadToByte()
	}
}
