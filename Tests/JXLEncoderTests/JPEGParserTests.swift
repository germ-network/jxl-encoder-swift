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
	@Test("each selected component binds the quantizer active at its scan")
	func quantizationTablesBindAtSelectedScan() throws {
		let data = try Self.fixture("scan_420_111_dqt_redefined")
		let image = try JPEGParser.parse(data)
		let reference = try JPEGCoefficientDump(fixture: "scan_420_111_dqt_canonical")
		for (parsed, expected) in zip(image.components, reference.components) {
			#expect(parsed.coefficients == expected.coefficients)
			#expect(
				image.quantTables[parsed.quantTableIndex]
					== (try #require(
						reference.quantTables[expected.quantTableIndex])))
		}
		#expect(image.components.map(\.quantTableIndex) == [4, 0, 0])

		var delayed = try Self.fixture("scan_420_111")
		let frame = try #require(Self.segmentOffset(delayed, marker: 0xC0)) + 2
		delayed[frame + 8] = 3
		let scans = Self.markerOffsets(0xDA, in: delayed)
		delayed.insert(
			contentsOf: Self.quantTableSegment(destination: 3, value: 11), at: scans[1])
		let delayedImage = try JPEGParser.parse(delayed)
		#expect(delayedImage.components[0].quantTableIndex == 3)
		#expect(delayedImage.quantTables[3] == [UInt16](repeating: 11, count: 64))

		var missing = try Self.fixture("scan_420_111")
		let missingFrame = try #require(Self.segmentOffset(missing, marker: 0xC0)) + 2
		missing[missingFrame + 8] = 3
		let afterScans = Self.quantTableSegment(destination: 3, value: 11)
		missing = Array(missing.dropLast(2)) + afterScans + Array(missing.suffix(2))
		#expect(throws: JPEGParseError.undefinedQuantTable(index: 3)) {
			try JPEGParser.parse(missing)
		}

		var repeated = try Self.fixture("small_444")
		let repeatedSOS = try #require(Self.markerOffsets(0xDA, in: repeated).first)
		let replacements = (5...10).flatMap {
			Self.quantTableSegment(destination: 0, value: UInt8($0))
		}
		repeated.insert(contentsOf: replacements, at: repeatedSOS)
		let repeatedImage = try JPEGParser.parse(repeated)
		#expect(repeatedImage.quantTables[0] == [UInt16](repeating: 10, count: 64))
	}

	@Test("quantizer replacement preserves previously decoded component meaning")
	func quantizationRedefinitionsPreserveBoundValues() throws {
		var data = try Self.fixture("scan_420_111")
		let frame = try #require(Self.segmentOffset(data, marker: 0xC0)) + 2
		for component in 0..<3 { data[frame + 6 + component * 3 + 2] = 0 }
		let scans = Self.markerOffsets(0xDA, in: data)
		data.insert(
			contentsOf: Self.quantTableSegment(destination: 0, value: 7), at: scans[1])
		let afterFirstReplacement = Self.markerOffsets(0xDA, in: data)
		data.insert(
			contentsOf: Self.quantTableSegment(destination: 0, value: 9),
			at: afterFirstReplacement[2])
		let afterLastScan = Self.quantTableSegment(destination: 0, value: 11)
		data = Array(data.dropLast(2)) + afterLastScan + Array(data.suffix(2))
		let image = try JPEGParser.parse(data)
		#expect(image.components.map(\.quantTableIndex) == [4, 5, 0])
		#expect(image.quantTables[0] != image.quantTables[4])
		#expect(image.quantTables[4] == [UInt16](repeating: 7, count: 64))
		#expect(image.quantTables[5] == [UInt16](repeating: 9, count: 64))
	}

	@Test("scan-bound quantizers preserve sparse destination compatibility")
	func quantizationBindingsPreserveSparseDestinations() throws {
		var data = try Self.fixture("small_444")
		let frame = try #require(Self.segmentOffset(data, marker: 0xC0)) + 2
		let dqt = try #require(Self.segmentOffset(data, marker: 0xDB)) + 2
		data[frame + 8] = 3
		data[dqt] = (data[dqt] & 0xF0) | 3
		let image = try JPEGParser.parse(data)
		#expect(image.components.map(\.quantTableIndex) == [3, 1, 1])
		#expect(image.quantTables.count == 4)
		#expect(image.quantTables[0].isEmpty)
		#expect(!image.quantTables[3].isEmpty)
	}

	@Test("selected marker parsing reaches a required EOI")
	func markerDispatchRequiresEOI() throws {
		let data = try Self.fixture("small_444")
		let baseline = try JPEGParser.parse(data)
		#expect(throws: Never.self) { try JPEGParser.parse(data) }
		let interMarkerData =
			Array(data.prefix(2))
			+ [
				0xFF, 0x00, 0xFF, 0x01, 0xFF, 0xD8, 0xFF, 0xDC, 0, 2,
				0xFF, 0xF0, 0, 2, 0xFF, 0x02, 0xFF, 0xFF,
			]
			+ Array(data.dropFirst(2))
		let interMarkerImage = try JPEGParser.parse(interMarkerData)
		#expect(interMarkerImage.components == baseline.components)
		#expect(interMarkerImage.quantTables == baseline.quantTables)
		#expect(throws: JPEGParseError.unexpectedEndOfData) {
			try JPEGParser.parse(Array(data.dropLast(2)) + [0, 0])
		}
		#expect(
			throws: JPEGParseError.unsupportedFrameType(marker: 0xDE)
		) {
			try JPEGParser.parse(Self.withMarker(0xDE, payload: [], in: data))
		}
	}

	@Test("segment fields stay inside their declared payloads")
	func segmentReadsRespectDeclaredBounds() throws {
		let data = try Self.fixture("small_444")
		for (marker, length): (UInt8, Int) in [(0xC0, 8), (0xDA, 6)] {
			var malformed = data
			let offset = try #require(Self.segmentOffset(malformed, marker: marker))
			malformed[offset] = UInt8(length >> 8)
			malformed[offset + 1] = UInt8(length & 255)
			#expect(throws: JPEGParseError.invalidSegmentLength(marker: marker)) {
				try JPEGParser.parse(malformed)
			}
		}
		let shortSOF: [UInt8] = [0xFF, 0xD8, 0xFF, 0xC0, 0, 2, 0xFF, 0xD9]
		#expect(throws: JPEGParseError.invalidSegmentLength(marker: 0xC0)) {
			try JPEGParser.parse(shortSOF)
		}
		let scanOffset = try #require(Self.segmentOffset(data, marker: 0xDA))
		let shortSOS =
			Array(data.prefix(scanOffset - 2)) + [
				0xFF, 0xDA, 0, 2, 0xFF, 0xD9,
			]
		#expect(throws: JPEGParseError.invalidSegmentLength(marker: 0xDA)) {
			try JPEGParser.parse(shortSOS)
		}
		var malformedDRI = Self.withMarker(0xDD, payload: [0, 1], in: data)
		let driOffset = try #require(Self.segmentOffset(malformedDRI, marker: 0xDD))
		malformedDRI[driOffset] = 0
		malformedDRI[driOffset + 1] = 3
		#expect(throws: JPEGParseError.invalidSegmentLength(marker: 0xDD)) {
			try JPEGParser.parse(malformedDRI)
		}
		let emptyDQT = Self.withMarker(0xDB, payload: [], in: data)
		#expect(throws: JPEGParseError.invalidSegmentLength(marker: 0xDB)) {
			try JPEGParser.parse(emptyDQT)
		}
		var truncatedDQT = Self.withMarker(0xDB, payload: [0], in: data)
		let offset = try #require(Self.segmentOffset(truncatedDQT, marker: 0xDB))
		truncatedDQT[offset] = 0
		truncatedDQT[offset + 1] = 3
		#expect(throws: JPEGParseError.invalidSegmentLength(marker: 0xDB)) {
			try JPEGParser.parse(truncatedDQT)
		}
	}

	@Test("frame and scan component identifiers are unique")
	func componentIdentifiersAreUnique() throws {
		let data = try Self.fixture("small_444")
		let repeatedFrameID = Self.withFrameComponentIDs([1, 1, 3], in: data)
		#expect(throws: JPEGParseError.duplicateComponentIdentifier(identifier: 1)) {
			try JPEGParser.parse(repeatedFrameID)
		}
		let repeatedScanID = Self.withScanComponentIDs([1, 1, 3], in: data)
		#expect(throws: JPEGParseError.duplicateComponentIdentifier(identifier: 1)) {
			try JPEGParser.parse(repeatedScanID)
		}
	}

	@Test("frame sampling ratios are integral")
	func frameSamplingRatiosAreIntegral() throws {
		let data = try Self.fixture("small_444")
		#expect(throws: Never.self) { try JPEGParser.parse(data) }
		var malformed = data
		let offset = try #require(Self.segmentOffset(malformed, marker: 0xC0))
		let payload = offset + 2
		malformed[payload + 7] = 0x32
		malformed[payload + 10] = 0x22
		#expect(
			throws: JPEGParseError.unsupportedSamplingFactors(
				horizontal: 3, vertical: 2)
		) {
			try JPEGParser.parse(malformed)
		}
	}

	@Test("a second restart interval definition is rejected")
	func duplicateRestartIntervalIsRejected() throws {
		let data = try Self.fixture("small_444")
		#expect(throws: Never.self) {
			try JPEGParser.parse(Self.withMarker(0xDD, payload: [0, 0], in: data))
		}
		let duplicated = Self.withMarkers(
			[(0xDD, [0, 0]), (0xDD, [0, 0])], in: data)
		#expect(throws: JPEGParseError.duplicateRestartInterval) {
			try JPEGParser.parse(duplicated)
		}
	}

	@Test(
		"disjoint sequential scan partitions recover exact coefficients")
	func sequentialScanPartitionsMatchReference() throws {
		for name in ["scan_420_111", "scan_422_21", "scan_440_12"] {
			let reference = try JPEGCoefficientDump(fixture: name)
			let image = try JPEGParser.parse(Self.fixture(name))
			#expect(image.width == reference.width)
			#expect(image.height == reference.height)
			try #require(image.components.count == reference.components.count)
			for (parsed, expected) in zip(image.components, reference.components) {
				#expect(parsed.identifier == expected.identifier)
				#expect(parsed.blocksPerLine == expected.blocksPerLine)
				#expect(parsed.blocksPerColumn == expected.blocksPerColumn)
				#expect(
					Self.firstDifference(
						parsed.coefficients, expected.coefficients) == nil,
					"component \(parsed.identifier) differs from libjpeg")
			}
		}
		let data = try Self.fixture("scan_420_111")
		let scans = Self.markerOffsets(0xDA, in: data)
		let huffmanDefinitions = Self.markerOffsets(0xC4, in: data)
		try #require(scans.count == 3)
		#expect(huffmanDefinitions.contains { scans[0] < $0 && $0 < scans[1] })
	}

	@Test("scan order preserves frame component identity")
	func reorderedScanComponentsPreserveFrameOrder() throws {
		for name in ["scan_420_111", "scan_422_21", "scan_440_12"] {
			let image = try JPEGParser.parse(Self.fixture(name))
			#expect(image.components.map(\.identifier) == [1, 2, 3])
		}
	}

	@Test("single-component scans preserve padded storage and zero edges")
	func singleComponentScansUsePaddedStride() throws {
		let image = try JPEGParser.parse(Self.fixture("scan_420_111"))
		let reference = try JPEGCoefficientDump(fixture: "scan_420_111")
		for (component, expected) in zip(image.components, reference.components) {
			#expect(
				component.coefficients.count == component.blocksPerLine
					* component.blocksPerColumn * 64)
			#expect(
				Self.firstDifference(component.coefficients, expected.coefficients)
					== nil)
		}
		let chroma = image.components[1]
		let codedWidth = (image.width + 15) / 16
		let codedHeight = (image.height + 15) / 16
		#expect(chroma.blocksPerLine == codedWidth)
		#expect(chroma.blocksPerColumn == codedHeight)
	}

	@Test("unvisited components remain zero-filled when EOI follows one scan")
	func unvisitedSequentialComponentsRemainZero() throws {
		let data = try Self.fixture("scan_420_111")
		let firstScan = try #require(Self.markerOffsets(0xDA, in: data).first)
		let nextTable = try #require(
			Self.markerOffsets(0xC4, in: data).first(where: { $0 > firstScan }))
		var partial = Array(data[..<nextTable]) + [0xFF, 0xD9]
		partial[Self.frameComponentQuantOffset(partial, component: 2)!] = 0
		let image = try JPEGParser.parse(partial)
		#expect(image.components[0].coefficients.allSatisfy { $0 == 0 })
		#expect(image.components[1].coefficients.allSatisfy { $0 == 0 })
		#expect(image.components[2].coefficients.contains { $0 != 0 })
		var lateTable = Array(partial.dropLast(2))
		lateTable += Self.quantTableSegment(destination: 0, value: 13)
		lateTable += [0xFF, 0xD9]
		let finalized = try JPEGParser.parse(lateTable)
		#expect(finalized.components[0].quantTableIndex == 4)
		#expect(finalized.components[2].quantTableIndex == 0)
		#expect(finalized.components[0].coefficients.allSatisfy { $0 == 0 })
		#expect(finalized.quantTables[0] != finalized.quantTables[4])
		#expect(finalized.quantTables[4] == [UInt16](repeating: 13, count: 64))

		var missingFinalTable = Array(data[..<nextTable]) + [0xFF, 0xD9]
		missingFinalTable[
			Self.frameComponentQuantOffset(missingFinalTable, component: 0)!] = 3
		#expect(throws: JPEGParseError.undefinedQuantTable(index: 3)) {
			try JPEGParser.parse(missingFinalTable)
		}
	}

	@Test("later scan bytes cannot satisfy an earlier scan's entropy floor")
	func scanEntropyFloorUsesOnlyCurrentScanBytes() throws {
		let source = try Self.fixture("scan_420_111")
		let originalScan = try #require(Self.markerOffsets(0xDA, in: source).first)
		let invalidDC =
			[0xFF, 0xC4, 0, 20, 0x03, 1]
			+ [UInt8](repeating: 0, count: 15) + [0]
		let data =
			Array(source[..<originalScan]) + invalidDC + Array(source[originalScan...])
		let firstScan = try #require(Self.markerOffsets(0xDA, in: data).first)
		let nextTable = try #require(
			Self.markerOffsets(0xC4, in: data).first(where: { $0 > firstScan }))
		let entropyStart = firstScan + 10
		var truncated = Array(data[..<entropyStart]) + [0x80] + Array(data[nextTable...])
		truncated[firstScan + 6] = (truncated[firstScan + 6] & 0x0F) | 0x30
		#expect(throws: JPEGParseError.truncatedEntropyData) {
			try JPEGParser.parse(truncated)
		}
	}

	@Test("sequential scans cannot decode a component twice")
	func sequentialScansRejectOverlap() throws {
		var data = try Self.fixture("scan_420_111")
		let scans = Self.markerOffsets(0xDA, in: data)
		try #require(scans.count == 3)
		data[scans[1] + 5] = 3
		#expect(throws: JPEGParseError.multipleScansNotSupported) {
			try JPEGParser.parse(data)
		}
	}

	@Test(
		"range-valid sequential scan fields use source normalization")
	func sequentialScanParametersFollowSource() throws {
		let data = try Self.fixture("small_444")
		let baseline = try JPEGParser.parse(data)
		for parameters: [UInt8] in [[1, 1, 0], [63, 63, 0], [0, 63, 0x31]] {
			var modified = data
			let sos = try #require(Self.markerOffsets(0xDA, in: modified).first)
			let parametersOffset = sos + 5 + 2 * 3
			modified.replaceSubrange(
				parametersOffset..<(parametersOffset + 3), with: parameters)
			#expect(try JPEGParser.parse(modified).components == baseline.components)
		}
	}

	static func markerOffsets(_ marker: UInt8, in data: [UInt8]) -> [Int] {
		guard data.count > 1 else { return [] }
		return (0..<(data.count - 1)).filter {
			data[$0] == 0xFF && data[$0 + 1] == marker
		}
	}

	@Test(
		"restart MCU counts and predictor state are local to each scan",
	)
	func restartStateIsLocalToEachScan() throws {
		let data = try Self.fixture("scan_420_111_restart")
		let reference = try JPEGCoefficientDump(fixture: "scan_420_111_restart")
		let image = try JPEGParser.parse(data)
		#expect(image.restartInterval == 1)
		try #require(image.components.count == reference.components.count)
		for (parsed, expected) in zip(image.components, reference.components) {
			#expect(
				Self.firstDifference(parsed.coefficients, expected.coefficients)
					== nil,
				"component \(parsed.identifier) differs from libjpeg")
		}
		let scans = Self.markerOffsets(0xDA, in: data)
		let restarts = Self.restartMarkerOffsets(data)
		try #require(scans.count == 3)
		try #require(restarts.count > 8)
		for scan in scans.indices {
			let upperBound = scan + 1 < scans.count ? scans[scan + 1] : data.count
			let current = restarts.filter { $0 > scans[scan] && $0 < upperBound }
			try #require(!current.isEmpty)
			#expect(data[current[0] + 1] == 0xD0)
		}

		var wrongSecondScan = data
		let secondScanRestart = try #require(
			restarts.first(where: { $0 > scans[1] && $0 < scans[2] }))
		wrongSecondScan[secondScanRestart + 1] = 0xD1
		#expect(throws: JPEGParseError.missingRestartMarker(expected: 0)) {
			try JPEGParser.parse(wrongSecondScan)
		}

		let firstRestart = restarts[0]
		let missing =
			Array(data[..<firstRestart]) + Array(data[(firstRestart + 2)...])
		#expect(throws: JPEGParseError.missingRestartMarker(expected: 0)) {
			try JPEGParser.parse(missing)
		}

		let extraFill =
			Array(data[..<firstRestart]) + [0xFF] + Array(data[firstRestart...])
		#expect(throws: JPEGParseError.missingRestartMarker(expected: 0)) {
			try JPEGParser.parse(extraFill)
		}
	}

	static func restartMarkerOffsets(_ data: [UInt8]) -> [Int] {
		guard data.count > 1 else { return [] }
		return (0..<(data.count - 1)).filter {
			data[$0] == 0xFF && (0xD0...0xD7).contains(data[$0 + 1])
		}
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
		"APP0, first valid Adobe marker, and ordered component IDs determine source RGB"
	)
	func markerColorPrecedence() throws {
		let base = try Self.fixture("small_444")
		#expect(
			try JPEGParser.parse(Self.fixture("rgb_color")).sourceIsRGB)
		let noAPP0 = Self.withoutMarker(0xE0, in: base)
		let rgbIDs = Self.withRGBIDs(noAPP0)
		#expect(try JPEGParser.parse(rgbIDs).sourceIsRGB)
		#expect(
			try JPEGParser.parse(Self.withMarker(0xE0, payload: [0], in: rgbIDs))
				.sourceIsRGB == false)
		#expect(
			try JPEGParser.parse(
				Self.withMarkers([(0xE0, [0]), (0xEE, Self.adobe(0))], in: rgbIDs)
			)
			.sourceIsRGB == false)
		#expect(
			try JPEGParser.parse(
				Self.withMarker(0xEE, payload: Self.adobe(0), in: noAPP0)
			)
			.sourceIsRGB)
		#expect(
			try JPEGParser.parse(
				Self.withMarker(0xEE, payload: Self.adobe(1), in: noAPP0)
			)
			.sourceIsRGB == false)
		#expect(
			try JPEGParser.parse(
				Self.withMarker(0xEE, payload: Self.adobe(2), in: noAPP0)
			)
			.sourceIsRGB == false)
		let firstWins = Self.withMarkers(
			[
				(0xEE, Self.adobe(0)), (0xEE, Self.adobe(1)),
			], in: noAPP0)
		#expect(try JPEGParser.parse(firstWins).sourceIsRGB)
		let invalidThenValid = Self.withMarkers(
			[
				(0xEE, Array(Self.adobe(0).prefix(11))), (0xEE, Self.adobe(1)),
			], in: noAPP0)
		#expect(try !JPEGParser.parse(invalidThenValid).sourceIsRGB)
		let overlongThenValid = Self.withMarkers(
			[(0xEE, Self.adobe(0) + [0]), (0xEE, Self.adobe(2))], in: noAPP0)
		#expect(try !JPEGParser.parse(overlongThenValid).sourceIsRGB)
		var wrongSignature = Self.adobe(0)
		wrongSignature[0] = 0x58
		#expect(
			try JPEGParser.parse(
				Self.withMarker(0xEE, payload: wrongSignature, in: noAPP0)
			).sourceIsRGB == false)
		#expect(
			try JPEGParser.parse(Self.withComponentIDs([0x31, 0x32, 0x33], in: noAPP0))
				.sourceIsRGB == false)
		let afterScan = Self.withMarkerAfterScan(0xE0, payload: [0], in: rgbIDs)
		#expect(try !JPEGParser.parse(afterScan).sourceIsRGB)
		let afterScanAdobe = Self.withMarkerAfterScan(
			0xEE, payload: Self.adobe(0), in: noAPP0)
		#expect(try JPEGParser.parse(afterScanAdobe).sourceIsRGB)
		let afterScanICC = Self.withMarkerAfterScan(
			0xE2, payload: Array("ICC_PROFILE\0".utf8) + [1, 1], in: noAPP0)
		#expect(try JPEGParser.parse(afterScanICC).hasICCProfileTag)
		let gray = try Self.fixture("hopper_gray_odd")
		#expect(
			try JPEGParser.parse(
				Self.withMarker(0xEE, payload: Self.adobe(0), in: gray)
			)
			.sourceIsRGB == false)
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
		"ICC signature detection is independent of RGB classification")
	func iccProfileEligibility() throws {
		let base = try Self.fixture("small_444")
		#expect(
			try JPEGParser.parse(Self.fixture("display_p3_profile")).hasICCProfileTag)
		let tag: [UInt8] = Array("ICC_PROFILE\0".utf8)
		let rgbICC = try JPEGParser.parse(
			Self.withMarker(
				0xE2, payload: tag + [1, 1],
				in: Self.withRGBIDs(Self.withoutMarker(0xE0, in: base))))
		#expect(rgbICC.sourceIsRGB)
		#expect(rgbICC.hasICCProfileTag)
		for tail: [UInt8] in [[], [0, 1], [1, 1, 1, 2], [1, 2, 1, 2]] {
			let tagged = Self.withMarker(0xE2, payload: tag + tail, in: base)
			#expect(try JPEGParser.parse(tagged).hasICCProfileTag)
		}
		for prefix in [
			Array("ICC_PROFIL".utf8), Array("ICC_PROFILE".utf8),
			Array("OTHER_PROFILE\0".utf8),
		] {
			#expect(
				try JPEGParser.parse(
					Self.withMarker(0xE2, payload: prefix, in: base)
				)
				.hasICCProfileTag == false)
		}
	}

	static func adobe(_ transform: UInt8) -> [UInt8] {
		Array("Adobe".utf8) + [0, 100, 0, 0, 0, 0, transform]
	}

	static func withMarker(_ marker: UInt8, payload: [UInt8], in data: [UInt8]) -> [UInt8] {
		withMarkers([(marker, payload)], in: data)
	}

	static func quantTableSegment(destination: UInt8, value: UInt8) -> [UInt8] {
		[0xFF, 0xDB, 0, 67, destination]
			+ [UInt8](repeating: value, count: 64)
	}

	static func frameComponentQuantOffset(_ data: [UInt8], component: Int) -> Int? {
		segmentOffset(data, marker: 0xC0).map { $0 + 2 + 6 + component * 3 + 2 }
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

	static func withFrameComponentIDs(_ ids: [UInt8], in data: [UInt8]) -> [UInt8] {
		var result = data
		guard ids.count == 3, let offset = segmentOffset(result, marker: 0xC0) else {
			return result
		}
		let payload = offset + 2
		for (index, id) in ids.enumerated() { result[payload + 6 + index * 3] = id }
		return result
	}

	static func withScanComponentIDs(_ ids: [UInt8], in data: [UInt8]) -> [UInt8] {
		var result = data
		guard ids.count == 3, let offset = segmentOffset(result, marker: 0xDA) else {
			return result
		}
		let payload = offset + 2
		for (index, id) in ids.enumerated() { result[payload + 1 + index * 2] = id }
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
			"hopper_gray_odd", "hopper_gray_2x2_odd", "scan_420_111",
			"scan_420_111_restart", "scan_422_21",
			"scan_440_12",
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
	/// it is always its own maximum, and persistent storage uses the padded MCU grid.
	@Test("a single-component scan uses padded storage stride")
	func nonInterleavedBlockGrid() throws {
		let plain = try JPEGParser.parse(Self.fixture("hopper_gray_odd"))
		#expect(plain.components[0].blocksPerLine == 13)  // ceil(101 / 8)
		#expect(plain.components[0].blocksPerColumn == 9)  // ceil(67 / 8)

		let image = try JPEGParser.parse(Self.fixture("hopper_gray_2x2_odd"))

		#expect(image.components[0].blocksPerLine == 14)
		#expect(image.components[0].blocksPerColumn == 10)
		for y in 0..<9 {
			let row = y * 14 * 64
			#expect(
				Array(image.components[0].coefficients[row..<(row + 13 * 64)])
					== Array(
						plain.components[0].coefficients[
							(y * 13 * 64)..<((y + 1) * 13 * 64)]))
			#expect(
				image.components[0].coefficients[(row + 13 * 64)..<(row + 14 * 64)]
					.allSatisfy { $0 == 0 })
		}
		#expect(image.components[0].coefficients[(9 * 14 * 64)...].allSatisfy { $0 == 0 })
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
