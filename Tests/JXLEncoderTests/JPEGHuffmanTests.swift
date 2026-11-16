import Testing

@testable import JXLEncoder

@Suite("JPEG Huffman decoding")
struct JPEGHuffmanTests {
	static let fixtureReferences = Set([
		"Tests/JXLEncoderTests/Fixtures/jpeg_huffman/root_sparse.tsv",
		"Tests/JXLEncoderTests/Fixtures/jpeg_huffman/subtable_9.tsv",
		"Tests/JXLEncoderTests/Fixtures/jpeg_huffman/subtable_16.tsv",
		"Tests/JXLEncoderTests/Fixtures/jpeg_huffman/maximal_ac.tsv",
	])

	@Test("lookup entries match root, subtable and sentinel captures")
	func lookupEntriesMatchSource() throws {
		let cases: [(String, [Int], [UInt8])] = [
			("root_sparse", [0, 2], [7, 9]),
			("subtable_9", [0, 0, 0, 0, 0, 0, 0, 1, 1], [7, 9]),
			("subtable_16", [1] + Array(repeating: 0, count: 14) + [1], [7, 9]),
			(
				"maximal_ac",
				Array(repeating: 0, count: 7) + [255, 1]
					+ Array(repeating: 0, count: 7),
				Array(0...255).map(UInt8.init)
			),
		]
		for (name, prefixCounts, symbols) in cases {
			let table = try #require(
				JPEGHuffmanTable(
					counts: prefixCounts
						+ Array(
							repeating: 0, count: 16 - prefixCounts.count
						),
					values: symbols))
			let capture = try PackageCheckout.read(
				"Tests/JXLEncoderTests/Fixtures/jpeg_huffman/\(name).tsv")
			let expected = try capture.split(whereSeparator: \.isNewline).map {
				line -> JPEGHuffmanTable.Entry in
				let fields = line.split(separator: "\t")
				guard fields.count == 2, let bits = UInt8(fields[0]),
					let value = UInt16(fields[1])
				else {
					throw SemanticDumpError.malformedEntropyFixture(
						name: name, field: "lookup")
				}
				return JPEGHuffmanTable.Entry(bits: bits, value: value)
			}
			#expect(
				table.entries == expected,
				"\(name) differs from pinned lookup capture")
		}
	}

	@Test("symbols consume their exact code lengths across root and subtable paths")
	func symbolsConsumeExactCodeLengths() throws {
		let table = try #require(
			JPEGHuffmanTable(
				counts: [0, 2] + Array(repeating: 0, count: 14), values: [7, 9]))
		var reader = JPEGBitReader(data: [0x10, 0xFF, 0xD9], index: 0)
		#expect(try table.decode(&reader) == 7)
		#expect(try table.decode(&reader) == 9)
		#expect(reader.read(1) == 0)
	}

	@Test("invalid counts and reserved code space fail before lookup indexing")
	func invalidCodeSpaceIsRejected() {
		#expect(
			JPEGHuffmanTable(
				counts: [2] + Array(repeating: 0, count: 15), values: [0, 1]) == nil
		)
		#expect(
			JPEGHuffmanTable(
				counts: [0, 1] + Array(repeating: 0, count: 14), values: []) == nil)
		#expect(
			JPEGHuffmanTable(counts: [256] + Array(repeating: 0, count: 15), values: [])
				== nil)
		#expect(JPEGHuffmanTable(counts: [0], values: []) == nil)
		#expect(
			JPEGHuffmanTable(
				counts: [0, -1] + Array(repeating: 0, count: 14), values: []) == nil
		)
		#expect(
			JPEGHuffmanTable(
				counts: [0, 1] + Array(repeating: 0, count: 14), values: []) == nil)
		let deepFullCounts = Array(repeating: 1, count: 15) + [2]
		let deepFullSymbols = Array(0..<17).map(UInt8.init)
		#expect(
			JPEGHuffmanTable(counts: deepFullCounts, values: deepFullSymbols) == nil)
	}

	@Test("empty, reserved and unassigned lookup symbols fail without narrowing")
	func invalidSymbolsAreRejected() throws {
		let table = try #require(
			JPEGHuffmanTable(counts: Array(repeating: 0, count: 16), values: []))
		#expect(table.entries[0] == JPEGHuffmanTable.Entry(bits: 0, value: 256))
		var reader = JPEGBitReader(data: [0, 0xFF, 0xD9], index: 0)
		#expect(throws: JPEGParseError.invalidHuffmanCode) { try table.decode(&reader) }
		let oneSymbol = try #require(
			JPEGHuffmanTable(
				counts: [0, 1] + Array(repeating: 0, count: 14), values: [255]))
		var reserved = JPEGBitReader(data: [0x40, 0xFF, 0xD9], index: 0)
		#expect(throws: JPEGParseError.invalidHuffmanCode) {
			try oneSymbol.decode(&reserved)
		}
	}

	@Test("variable-width subtables consume exact source lengths")
	func subtableSymbolsConsumeExactCodeLengths() throws {
		let table9 = try #require(
			JPEGHuffmanTable(
				counts: [0, 0, 0, 0, 0, 0, 0, 1, 1] + Array(repeating: 0, count: 7),
				values: [7, 9]))
		var reader9 = JPEGBitReader(data: [0, 1, 0x40, 0xFF, 0xD9], index: 0)
		#expect(try table9.decode(&reader9) == 7)
		#expect(try table9.decode(&reader9) == 9)
		#expect(reader9.read(1) == 1)

		let table16 = try #require(
			JPEGHuffmanTable(
				counts: [1] + Array(repeating: 0, count: 14) + [1], values: [7, 9]))
		var reader16 = JPEGBitReader(data: [0x40, 0, 0, 0xFF, 0xD9], index: 0)
		#expect(try table16.decode(&reader16) == 7)
		#expect(try table16.decode(&reader16) == 9)
		#expect(reader16.read(1) == 0)
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
