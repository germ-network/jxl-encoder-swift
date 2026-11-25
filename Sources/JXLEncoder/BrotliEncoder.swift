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
		fatalError("unimplemented")
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
struct BrotliMatchFinder {
	init(input: [UInt8], windowSize: Int) {
		fatalError("unimplemented")
	}

	/// Commands covering exactly `range`, whose copies never reach before the
	/// start of the input or further back than the window.
	mutating func commands(for range: Range<Int>) -> [BrotliCommand] {
		fatalError("unimplemented")
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
	static func insertCode(forLength length: Int) -> BrotliCodedValue {
		fatalError("unimplemented")
	}

	/// `length` is at least 2, the shortest copy §5 can express.
	static func copyCode(forLength length: Int) -> BrotliCodedValue {
		fatalError("unimplemented")
	}

	/// The insert-and-copy symbol. With `reusesLastDistance`, it is one of the
	/// codes 0...127, after which §5 says "the distance code of the command is
	/// set to zero" and no distance is written. Those codes exist only for
	/// insert codes 0...7 and copy codes 0...15, so a caller reusing the last
	/// distance outside that range writes distance symbol 0 explicitly instead.
	static func insertAndCopySymbol(
		insertCode: Int, copyCode: Int, reusesLastDistance: Bool
	) -> Int {
		fatalError("unimplemented")
	}
}

/// The stream-wide ring of the four last distances (RFC 7932 §4), with
/// NPOSTFIX = 0 and NDIRECT = 0.
struct BrotliDistanceRing: Equatable, Sendable {
	/// RFC 7932 §4: "the fourth-to-last is set to 16, the third-to-last to 15,
	/// the second-to-last to 11, and the last distance to 4".
	init() {
		fatalError("unimplemented")
	}

	/// The distance symbol and extra bits that encode `distance` now: a special
	/// symbol 0...15 if one resolves to it, otherwise a symbol of 16 or more.
	func code(forDistance distance: Int) -> BrotliCodedValue {
		fatalError("unimplemented")
	}

	/// Advances the ring after a copy written with `code`. §4: "When a distance
	/// symbol 0 appears, the distance it represents ... is not pushed".
	mutating func record(distance: Int, code: Int) {
		fatalError("unimplemented")
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
		fatalError("unimplemented")
	}

	static func write(_ code: PrefixCode, alphabetSize: Int, to writer: inout BitWriter) {
		fatalError("unimplemented")
	}
}

/// Stream header and meta-block serialization (RFC 7932 §9).
enum BrotliMetaBlock {
	static func writeStreamHeader(to writer: inout BitWriter) {
		fatalError("unimplemented")
	}

	/// A non-last meta-block holding `bytes` verbatim. §9.2 allows
	/// ISUNCOMPRESSED "only if the ISLAST bit is not set".
	static func writeUncompressed(_ bytes: ArraySlice<UInt8>, to writer: inout BitWriter) {
		fatalError("unimplemented")
	}

	/// A compressed meta-block for `input[range]` built from `commands`, with one
	/// block type and one prefix tree per category, NPOSTFIX = 0 and NDIRECT = 0.
	/// `ring` advances only through what this meta-block writes; a caller that
	/// may discard the result passes a copy.
	static func writeCompressed(
		input: [UInt8], range: Range<Int>, commands: [BrotliCommand],
		isLast: Bool, ring: inout BrotliDistanceRing, to writer: inout BitWriter
	) {
		fatalError("unimplemented")
	}

	/// `input[range]` as whichever of the compressed and uncompressed meta-block
	/// is fewer bits. The compressed trial runs on a copy of `ring`, which is
	/// kept only if that form wins; uncompressed data pushes no distances. A
	/// last meta-block written uncompressed is followed by ``writeEmptyLast``.
	static func writeSmaller(
		input: [UInt8], range: Range<Int>, commands: [BrotliCommand],
		isLast: Bool, ring: inout BrotliDistanceRing, to writer: inout BitWriter
	) {
		fatalError("unimplemented")
	}

	/// The empty last meta-block: ISLAST = 1, ISLASTEMPTY = 1, zero fill.
	static func writeEmptyLast(to writer: inout BitWriter) {
		fatalError("unimplemented")
	}
}
