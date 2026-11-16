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
	@Test(
		"each selected component binds the quantizer active at its scan",
		.disabled("Pending approved reader implementation"))
	func quantizationTablesBindAtSelectedScan() throws {
		Issue.record("Pending behavioral assertions")
	}

	@Test(
		"quantizer replacement preserves previously decoded component meaning",
		.disabled("Pending approved reader implementation"))
	func quantizationRedefinitionsPreserveBoundValues() throws {
		Issue.record("Pending behavioral assertions")
	}

	@Test(
		"scan-bound quantizers preserve sparse destination compatibility",
		.disabled("Pending approved reader implementation"))
	func quantizationBindingsPreserveSparseDestinations() throws {
		Issue.record("Pending behavioral assertions")
	}

	@Test(
		"selected marker parsing reaches a required EOI",
		.disabled("Pending approved reader implementation"))
	func markerDispatchRequiresEOI() throws {
		Issue.record("Pending behavioral assertions")
	}

	@Test(
		"segment fields stay inside their declared payloads",
		.disabled("Pending approved reader implementation"))
	func segmentReadsRespectDeclaredBounds() throws {
		Issue.record("Pending behavioral assertions")
	}

	@Test(
		"frame and scan component identifiers are unique",
		.disabled("Pending approved reader implementation"))
	func componentIdentifiersAreUnique() throws {
		Issue.record("Pending behavioral assertions")
	}

	@Test(
		"frame sampling ratios are integral",
		.disabled("Pending approved reader implementation"))
	func frameSamplingRatiosAreIntegral() throws {
		Issue.record("Pending behavioral assertions")
	}

	@Test(
		"a second restart interval definition is rejected",
		.disabled("Pending approved reader implementation"))
	func duplicateRestartIntervalIsRejected() throws {
		Issue.record("Pending behavioral assertions")
	}

	@Test(
		"disjoint sequential scan partitions recover exact coefficients",
		.disabled("Pending approved reader implementation"))
	func sequentialScanPartitionsMatchReference() throws {
		Issue.record("Pending behavioral assertions")
	}

	@Test(
		"scan order preserves frame component identity",
		.disabled("Pending approved reader implementation"))
	func reorderedScanComponentsPreserveFrameOrder() throws {
		Issue.record("Pending behavioral assertions")
	}

	@Test(
		"single-component scans preserve padded storage and zero edges",
		.disabled("Pending approved reader implementation"))
	func singleComponentScansUsePaddedStride() throws {
		Issue.record("Pending behavioral assertions")
	}

	@Test(
		"sequential scans cannot decode a component twice",
		.disabled("Pending approved reader implementation"))
	func sequentialScansRejectOverlap() throws {
		Issue.record("Pending behavioral assertions")
	}

	@Test(
		"range-valid sequential scan fields use source normalization",
		.disabled("Pending approved reader implementation"))
	func sequentialScanParametersFollowSource() throws {
		Issue.record("Pending behavioral assertions")
	}

	@Test(
		"restart MCU counts and predictor state are local to each scan",
		.disabled("Pending approved reader implementation"))
	func restartStateIsLocalToEachScan() throws {
		Issue.record("Pending behavioral assertions")
	}

	@Test("DHT selectors, limits and duplicate values are validated")
	func dhtValidationMatchesSource() throws {
		let base = try Self.fixture("small_444")
		for selector in [UInt8(0x00), 0x01, 0x02, 0x03, 0x10, 0x11, 0x12, 0x13] {
			let definition = Self.dhtDefinition(
				selector: selector, counts: [1], values: [0])
			#expect(throws: Never.self) {
				try JPEGParser.parse(
					Self.withMarker(0xC4, payload: definition, in: base))
			}
		}
		for selector in [UInt8(0x04), 0x0F, 0x14, 0x20, 0xFF] {
			let result = Self.withMarker(0xC4, payload: [selector], in: base)
			#expect(
				throws: JPEGParseError.invalidHuffmanTable(
					isAC: selector >> 4 == 1, index: Int(selector & 15))
			) {
				try JPEGParser.parse(result)
			}
		}
		let maxDC = Self.dhtDefinition(
			selector: 0x03, counts: [0, 0, 0, 11, 1], values: Array(0...11))
		let maxAC = Self.dhtDefinition(
			selector: 0x13, counts: [0, 0, 0, 0, 0, 0, 0, 0, 255, 1],
			values: Array(0...255).map(UInt8.init))
		#expect(throws: Never.self) {
			try JPEGParser.parse(
				Self.withMarker(0xC4, payload: maxDC + maxAC, in: base))
		}
		for (selector, values): (UInt8, [UInt8]) in [(0, [12])] {
			let definition = Self.dhtDefinition(
				selector: selector, counts: [UInt8(values.count)], values: values)
			#expect(
				throws: JPEGParseError.invalidHuffmanTable(
					isAC: selector == 0x10, index: Int(selector & 15))
			) {
				try JPEGParser.parse(
					Self.withMarker(0xC4, payload: definition, in: base))
			}
		}
		let duplicateAC = Self.dhtDefinition(
			selector: 0x10, counts: [1, 1], values: [7, 7])
		#expect(
			throws: JPEGParseError.invalidHuffmanTable(isAC: true, index: 0)
		) {
			try JPEGParser.parse(Self.withMarker(0xC4, payload: duplicateAC, in: base))
		}
		let tooManyDC = Self.dhtDefinition(selector: 0, counts: [13], values: Array(0...12))
		#expect(throws: JPEGParseError.invalidHuffmanTable(isAC: false, index: 0)) {
			try JPEGParser.parse(Self.withMarker(0xC4, payload: tooManyDC, in: base))
		}
		var overfullACCounts = [UInt8](repeating: 0, count: 16)
		overfullACCounts[7] = 255
		overfullACCounts[8] = 2
		let tooManyAC = Self.dhtDefinition(
			selector: 0x10, counts: overfullACCounts,
			values: Array(0...255).map(UInt8.init) + [0])
		#expect(throws: JPEGParseError.invalidHuffmanTable(isAC: true, index: 0)) {
			try JPEGParser.parse(Self.withMarker(0xC4, payload: tooManyAC, in: base))
		}
	}

	@Test("every DHT read stays inside its exact declared segment")
	func dhtBoundsAreExact() throws {
		let base = try Self.fixture("small_444")
		let selector: [UInt8] = [0]
		let shortCounts = selector + [UInt8](repeating: 0, count: 16)
		let missingValueCounts = [UInt8(0), 1] + [UInt8](repeating: 0, count: 15)
		let cases: [([UInt8], Int)] = [
			(selector, 3),
			(shortCounts, 10),
			(missingValueCounts + [0], 19),
		]
		for (payload, length) in cases {
			let malformed = Self.withDHT(payload, declaredLength: length, in: base)
			#expect(throws: JPEGParseError.invalidSegmentLength(marker: 0xC4)) {
				try JPEGParser.parse(malformed)
			}
		}
	}

	@Test("empty DHT segments preserve tables and empty definitions replace them")
	func dhtRedefinitionsReplaceTables() throws {
		let base = try Self.fixture("small_444")
		let baseline = try JPEGParser.parse(base)
		let emptySegment = try JPEGParser.parse(
			Self.withMarker(0xC4, payload: [], in: base))
		#expect(emptySegment.components == baseline.components)
		let zeroDC = Self.dhtDefinition(selector: 0, counts: [], values: [])
		let replaced = Self.withDHTAfterExisting(zeroDC, in: base)
		#expect(throws: JPEGParseError.invalidHuffmanCode) {
			try JPEGParser.parse(replaced)
		}
		let dhtOffset = try #require(Self.segmentOffset(base, marker: 0xC4))
		let dhtLength = Int(base[dhtOffset]) << 8 | Int(base[dhtOffset + 1])
		let originalDefinitions = Array(base[(dhtOffset + 2)..<(dhtOffset + dhtLength)])
		let restored = Self.withDHTAfterExisting(zeroDC + originalDefinitions, in: base)
		#expect(throws: Never.self) { try JPEGParser.parse(restored) }
		let sparse = Self.dhtDefinition(selector: 0, counts: [1, 1], values: [0, 1])
		let short = Self.dhtDefinition(selector: 0, counts: [1], values: [0])
		let denseToSparse = Self.withDHTAfterExisting(sparse, in: base)
		let longToShort = Self.withDHTAfterExisting(
			Self.dhtDefinition(
				selector: 0, counts: [0, 0, 0, 0, 0, 0, 0, 0, 1], values: [0])
				+ short,
			in: base)
		#expect(throws: JPEGParseError.invalidHuffmanCode) {
			try JPEGParser.parse(denseToSparse)
		}
		#expect(throws: JPEGParseError.invalidHuffmanCode) {
			try JPEGParser.parse(longToShort)
		}
	}

	static func dhtDefinition(selector: UInt8, counts: [UInt8], values: [UInt8]) -> [UInt8] {
		precondition(counts.count <= 16)
		return [selector] + counts + [UInt8](repeating: 0, count: 16 - counts.count)
			+ values
	}

	static func withDHT(_ payload: [UInt8], declaredLength: Int, in data: [UInt8]) -> [UInt8] {
		let segment =
			[
				UInt8(0xFF), 0xC4, UInt8(declaredLength >> 8),
				UInt8(declaredLength & 255),
			] + payload
		return Array(data.prefix(2)) + segment + Array(data.dropFirst(2))
	}

	static func withDHTAfterExisting(_ payload: [UInt8], in data: [UInt8]) -> [UInt8] {
		guard let offset = segmentOffset(data, marker: 0xC4) else { return data }
		let end = offset + (Int(data[offset]) << 8 | Int(data[offset + 1]))
		let length = payload.count + 2
		let segment: [UInt8] =
			[0xFF, 0xC4, UInt8(length >> 8), UInt8(length & 255)] + payload
		return Array(data[..<end]) + segment + Array(data[end...])
	}

	@Test(
		"APP0, first valid Adobe marker, and ordered component IDs determine color eligibility"
	)
	func markerColorPrecedence() throws {
		let base = try Self.fixture("small_444")
		#expect(
			try !JPEGParser.parse(Self.fixture("rgb_color"))
				.hasSupportedColorInterpretation)
		let noAPP0 = Self.withoutMarker(0xE0, in: base)
		let rgbIDs = Self.withRGBIDs(noAPP0)
		#expect(try !JPEGParser.parse(rgbIDs).hasSupportedColorInterpretation)
		#expect(
			try JPEGParser.parse(Self.withMarker(0xE0, payload: [0], in: rgbIDs))
				.hasSupportedColorInterpretation)
		#expect(
			try JPEGParser.parse(
				Self.withMarkers([(0xE0, [0]), (0xEE, Self.adobe(0))], in: rgbIDs)
			)
			.hasSupportedColorInterpretation)
		#expect(
			try JPEGParser.parse(
				Self.withMarker(0xEE, payload: Self.adobe(0), in: noAPP0)
			)
			.hasSupportedColorInterpretation == false)
		#expect(
			try JPEGParser.parse(
				Self.withMarker(0xEE, payload: Self.adobe(1), in: noAPP0)
			)
			.hasSupportedColorInterpretation)
		#expect(
			try JPEGParser.parse(
				Self.withMarker(0xEE, payload: Self.adobe(2), in: noAPP0)
			)
			.hasSupportedColorInterpretation)
		let firstWins = Self.withMarkers(
			[
				(0xEE, Self.adobe(0)), (0xEE, Self.adobe(1)),
			], in: noAPP0)
		#expect(try !JPEGParser.parse(firstWins).hasSupportedColorInterpretation)
		let invalidThenValid = Self.withMarkers(
			[
				(0xEE, Array(Self.adobe(0).prefix(11))), (0xEE, Self.adobe(1)),
			], in: noAPP0)
		#expect(try JPEGParser.parse(invalidThenValid).hasSupportedColorInterpretation)
		let overlongThenValid = Self.withMarkers(
			[(0xEE, Self.adobe(0) + [0]), (0xEE, Self.adobe(2))], in: noAPP0)
		#expect(try JPEGParser.parse(overlongThenValid).hasSupportedColorInterpretation)
		var wrongSignature = Self.adobe(0)
		wrongSignature[0] = 0x58
		#expect(
			try JPEGParser.parse(
				Self.withMarker(0xEE, payload: wrongSignature, in: noAPP0)
			).hasSupportedColorInterpretation)
		#expect(
			try JPEGParser.parse(Self.withComponentIDs([0x31, 0x32, 0x33], in: noAPP0))
				.hasSupportedColorInterpretation)
		#expect(
			try JPEGParser.parse(Self.withComponentIDs([0x52, 0x42, 0x47], in: noAPP0))
				.hasSupportedColorInterpretation)

		let afterScan = Self.withMarkerAfterScan(0xE0, payload: [0], in: rgbIDs)
		#expect(try JPEGParser.parse(afterScan).hasSupportedColorInterpretation)
		let afterScanAdobe = Self.withMarkerAfterScan(
			0xEE, payload: Self.adobe(0), in: noAPP0)
		#expect(try !JPEGParser.parse(afterScanAdobe).hasSupportedColorInterpretation)
		let afterScanICC = Self.withMarkerAfterScan(
			0xE2, payload: Array("ICC_PROFILE\0".utf8) + [1, 1], in: noAPP0)
		#expect(try !JPEGParser.parse(afterScanICC).hasSupportedColorInterpretation)
		let gray = try Self.fixture("hopper_gray_odd")
		#expect(
			try JPEGParser.parse(
				Self.withMarker(0xEE, payload: Self.adobe(0), in: gray)
			)
			.hasSupportedColorInterpretation)
		#expect(
			try JPEGParser.parse(rgbIDs).components.map(\.coefficients)
				== JPEGParser.parse(noAPP0).components.map(\.coefficients))
		#expect(
			try JPEGParser.parse(afterScanAdobe).components.map(\.coefficients)
				== JPEGParser.parse(noAPP0).components.map(\.coefficients))
		#expect(
			try JPEGParser.parse(afterScanICC).components.map(\.coefficients)
				== JPEGParser.parse(noAPP0).components.map(\.coefficients))
	}

	@Test(
		"fully tagged ICC metadata declines coefficient recompression")
	func iccProfileEligibility() throws {
		let base = try Self.fixture("small_444")
		#expect(
			try !JPEGParser.parse(Self.fixture("display_p3_profile"))
				.hasSupportedColorInterpretation)
		let tag: [UInt8] = Array("ICC_PROFILE\0".utf8)
		for tail: [UInt8] in [[], [0, 1], [1, 1, 1, 2], [1, 2, 1, 2]] {
			let tagged = Self.withMarker(0xE2, payload: tag + tail, in: base)
			#expect(try !JPEGParser.parse(tagged).hasSupportedColorInterpretation)
		}
		for prefix in [
			Array("ICC_PROFIL".utf8), Array("ICC_PROFILE".utf8),
			Array("OTHER_PROFILE\0".utf8),
		] {
			#expect(
				try JPEGParser.parse(
					Self.withMarker(0xE2, payload: prefix, in: base)
				)
				.hasSupportedColorInterpretation)
		}
	}

	static func adobe(_ transform: UInt8) -> [UInt8] {
		Array("Adobe".utf8) + [0, 100, 0, 0, 0, 0, transform]
	}

	static func withMarker(_ marker: UInt8, payload: [UInt8], in data: [UInt8]) -> [UInt8] {
		withMarkers([(marker, payload)], in: data)
	}

	static func withMarkers(_ markers: [(UInt8, [UInt8])], in data: [UInt8]) -> [UInt8] {
		let inserted = markers.flatMap { marker, payload in
			let length = payload.count + 2
			return [0xFF, marker, UInt8(length >> 8), UInt8(length & 255)] + payload
		}
		return Array(data.prefix(2)) + inserted + Array(data.dropFirst(2))
	}

	static func withMarkerAfterScan(_ marker: UInt8, payload: [UInt8], in data: [UInt8])
		-> [UInt8]
	{
		let length = payload.count + 2
		let segment = [0xFF, marker, UInt8(length >> 8), UInt8(length & 255)] + payload
		return Array(data.dropLast(2)) + segment + Array(data.suffix(2))
	}

	static func withRGBIDs(_ data: [UInt8]) -> [UInt8] {
		withComponentIDs([0x52, 0x47, 0x42], in: data)
	}

	static func withComponentIDs(_ ids: [UInt8], in data: [UInt8]) -> [UInt8] {
		var result = data
		guard let lengthOffset = segmentOffset(result, marker: 0xC0) else { return result }
		let payload = lengthOffset + 2
		guard ids.count == 3 else { return result }
		for (index, id) in ids.enumerated() {
			result[payload + 6 + index * 3] = id
		}
		guard let scanLengthOffset = segmentOffset(result, marker: 0xDA) else {
			return result
		}
		let scanPayload = scanLengthOffset + 2
		for (index, id) in ids.enumerated() {
			result[scanPayload + 1 + index * 2] = id
		}
		return result
	}

	static func withoutMarker(_ marker: UInt8, in data: [UInt8]) -> [UInt8] {
		guard let lengthOffset = segmentOffset(data, marker: marker) else { return data }
		let start = lengthOffset - 2
		let length = (Int(data[lengthOffset]) << 8) | Int(data[lengthOffset + 1])
		let end = lengthOffset + length
		return Array(data[..<start]) + Array(data[end...])
	}

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
			let length = (Int(data[index + 2]) << 8) | Int(data[index + 3])
			index += 2 + length
		}
		return nil
	}
}
