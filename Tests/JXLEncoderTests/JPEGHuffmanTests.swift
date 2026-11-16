import Testing

@testable import JXLEncoder

@Suite("JPEG Huffman decoding")
struct JPEGHuffmanTests {
	@Test(
		"lookup entries match pinned root, subtable and sentinel captures",
		.disabled("Pending implementation"))
	func lookupEntriesMatchSource() throws {
		let table = try #require(
			JPEGHuffmanTable(counts: [1] + Array(repeating: 0, count: 15), values: [0]))
		let entry = JPEGHuffmanTable.Entry(bits: 1, value: 0)
		#expect(table.entries.first == entry)
	}

	@Test(
		"symbols consume their exact code lengths across root and subtable paths",
		.disabled("Pending implementation"))
	func symbolsConsumeExactCodeLengths() throws {
		let table = try #require(
			JPEGHuffmanTable(counts: [1] + Array(repeating: 0, count: 15), values: [7]))
		var reader = JPEGBitReader(data: [0x40, 0xFF, 0xD9], index: 0)
		#expect(try table.decode(&reader) == 7)
		#expect(reader.read(1) == 1)
	}

	@Test(
		"invalid counts and reserved code space fail before lookup indexing",
		.disabled("Pending implementation"))
	func invalidCodeSpaceIsRejected() {
		#expect(
			JPEGHuffmanTable(
				counts: [2] + Array(repeating: 0, count: 15), values: [0, 1]) == nil
		)
	}

	@Test(
		"empty, reserved and unassigned lookup symbols fail without narrowing",
		.disabled("Pending implementation"))
	func invalidSymbolsAreRejected() throws {
		let table = try #require(
			JPEGHuffmanTable(counts: Array(repeating: 0, count: 16), values: []))
		var reader = JPEGBitReader(data: [0, 0xFF, 0xD9], index: 0)
		#expect(throws: JPEGParseError.invalidHuffmanCode) { try table.decode(&reader) }
	}

	@Test(
		"lookahead is returned while consumed marker or EOF bits are rejected",
		.disabled("Pending implementation"))
	func consumedBoundaryIsEnforced() throws {
		var reader = JPEGBitReader(data: [0x40, 0xFF, 0xD9], index: 0)
		_ = reader.peek(16)
		reader.skip(1)
		#expect(try reader.finish() == 1)
	}

	@Test(
		"stuffed bytes and restart reset preserve the next entropy stream",
		.disabled("Pending implementation"))
	func stuffingAndRestartPreserveBits() throws {
		var reader = JPEGBitReader(data: [0xFF, 0, 0xFF, 0xD0, 0x40, 0xFF, 0xD9], index: 0)
		#expect(reader.read(8) == 0xFF)
		#expect(try reader.finish() == 2)
		reader.restart(at: 4)
		#expect(reader.read(1) == 0)
		#expect(try reader.finish() == 5)
	}
}
