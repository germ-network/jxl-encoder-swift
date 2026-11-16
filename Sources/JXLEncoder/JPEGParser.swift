//
//  JPEGParser.swift
//  JXLEncoder
//
//  Baseline JPEG parsing down to quantized DCT coefficients — ISO/IEC 10918-1
//  Annexes B and F.
//
//  The output stops at the coefficients: no dequantization, no inverse DCT, no
//  colour transform. Everything outside sequential Huffman coding is rejected
//  with a specific error rather than approximated, because the caller's
//  fallback is a full decoder and a wrong answer is worse than no answer.
//

public enum JPEGParseError: Error, Equatable, Sendable {
	case missingStartOfImage
	case unexpectedEndOfData
	case invalidSegmentLength(marker: UInt8)
	/// SOF2.
	case progressiveNotSupported
	/// SOF9, SOF10, SOF11, SOF13-15, or a DAC segment.
	case arithmeticCodingNotSupported
	/// SOF3.
	case losslessNotSupported
	/// SOF5, SOF6, SOF7.
	case differentialNotSupported
	/// A frame or scan the parser has no rule for, including DHP hierarchical
	/// mode. The marker's low byte identifies it.
	case unsupportedFrameType(marker: UInt8)
	/// Only 8-bit samples are handled; 12-bit needs wider coefficients and a
	/// different DC category range.
	case unsupportedSamplePrecision(Int)
	case unsupportedComponentCount(Int)
	case unsupportedSamplingFactors(horizontal: Int, vertical: Int)
	case multipleFramesNotSupported
	/// A component selected by more than one sequential scan.
	case multipleScansNotSupported
	/// A component identifier repeated within a frame or scan header.
	case duplicateComponentIdentifier(identifier: UInt8)
	/// More than one restart-interval definition in the input.
	case duplicateRestartInterval
	case missingFrameHeader
	case missingScan
	/// Zero width, or the zero height that signals a DNL segment.
	case invalidDimensions(width: Int, height: Int)
	/// The frame's coefficients would exceed the caller's budget. Held in full,
	/// so the frame header decides the allocation before any entropy data is
	/// read.
	case coefficientBudgetExceeded(required: Int, budget: Int)
	/// The scan spectral range is reversed or extends past coefficient 63.
	case invalidScanParameters
	case undefinedQuantTable(index: Int)
	case undefinedHuffmanTable(isAC: Bool, index: Int)
	case invalidQuantTable(index: Int)
	case invalidHuffmanTable(isAC: Bool, index: Int)
	case invalidHuffmanCode
	/// A run length that would place a coefficient past the end of its block.
	case invalidCoefficientRun
	/// The differential DC predictor left the range 8-bit samples can produce.
	case dcCoefficientOutOfRange
	case truncatedEntropyData
	case missingRestartMarker(expected: Int)
	case scanComponentNotInFrame(identifier: UInt8)
}

public struct JPEGComponent: Equatable, Sendable {
	public let identifier: UInt8
	public let horizontalSampling: Int
	public let verticalSampling: Int
	/// Index of this component’s bound values in `JPEGImage.quantTables`.
	/// May exceed the original JPEG destination range after redefinition.
	public let quantTableIndex: Int
	/// Width of `coefficients` in blocks.
	///
	/// For a colour image this is the interleaved MCU grid, `mcusPerLine *
	/// horizontalSampling`, so it can run past the image: the trailing blocks
	/// are coded and stored like any other. The component's own sample width is
	/// `ceil(width * horizontalSampling / maxHorizontalSampling)`.
	public let blocksPerLine: Int
	public let blocksPerColumn: Int
	/// Quantized coefficients, 64 per block, block-raster order, natural
	/// (de-zigzagged) order within each block.
	public let coefficients: [Int32]
}

public struct JPEGImage: Equatable, Sendable {
	var hasSupportedColorInterpretation = true

	public let width: Int
	public let height: Int
	public let components: [JPEGComponent]
	/// Natural-order tables indexed by each component’s `quantTableIndex`.
	/// Original destination slots remain sparse; additional slots preserve
	/// distinct values bound to components before a destination is redefined.
	public let quantTables: [[UInt16]]
	/// MCUs between restart markers, or 0 when the file defines none.
	public let restartInterval: Int

	public var maxHorizontalSampling: Int {
		components.reduce(1) { max($0, $1.horizontalSampling) }
	}
	public var maxVerticalSampling: Int {
		components.reduce(1) { max($0, $1.verticalSampling) }
	}
}

public enum JPEGParser {
	/// Zig-zag scan order (Figure A.6): scan index to natural position.
	static let zigzag: [Int] = [
		0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4,
		5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14,
		21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30,
		37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54,
		47, 55, 62, 63,
	]

	/// Coefficient budget applied when the caller does not name one.
	///
	/// Coefficients cost exactly 12 bytes a pixel at 4:4:4 and 6 at 4:2:0, both
	/// measured. 512 MB therefore admits a 42 MP 4:4:4 frame or an 85 MP 4:2:0
	/// one, so a 48 MP phone photo fits at the subsampling phones actually use —
	/// it needs 279 MB.
	///
	/// Worth noting against the pixel path, which costs roughly 32 bytes a pixel
	/// and needs about 1.5 GB for that same photograph: recompressing a JPEG is
	/// five times cheaper than decoding and re-encoding it.
	public static let defaultMaxCoefficientBytes = 512 << 20

	/// Parses a baseline JPEG to quantized coefficients.
	///
	/// `maxCoefficientBytes` bounds the coefficient planes, which are what a
	/// hostile header buys: a block costs 256 bytes to hold but as little as two
	/// bits to code, so the frame header alone decides the allocation. Since a
	/// genuinely flat image codes that densely too, no ratio against the entropy
	/// data can separate the two without decoding first — libjpeg reaches the
	/// same conclusion and answers it with `max_memory_to_use`, spilling its
	/// coefficient arrays to a backing store rather than refusing them. Nothing
	/// here spills, so the budget is a limit instead.
	///
	/// Bytes rather than pixels because that is what varies: the same dimensions
	/// cost twice as much at 4:4:4 as at 4:2:0.
	public static func parse(
		_ data: [UInt8],
		maxCoefficientBytes: Int = defaultMaxCoefficientBytes
	) throws -> JPEGImage {
		var parser = JPEGSegmentParser(
			data: data, maxCoefficientBytes: maxCoefficientBytes)
		return try parser.run()
	}
}

/// Frame header state, kept apart from `JPEGImage` because the coefficients do
/// not exist until the scan is decoded.
private struct JPEGFrame {
	struct Component {
		let identifier: UInt8
		let horizontalSampling: Int
		let verticalSampling: Int
		let quantTableIndex: Int
	}

	let width: Int
	let height: Int
	let components: [Component]
	let maxHorizontal: Int
	let maxVertical: Int
	let mcusPerLine: Int
	let mcusPerColumn: Int
}

private struct JPEGSegmentParser {
	let data: [UInt8]
	let maxCoefficientBytes: Int
	var index = 0
	var activeQuantTables = [[UInt16]?](repeating: nil, count: 4)
	var boundQuantTables = [[UInt16]?](repeating: nil, count: 4)
	var boundQuantTableIndices: [Int?] = []
	var dcTables = [JPEGHuffmanTable?](repeating: nil, count: 4)
	var acTables = [JPEGHuffmanTable?](repeating: nil, count: 4)
	var restartInterval = 0
	var hasRestartInterval = false
	var frame: JPEGFrame?
	var planes: [[Int32]]?
	var hasAPP0 = false
	var adobeTransform: UInt8?
	var hasICCProfileTag = false

	mutating func run() throws -> JPEGImage {
		guard data.count >= 2, data[0] == 0xFF, data[1] == 0xD8 else {
			throw JPEGParseError.missingStartOfImage
		}
		index = 2

		loop: while true {
			guard let marker = nextMarker() else {
				throw JPEGParseError.unexpectedEndOfData
			}
			switch marker {
			case 0xC0, 0xC1:
				try readFrameHeader(marker: marker)
			case 0xC2:
				throw JPEGParseError.progressiveNotSupported
			case 0xC3:
				throw JPEGParseError.losslessNotSupported
			case 0xC5, 0xC6, 0xC7:
				throw JPEGParseError.differentialNotSupported
			case 0xC9, 0xCA, 0xCB, 0xCC, 0xCD, 0xCE, 0xCF:
				throw JPEGParseError.arithmeticCodingNotSupported
			case 0xC8, 0xDE, 0xDF:
				throw JPEGParseError.unsupportedFrameType(marker: marker)
			case 0xC4:
				try readHuffmanTables()
			case 0xDB:
				try readQuantTables()
			case 0xDD:
				try readRestartInterval()
			case 0xDA:
				try readScan()
			case 0xD9:
				break loop
			case 0xD0...0xD7:
				continue  // standalone markers, no payload
			case 0xE0:
				hasAPP0 = true
				try skipSegment(marker: marker)
			case 0xE2:
				try readICCProfileTag()
			case 0xEE:
				try readAdobeTransform()
			default:
				try skipSegment(marker: marker)
			}
		}

		guard let frame else { throw JPEGParseError.missingFrameHeader }
		guard let planes, boundQuantTableIndices.contains(where: { $0 != nil }) else {
			throw JPEGParseError.missingScan
		}
		for componentIndex in frame.components.indices
		where boundQuantTableIndices[componentIndex] == nil {
			try bindQuantTable(for: componentIndex, frame: frame)
		}
		let components = frame.components.enumerated().map { c, component in
			JPEGComponent(
				identifier: component.identifier,
				horizontalSampling: component.horizontalSampling,
				verticalSampling: component.verticalSampling,
				quantTableIndex: boundQuantTableIndices[c]!,
				blocksPerLine: frame.mcusPerLine * component.horizontalSampling,
				blocksPerColumn: frame.mcusPerColumn * component.verticalSampling,
				coefficients: planes[c])
		}
		for tableIndex in activeQuantTables.indices
		where boundQuantTables[tableIndex] == nil {
			boundQuantTables[tableIndex] = activeQuantTables[tableIndex]
		}
		let highestTable =
			boundQuantTables.lastIndex(where: { $0 != nil }).map { $0 + 1 } ?? 0
		let sourceIsRGB: Bool
		if components.count == 1 || hasAPP0 {
			sourceIsRGB = false
		} else if let adobeTransform {
			sourceIsRGB = adobeTransform == 0
		} else {
			sourceIsRGB = components.map(\.identifier) == [0x52, 0x47, 0x42]
		}
		var image = JPEGImage(
			width: frame.width,
			height: frame.height,
			components: components,
			quantTables: (0..<highestTable).map { boundQuantTables[$0] ?? [] },
			restartInterval: restartInterval)
		image.hasSupportedColorInterpretation = !sourceIsRGB && !hasICCProfileTag
		return image
	}

	// MARK: - Segments

	private mutating func byte() throws -> UInt8 {
		guard index < data.count else { throw JPEGParseError.unexpectedEndOfData }
		defer { index += 1 }
		return data[index]
	}

	private mutating func uint16() throws -> Int {
		let high = try byte()
		return Int(high) << 8 | Int(try byte())
	}

	/// Advances to a recognized marker, skipping fill and inter-marker bytes.
	private mutating func nextMarker() -> UInt8? {
		while index + 1 < data.count {
			guard data[index] == 0xFF else {
				index += 1
				continue
			}
			let marker = data[index + 1]
			guard Self.isMarker(marker) else {
				index += 1
				continue
			}
			index += 2
			return marker
		}
		index = data.count
		return nil
	}

	private static func isMarker(_ marker: UInt8) -> Bool {
		switch marker {
		case 0xC0...0xCF, 0xD0...0xD7, 0xD9...0xDB, 0xDD...0xDF,
			0xE0...0xEF, 0xFE:
			true
		default:
			false
		}
	}

	/// Segment length covers itself, so the payload is `length - 2` bytes.
	private mutating func segmentEnd(marker: UInt8) throws -> Int {
		let length = try uint16()
		let end = index + length - 2
		guard length >= 2, end <= data.count else {
			throw JPEGParseError.invalidSegmentLength(marker: marker)
		}
		return end
	}

	private mutating func skipSegment(marker: UInt8) throws {
		index = try segmentEnd(marker: marker)
	}

	private mutating func readAdobeTransform() throws {
		let end = try segmentEnd(marker: 0xEE)
		let payloadLength = end - index
		if adobeTransform == nil, payloadLength == 12,
			data[index..<(index + 5)].elementsEqual([0x41, 0x64, 0x6F, 0x62, 0x65])
		{
			adobeTransform = data[index + 11]
		}
		index = end
	}

	private mutating func readICCProfileTag() throws {
		let end = try segmentEnd(marker: 0xE2)
		let signature: [UInt8] = [
			0x49, 0x43, 0x43, 0x5F, 0x50, 0x52, 0x4F, 0x46, 0x49, 0x4C, 0x45, 0,
		]
		if end - index >= signature.count,
			data[index..<(index + signature.count)].elementsEqual(signature)
		{
			hasICCProfileTag = true
		}
		index = end
	}

	private mutating func readFrameHeader(marker: UInt8) throws {
		guard frame == nil else { throw JPEGParseError.multipleFramesNotSupported }
		let end = try segmentEnd(marker: marker)
		guard end - index >= 6 else {
			throw JPEGParseError.invalidSegmentLength(marker: marker)
		}

		let precision = Int(try byte())
		guard precision == 8 else {
			throw JPEGParseError.unsupportedSamplePrecision(precision)
		}
		let height = try uint16()
		let width = try uint16()
		guard width > 0, height > 0 else {
			throw JPEGParseError.invalidDimensions(width: width, height: height)
		}
		let count = Int(try byte())
		guard count == 1 || count == 3 else {
			throw JPEGParseError.unsupportedComponentCount(count)
		}
		guard end == index + count * 3 else {
			throw JPEGParseError.invalidSegmentLength(marker: marker)
		}

		var components: [JPEGFrame.Component] = []
		var identifiers = Set<UInt8>()
		for _ in 0..<count {
			let identifier = try byte()
			guard identifiers.insert(identifier).inserted else {
				throw JPEGParseError.duplicateComponentIdentifier(
					identifier: identifier)
			}
			let sampling = try byte()
			let horizontal = Int(sampling >> 4)
			let vertical = Int(sampling & 0x0F)
			guard (1...4).contains(horizontal), (1...4).contains(vertical) else {
				throw JPEGParseError.unsupportedSamplingFactors(
					horizontal: horizontal, vertical: vertical)
			}
			let quantTableIndex = Int(try byte())
			guard quantTableIndex < 4 else {
				throw JPEGParseError.undefinedQuantTable(index: quantTableIndex)
			}
			components.append(
				JPEGFrame.Component(
					identifier: identifier, horizontalSampling: horizontal,
					verticalSampling: vertical, quantTableIndex: quantTableIndex
				))
		}

		let maxHorizontal = components.reduce(1) { max($0, $1.horizontalSampling) }
		let maxVertical = components.reduce(1) { max($0, $1.verticalSampling) }
		guard
			components.allSatisfy({
				maxHorizontal.isMultiple(of: $0.horizontalSampling)
					&& maxVertical.isMultiple(of: $0.verticalSampling)
			})
		else {
			throw JPEGParseError.unsupportedSamplingFactors(
				horizontal: maxHorizontal, vertical: maxVertical)
		}
		frame = JPEGFrame(
			width: width,
			height: height,
			components: components,
			maxHorizontal: maxHorizontal,
			maxVertical: maxVertical,
			mcusPerLine: ceilDiv(width, 8 * maxHorizontal),
			mcusPerColumn: ceilDiv(height, 8 * maxVertical))
		boundQuantTableIndices = [Int?](repeating: nil, count: count)
	}

	private mutating func readQuantTables() throws {
		let end = try segmentEnd(marker: 0xDB)
		guard index < end else {
			throw JPEGParseError.invalidSegmentLength(marker: 0xDB)
		}
		while index < end {
			let header = try byte()
			let precision = Int(header >> 4)
			let table = Int(header & 0x0F)
			guard table < 4, precision <= 1 else {
				throw JPEGParseError.invalidQuantTable(index: table)
			}
			let tableBytes = 64 * (precision + 1)
			guard index + tableBytes <= end else {
				throw JPEGParseError.invalidSegmentLength(marker: 0xDB)
			}
			var values = [UInt16](repeating: 0, count: 64)
			for k in 0..<64 {
				let value =
					precision == 1 ? UInt16(try uint16()) : UInt16(try byte())
				// A zero divisor would trap in any consumer that dequantizes.
				guard value > 0 else {
					throw JPEGParseError.invalidQuantTable(index: table)
				}
				values[JPEGParser.zigzag[k]] = value
			}
			activeQuantTables[table] = values
		}
		guard index == end else {
			throw JPEGParseError.invalidSegmentLength(marker: 0xDB)
		}
	}

	private mutating func readHuffmanTables() throws {
		let end = try segmentEnd(marker: 0xC4)
		while index < end {
			let header = try byte()
			let tableClass = header >> 4
			let isAC = tableClass == 1
			let table = Int(header & 0x0F)
			guard tableClass <= 1, table < 4 else {
				throw JPEGParseError.invalidHuffmanTable(isAC: isAC, index: table)
			}
			guard index + 16 <= end else {
				throw JPEGParseError.invalidSegmentLength(marker: 0xC4)
			}

			var counts = [Int](repeating: 0, count: 16)
			var total = 0
			for i in 0..<16 {
				counts[i] = Int(try byte())
				total += counts[i]
			}
			guard total <= (isAC ? 256 : 12) else {
				throw JPEGParseError.invalidHuffmanTable(isAC: isAC, index: table)
			}
			guard index + total <= end else {
				throw JPEGParseError.invalidSegmentLength(marker: 0xC4)
			}
			var values = [UInt8](repeating: 0, count: total)
			for i in 0..<total { values[i] = try byte() }

			if !isAC, values.contains(where: { $0 > 11 }) {
				throw JPEGParseError.invalidHuffmanTable(isAC: false, index: table)
			}
			guard Set(values).count == values.count else {
				throw JPEGParseError.invalidHuffmanTable(isAC: isAC, index: table)
			}
			guard let built = JPEGHuffmanTable(counts: counts, values: values) else {
				throw JPEGParseError.invalidHuffmanTable(isAC: isAC, index: table)
			}
			if isAC { acTables[table] = built } else { dcTables[table] = built }
		}
		guard index == end else {
			throw JPEGParseError.invalidSegmentLength(marker: 0xC4)
		}
	}

	private mutating func readRestartInterval() throws {
		guard !hasRestartInterval else {
			throw JPEGParseError.duplicateRestartInterval
		}
		let end = try segmentEnd(marker: 0xDD)
		guard end - index == 2 else {
			throw JPEGParseError.invalidSegmentLength(marker: 0xDD)
		}
		restartInterval = try uint16()
		hasRestartInterval = true
	}

	// MARK: - Scan

	private mutating func readScan() throws {
		guard let frame else { throw JPEGParseError.missingFrameHeader }
		let end = try segmentEnd(marker: 0xDA)
		guard index < end else {
			throw JPEGParseError.invalidSegmentLength(marker: 0xDA)
		}

		let count = Int(try byte())
		guard count > 0, count <= frame.components.count else {
			throw JPEGParseError.multipleScansNotSupported
		}
		guard end == index + count * 2 + 3 else {
			throw JPEGParseError.invalidSegmentLength(marker: 0xDA)
		}
		var dcSelectors = [Int](repeating: 0, count: count)
		var acSelectors = [Int](repeating: 0, count: count)
		var order: [Int] = []
		var identifiers = Set<UInt8>()
		for i in 0..<count {
			let identifier = try byte()
			guard identifiers.insert(identifier).inserted else {
				throw JPEGParseError.duplicateComponentIdentifier(
					identifier: identifier)
			}
			guard
				let component = frame.components.firstIndex(where: {
					$0.identifier == identifier
				})
			else {
				throw JPEGParseError.scanComponentNotInFrame(identifier: identifier)
			}
			let selectors = try byte()
			dcSelectors[i] = Int(selectors >> 4)
			acSelectors[i] = Int(selectors & 0x0F)
			order.append(component)
		}
		let spectralStart = try byte()
		let spectralEnd = try byte()
		_ = try byte()
		guard spectralStart <= spectralEnd, spectralEnd <= 63 else {
			throw JPEGParseError.invalidScanParameters
		}
		guard index == end else {
			throw JPEGParseError.invalidSegmentLength(marker: 0xDA)
		}

		var dc: [JPEGHuffmanTable] = []
		var ac: [JPEGHuffmanTable] = []
		for i in 0..<count {
			guard dcSelectors[i] < 4, let table = dcTables[dcSelectors[i]] else {
				throw JPEGParseError.undefinedHuffmanTable(
					isAC: false, index: dcSelectors[i])
			}
			guard acSelectors[i] < 4, let acTable = acTables[acSelectors[i]] else {
				throw JPEGParseError.undefinedHuffmanTable(
					isAC: true, index: acSelectors[i])
			}
			dc.append(table)
			ac.append(acTable)
		}
		guard order.allSatisfy({ boundQuantTableIndices[$0] == nil }) else {
			throw JPEGParseError.multipleScansNotSupported
		}
		for componentIndex in order {
			try bindQuantTable(for: componentIndex, frame: frame)
		}
		let entropy = scanEntropyBounds(from: index)
		try decodeScan(
			frame: frame, order: order, dcTables: dc, acTables: ac,
			entropyByteCount: entropy.byteCount, scanEnd: entropy.end)
	}

	private mutating func bindQuantTable(for componentIndex: Int, frame: JPEGFrame) throws {
		let destination = frame.components[componentIndex].quantTableIndex
		guard let values = activeQuantTables[destination] else {
			throw JPEGParseError.undefinedQuantTable(index: destination)
		}
		if boundQuantTables[destination] == nil {
			boundQuantTables[destination] = values
			boundQuantTableIndices[componentIndex] = destination
		} else if boundQuantTables[destination] == values {
			boundQuantTableIndices[componentIndex] = destination
		} else {
			let newIndex = boundQuantTables.count
			boundQuantTables.append(values)
			boundQuantTableIndices[componentIndex] = newIndex
		}
	}

	private func scanEntropyBounds(from start: Int) -> (end: Int, byteCount: Int) {
		var cursor = start
		var byteCount = 0
		while cursor < data.count {
			guard data[cursor] == 0xFF else {
				byteCount += 1
				cursor += 1
				continue
			}
			let markerStart = cursor
			var code = cursor + 1
			while code < data.count, data[code] == 0xFF { code += 1 }
			guard code < data.count else { return (markerStart, byteCount) }
			switch data[code] {
			case 0x00:
				byteCount += 1
				cursor = code + 1
			case 0xD0...0xD7:
				cursor = code + 1
			default:
				return (markerStart, byteCount)
			}
		}
		return (data.count, byteCount)
	}

	private mutating func decodeScan(
		frame: JPEGFrame, order: [Int], dcTables: [JPEGHuffmanTable],
		acTables: [JPEGHuffmanTable], entropyByteCount: Int, scanEnd: Int
	) throws {
		let interleaved = order.count > 1
		let codedBlocks: Int
		if interleaved {
			codedBlocks =
				frame.mcusPerLine * frame.mcusPerColumn
				* order.reduce(0) { sum, c in
					let component = frame.components[c]
					return sum + component.horizontalSampling
						* component.verticalSampling
				}
		} else {
			let component = frame.components[order[0]]
			let width = ceilDiv(
				frame.width * component.horizontalSampling, frame.maxHorizontal)
			let height = ceilDiv(
				frame.height * component.verticalSampling, frame.maxVertical)
			codedBlocks = ceilDiv(width, 8) * ceilDiv(height, 8)
		}
		// Every block costs at least a DC code and an end-of-block code, so two
		// bits. Without this a tiny file claiming huge dimensions would have us
		// allocate gigabytes before discovering it is truncated.
		guard entropyByteCount * 4 >= codedBlocks else {
			throw JPEGParseError.truncatedEntropyData
		}
		if planes == nil {
			let paddedBlocks = frame.components.reduce(0) { sum, component in
				sum + frame.mcusPerLine * component.horizontalSampling
					* frame.mcusPerColumn * component.verticalSampling
			}
			let required = paddedBlocks * 64 * MemoryLayout<Int32>.size
			guard required <= maxCoefficientBytes else {
				throw JPEGParseError.coefficientBudgetExceeded(
					required: required, budget: maxCoefficientBytes)
			}
			planes = frame.components.map { component in
				[Int32](
					repeating: 0,
					count: frame.mcusPerLine * component.horizontalSampling
						* frame.mcusPerColumn * component.verticalSampling
						* 64)
			}
		}

		// One MCU's blocks in coding order: each component contributes
		// `horizontal * vertical` of them, at a fixed offset within the MCU.
		// A non-interleaved scan has an MCU of exactly one block, whatever its
		// sampling factors claim.
		var slots: [(component: Int, scan: Int, x: Int, y: Int)] = []
		for (scan, component) in order.enumerated() {
			let sampling = frame.components[component]
			for y in 0..<(interleaved ? sampling.verticalSampling : 1) {
				for x in 0..<(interleaved ? sampling.horizontalSampling : 1) {
					slots.append((component, scan, x, y))
				}
			}
		}

		var reader = JPEGBitReader(data: data, index: index, scanEnd: scanEnd)
		var predictors = [Int32](repeating: 0, count: frame.components.count)
		let singleWidth: Int
		if interleaved {
			singleWidth = frame.mcusPerLine
		} else {
			let c = frame.components[order[0]]
			singleWidth = ceilDiv(
				ceilDiv(frame.width * c.horizontalSampling, frame.maxHorizontal), 8)
		}
		let mcuCount =
			interleaved
			? frame.mcusPerLine * frame.mcusPerColumn
			: singleWidth
				* ceilDiv(
					ceilDiv(
						frame.height
							* frame.components[order[0]]
							.verticalSampling, frame.maxVertical), 8)
		var restartsSeen = 0

		for mcu in 0..<mcuCount {
			if restartInterval > 0, mcu > 0, mcu % restartInterval == 0 {
				_ = try reader.finish()
				try consumeRestartMarker(&reader, expected: restartsSeen % 8)
				restartsSeen += 1
				for i in predictors.indices { predictors[i] = 0 }
			}

			let mcuX = mcu % singleWidth
			let mcuY = mcu / singleWidth
			for slot in slots {
				let component = frame.components[slot.component]
				let row =
					interleaved
					? mcuY * component.verticalSampling + slot.y : mcuY
				let column =
					interleaved
					? mcuX * component.horizontalSampling + slot.x : mcuX
				let block =
					row * (frame.mcusPerLine * component.horizontalSampling)
					+ column
				try decodeBlock(
					into: &planes![slot.component], offset: block * 64,
					dc: dcTables[slot.scan], ac: acTables[slot.scan],
					predictor: &predictors[slot.component], reader: &reader)
			}
		}

		index = try reader.finish()
	}

	/// Restart markers are byte-aligned and cycle RST0...RST7. A mismatch means
	/// the decoder and the stream have lost sync, so it is fatal here rather
	/// than something to resynchronize from.
	private func consumeRestartMarker(
		_ reader: inout JPEGBitReader, expected: Int
	) throws {
		let position = reader.index
		guard position + 1 < data.count, data[position] == 0xFF,
			data[position + 1] == 0xD0 + UInt8(expected)
		else {
			throw JPEGParseError.missingRestartMarker(expected: expected)
		}
		reader.restart(at: position + 2)
	}
}

/// Beyond anything an 8-bit frame can produce: the DC coefficient of such a
/// frame is bounded by ±1024 times the DCT scale, so this only fires on
/// malformed data, where it stops the predictor accumulating without bound.
private let dcLimit: Int32 = 1 << 20

private func decodeBlock(
	into plane: inout [Int32], offset: Int,
	dc: JPEGHuffmanTable, ac: JPEGHuffmanTable,
	predictor: inout Int32, reader: inout JPEGBitReader
) throws {
	let category = Int(try dc.decode(&reader))
	if category != 0 {
		predictor += extend(reader.read(category), category)
		guard abs(predictor) <= dcLimit else {
			throw JPEGParseError.dcCoefficientOutOfRange
		}
	}
	plane[offset] = predictor

	var k = 1
	while k < 64 {
		let symbol = try ac.decode(&reader)
		let size = Int(symbol & 0x0F)
		let run = Int(symbol >> 4)
		if size == 0 {
			// 0xF0 is a run of 16 zeros; any other zero size ends the block.
			if run != 15 { return }
			k += 16
			continue
		}
		k += run
		guard k < 64 else { throw JPEGParseError.invalidCoefficientRun }
		plane[offset + JPEGParser.zigzag[k]] = extend(reader.read(size), size)
		k += 1
	}
}

/// Sign-extends an `n`-bit magnitude to the symmetric range JPEG codes with it
/// (Figure F.12): the low half of the range is the negative side.
private func extend(_ value: UInt32, _ n: Int) -> Int32 {
	let value = Int32(value)
	return value < (1 << (n - 1)) ? value - (1 << n) + 1 : value
}

private func ceilDiv(_ a: Int, _ b: Int) -> Int {
	(a + b - 1) / b
}
