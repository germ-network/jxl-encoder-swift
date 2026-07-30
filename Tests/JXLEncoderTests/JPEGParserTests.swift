import Foundation
import Testing

@testable import JXLEncoder

/// Differential tests against libjpeg, which decoded the same fixtures into
/// `.coef` dumps (see `Reference/make_jpeg_fixtures.sh`). Coefficients are the
/// parser's whole output, so matching libjpeg block for block pins the Huffman
/// decode, the DC predictor, restart handling, byte destuffing, the zig-zag
/// scan and the MCU layout at once.
@Suite("JPEGParser")
struct JPEGParserTests {
	enum FixtureError: Error { case notFound(String) }

	static func fixture(_ name: String, _ ext: String = "jpg") throws -> [UInt8] {
		guard
			let url = Bundle.module.url(
				forResource: name, withExtension: ext, subdirectory: "Fixtures")
		else { throw FixtureError.notFound(name) }
		return [UInt8](try Data(contentsOf: url))
	}

	/// Index of the first differing element, for a failure message that names a
	/// block instead of printing tens of thousands of coefficients.
	static func firstDifference(_ lhs: [Int32], _ rhs: [Int32]) -> String? {
		if lhs.count != rhs.count { return "count \(lhs.count) vs \(rhs.count)" }
		for i in 0..<lhs.count where lhs[i] != rhs[i] {
			return "block \(i / 64) coefficient \(i % 64): \(lhs[i]) vs \(rhs[i])"
		}
		return nil
	}

	@Test(
		"matches libjpeg's coefficients",
		arguments: [
			"small_444", "small_422", "small_440", "small_411", "hopper_420_odd",
			"hopper_gray_odd",
		])
	func matchesReference(name: String) throws {
		let reference = try JPEGCoefficientDump(fixture: name)
		let image = try JPEGParser.parse(Self.fixture(name))

		#expect(image.width == reference.width)
		#expect(image.height == reference.height)
		try #require(image.components.count == reference.components.count)

		for (parsed, expected) in zip(image.components, reference.components) {
			#expect(parsed.identifier == expected.identifier)
			#expect(parsed.horizontalSampling == expected.horizontalSampling)
			#expect(parsed.verticalSampling == expected.verticalSampling)
			#expect(parsed.quantTableIndex == expected.quantTableIndex)
			#expect(parsed.blocksPerLine == expected.blocksPerLine)
			#expect(parsed.blocksPerColumn == expected.blocksPerColumn)
			let difference = Self.firstDifference(
				parsed.coefficients, expected.coefficients)
			#expect(
				difference == nil,
				"component \(parsed.identifier): \(difference ?? "")")
		}

		for (index, table) in reference.quantTables {
			try #require(index < image.quantTables.count)
			#expect(image.quantTables[index] == table)
		}
	}

	@Test("reads geometry and sampling factors from a 4:2:0 frame")
	func geometry() throws {
		let image = try JPEGParser.parse(Self.fixture("hopper_420_restart"))

		#expect(image.width == 200)
		#expect(image.height == 200)
		#expect(image.maxHorizontalSampling == 2)
		#expect(image.maxVerticalSampling == 2)
		#expect(image.components.map(\.identifier) == [1, 2, 3])
		#expect(image.components.map(\.horizontalSampling) == [2, 1, 1])
		#expect(image.components.map(\.verticalSampling) == [2, 1, 1])
		#expect(image.components.map(\.quantTableIndex) == [0, 1, 1])
		#expect(image.quantTables.count == 2)

		// 200 pixels is 12.5 MCUs of 16, so the grid pads to 13 and luma to 26
		// blocks; every one of those blocks is coded and kept.
		#expect(image.components[0].blocksPerLine == 26)
		#expect(image.components[0].blocksPerColumn == 26)
		#expect(image.components[1].blocksPerLine == 13)
		#expect(image.components[1].blocksPerColumn == 13)
		#expect(image.components[0].coefficients.count == 26 * 26 * 64)
		#expect(image.components[2].coefficients.count == 13 * 13 * 64)
	}

	@Test("reports the restart interval")
	func restartInterval() throws {
		#expect(
			try JPEGParser.parse(Self.fixture("hopper_420_restart")).restartInterval
				== 13)
		#expect(try JPEGParser.parse(Self.fixture("hopper_420_odd")).restartInterval == 21)
		#expect(try JPEGParser.parse(Self.fixture("small_444")).restartInterval == 0)
	}

	/// 16-bit DQT entries only appear in extended sequential frames, so this
	/// covers SOF1 and the two-byte quantizer path together.
	@Test("reads 16-bit quantization tables from an extended sequential frame")
	func sixteenBitQuantTables() throws {
		let image = try JPEGParser.parse(Self.fixture("hopper_420_sof1"))

		#expect(image.width == 200)
		#expect(image.quantTables.count == 2)
		#expect(image.quantTables[0][0] == 400)
		#expect(image.quantTables[1][0] == 425)
		#expect(image.quantTables[0].contains { $0 > 255 })
	}

	/// A lone component's sampling factors say nothing about its block grid —
	/// it is always its own maximum — so a non-interleaved scan codes exactly
	/// `ceil(width / 8)` blocks per line, not the MCU-padded count.
	@Test("a single-component scan is not padded to the MCU grid")
	func nonInterleavedBlockGrid() throws {
		let plain = try JPEGParser.parse(Self.fixture("hopper_gray_odd"))
		#expect(plain.components[0].blocksPerLine == 13)  // ceil(101 / 8)
		#expect(plain.components[0].blocksPerColumn == 9)  // ceil(67 / 8)

		var patched = try Self.fixture("hopper_gray_odd")
		let sampling = try #require(Self.segmentOffset(patched, marker: 0xC0)) + 9
		patched[sampling] = 0x22
		let image = try JPEGParser.parse(patched)

		// The MCU grid would be ceil(101 / 16) * 2 = 14 blocks wide.
		#expect(image.components[0].blocksPerLine == 13)
		#expect(image.components[0].blocksPerColumn == 9)
		#expect(image.components[0].coefficients == plain.components[0].coefficients)
	}

	/// Destuffing is only covered because the fixtures actually contain `FF 00`.
	@Test("fixtures exercise byte stuffing")
	func fixturesContainStuffedBytes() throws {
		let data = try Self.fixture("hopper_420_odd")
		var stuffed = 0
		for i in 0..<(data.count - 1) where data[i] == 0xFF && data[i + 1] == 0x00 {
			stuffed += 1
		}
		#expect(stuffed > 0)
	}

	// MARK: - Rejection

	@Test("rejects progressive")
	func rejectsProgressive() throws {
		let data = try Self.fixture("reject_progressive")
		#expect(throws: JPEGParseError.progressiveNotSupported) {
			try JPEGParser.parse(data)
		}
	}

	@Test("rejects arithmetic coding")
	func rejectsArithmetic() throws {
		let data = try Self.fixture("reject_arithmetic")
		#expect(throws: JPEGParseError.arithmeticCodingNotSupported) {
			try JPEGParser.parse(data)
		}
	}

	@Test("rejects lossless")
	func rejectsLossless() throws {
		let data = try Self.fixture("reject_lossless")
		#expect(throws: JPEGParseError.losslessNotSupported) {
			try JPEGParser.parse(data)
		}
	}

	/// Differential and hierarchical frames have no fixture — no encoder to
	/// hand produces them — so the SOF marker is substituted directly.
	@Test(
		"rejects the remaining frame types",
		arguments: [
			(UInt8(0xC5), JPEGParseError.differentialNotSupported),
			(UInt8(0xC6), JPEGParseError.differentialNotSupported),
			(UInt8(0xC7), JPEGParseError.differentialNotSupported),
			(UInt8(0xCB), JPEGParseError.arithmeticCodingNotSupported),
			(UInt8(0xCD), JPEGParseError.arithmeticCodingNotSupported),
			(UInt8(0xDE), JPEGParseError.unsupportedFrameType(marker: 0xDE)),
		])
	func rejectsOtherFrameTypes(marker: UInt8, expected: JPEGParseError) throws {
		var data = try Self.fixture("small_444")
		let offset = try #require(Self.segmentOffset(data, marker: 0xC0))
		data[offset - 1] = marker
		#expect(throws: expected) { try JPEGParser.parse(data) }
	}

	@Test("rejects a sample precision other than 8 bits")
	func rejectsTwelveBit() throws {
		var data = try Self.fixture("small_444")
		let offset = try #require(Self.segmentOffset(data, marker: 0xC0))
		data[offset + 2] = 12
		#expect(throws: JPEGParseError.unsupportedSamplePrecision(12)) {
			try JPEGParser.parse(data)
		}
	}

	@Test("rejects component counts other than 1 and 3")
	func rejectsFourComponents() throws {
		var data = try Self.fixture("small_444")
		let offset = try #require(Self.segmentOffset(data, marker: 0xC0))
		data[offset + 7] = 4
		#expect(throws: JPEGParseError.unsupportedComponentCount(4)) {
			try JPEGParser.parse(data)
		}
	}

	/// A zero quantizer would trap whatever dequantizes downstream.
	@Test("rejects a zero quantization table entry")
	func rejectsZeroQuantizer() throws {
		var data = try Self.fixture("small_444")
		let offset = try #require(Self.segmentOffset(data, marker: 0xDB))
		data[offset + 3] = 0
		#expect(throws: JPEGParseError.invalidQuantTable(index: 0)) {
			try JPEGParser.parse(data)
		}
	}

	@Test("rejects a scan that selects an undefined Huffman table")
	func rejectsUndefinedHuffmanTable() throws {
		var data = try Self.fixture("small_444")
		let offset = try #require(Self.segmentOffset(data, marker: 0xDA))
		data[offset + 4] = 0x30  // component 1, DC table 3, AC table 0
		#expect(throws: JPEGParseError.undefinedHuffmanTable(isAC: false, index: 3)) {
			try JPEGParser.parse(data)
		}
	}

	/// Losing restart-marker sync means the decoder and the stream disagree
	/// about where blocks start, which is not something to guess through.
	@Test("rejects a restart marker out of sequence")
	func rejectsWrongRestartMarker() throws {
		var data = try Self.fixture("hopper_420_odd")
		let marker = try #require(
			(0..<(data.count - 1)).first {
				data[$0] == 0xFF && data[$0 + 1] == 0xD0
			})
		data[marker + 1] = 0xD3
		#expect(throws: JPEGParseError.missingRestartMarker(expected: 0)) {
			try JPEGParser.parse(data)
		}
	}

	@Test("rejects entropy data that stops early")
	func rejectsTruncatedScan() throws {
		let data = try Self.fixture("small_444")
		let truncated = Array(data.prefix(data.count - 200))
		#expect(throws: JPEGParseError.truncatedEntropyData) {
			try JPEGParser.parse(truncated)
		}
	}

	@Test("rejects a file that stops inside the header")
	func rejectsTruncatedHeader() throws {
		let data = try Self.fixture("small_444")
		#expect(throws: JPEGParseError.unexpectedEndOfData) {
			try JPEGParser.parse(Array(data.prefix(20)))
		}
	}

	/// Dimensions this large cannot be backed by the bytes on hand; without the
	/// check the parser would allocate for them before finding out. Kept under
	/// the pixel ceiling so this exercises the entropy-length guard rather than
	/// the ceiling — see `JPEGSizeLimitTests` for that one.
	@Test("rejects dimensions the file cannot possibly hold")
	func rejectsImplausibleDimensions() throws {
		var data = try Self.fixture("small_444")
		let offset = try #require(Self.segmentOffset(data, marker: 0xC0))
		data[offset + 3] = 0x0F  // height
		data[offset + 5] = 0x0F  // width
		#expect(throws: JPEGParseError.truncatedEntropyData) {
			try JPEGParser.parse(data)
		}
	}

	@Test("rejects input that is not JPEG")
	func rejectsNonJPEG() {
		#expect(throws: JPEGParseError.missingStartOfImage) {
			try JPEGParser.parse([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
		}
		#expect(throws: JPEGParseError.missingStartOfImage) {
			try JPEGParser.parse([])
		}
	}

	@Test("rejects a file with no scan")
	func rejectsMissingScan() throws {
		let data = try Self.fixture("small_444")
		let offset = try #require(Self.segmentOffset(data, marker: 0xDA))
		#expect(throws: JPEGParseError.missingScan) {
			try JPEGParser.parse(Array(data.prefix(offset - 2)) + [0xFF, 0xD9])
		}
	}

	/// Offset of a marker's length field, found by walking the segment chain so
	/// a byte pattern inside APPn data cannot be mistaken for a marker.
	static func segmentOffset(_ data: [UInt8], marker: UInt8) -> Int? {
		var index = 2
		while index + 3 < data.count {
			guard data[index] == 0xFF else { return nil }
			let found = data[index + 1]
			if found == marker { return index + 2 }
			if found == 0xDA { return nil }
			index += 2 + Int(data[index + 2]) << 8 + Int(data[index + 3])
		}
		return nil
	}
}
