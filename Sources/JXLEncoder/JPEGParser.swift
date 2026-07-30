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
	/// A scan covering a subset of the frame's components, or a second scan.
	/// Legal in sequential JPEG, but vanishingly rare and untested.
	case multipleScansNotSupported
	case missingFrameHeader
	case missingScan
	/// Zero width, or the zero height that signals a DNL segment.
	case invalidDimensions(width: Int, height: Int)
	/// The frame's coefficients would exceed the caller's budget. Held in full,
	/// so the frame header decides the allocation before any entropy data is
	/// read.
	case coefficientBudgetExceeded(required: Int, budget: Int)
	/// Baseline requires a full spectral selection with no successive
	/// approximation.
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
	public let width: Int
	public let height: Int
	public let components: [JPEGComponent]
	/// Indexed by table id, natural order. A slot no component references may
	/// be empty, since ids need not be contiguous.
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
	/// 256 MB, which admits a 20 MP 4:4:4 photograph or a 42 MP 4:2:0 one —
	/// past any phone sensor at the subsampling phones actually use.
	public static let defaultMaxCoefficientBytes = 256 << 20

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
	var quantTables = [[UInt16]?](repeating: nil, count: 4)
	var dcTables = [JPEGHuffmanTable?](repeating: nil, count: 4)
	var acTables = [JPEGHuffmanTable?](repeating: nil, count: 4)
	var restartInterval = 0
	var frame: JPEGFrame?
	var components: [JPEGComponent]?

	mutating func run() throws -> JPEGImage {
		guard data.count >= 2, data[0] == 0xFF, data[1] == 0xD8 else {
			throw JPEGParseError.missingStartOfImage
		}
		index = 2

		loop: while true {
			guard let marker = nextMarker() else {
				// A file that stops right after its last MCU, with no EOI, is
				// still fully decodable.
				guard components != nil else {
					throw JPEGParseError.unexpectedEndOfData
				}
				break loop
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
				guard components == nil else {
					throw JPEGParseError.multipleScansNotSupported
				}
				components = try readScan()
			case 0xD9:
				break loop
			case 0x01, 0xD0...0xD7:
				continue  // standalone markers, no payload
			default:
				try skipSegment(marker: marker)
			}
		}

		guard let frame else { throw JPEGParseError.missingFrameHeader }
		guard let components else { throw JPEGParseError.missingScan }
		let highestTable = quantTables.lastIndex(where: { $0 != nil }).map { $0 + 1 } ?? 0
		return JPEGImage(
			width: frame.width,
			height: frame.height,
			components: components,
			quantTables: (0..<highestTable).map { quantTables[$0] ?? [] },
			restartInterval: restartInterval)
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

	/// Advances to the next marker, skipping any `FF` fill bytes and any stray
	/// bytes between segments. Returns nil at the end of the input.
	private mutating func nextMarker() -> UInt8? {
		while index < data.count, data[index] != 0xFF { index += 1 }
		while index < data.count, data[index] == 0xFF { index += 1 }
		guard index < data.count else { return nil }
		defer { index += 1 }
		return data[index]
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

	private mutating func readFrameHeader(marker: UInt8) throws {
		guard frame == nil else { throw JPEGParseError.multipleFramesNotSupported }
		let end = try segmentEnd(marker: marker)

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
		for _ in 0..<count {
			let identifier = try byte()
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
		frame = JPEGFrame(
			width: width,
			height: height,
			components: components,
			maxHorizontal: maxHorizontal,
			maxVertical: maxVertical,
			mcusPerLine: ceilDiv(width, 8 * maxHorizontal),
			mcusPerColumn: ceilDiv(height, 8 * maxVertical))
	}

	private mutating func readQuantTables() throws {
		let end = try segmentEnd(marker: 0xDB)
		while index < end {
			let header = try byte()
			let precision = Int(header >> 4)
			let table = Int(header & 0x0F)
			guard table < 4, precision <= 1 else {
				throw JPEGParseError.invalidQuantTable(index: table)
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
			quantTables[table] = values
		}
		guard index == end else {
			throw JPEGParseError.invalidSegmentLength(marker: 0xDB)
		}
	}

	private mutating func readHuffmanTables() throws {
		let end = try segmentEnd(marker: 0xC4)
		while index < end {
			let header = try byte()
			let isAC = header >> 4 == 1
			let table = Int(header & 0x0F)
			guard header >> 4 <= 1, table < 4 else {
				throw JPEGParseError.invalidHuffmanTable(isAC: isAC, index: table)
			}

			var counts = [Int](repeating: 0, count: 16)
			var total = 0
			for i in 0..<16 {
				counts[i] = Int(try byte())
				total += counts[i]
			}
			guard index + total <= end else {
				throw JPEGParseError.invalidSegmentLength(marker: 0xC4)
			}
			var values = [UInt8](repeating: 0, count: total)
			for i in 0..<total { values[i] = try byte() }

			// A DC symbol is a magnitude category — a bit count — so it cannot
			// exceed 15. Anything larger means this is not a DC table.
			if !isAC, values.contains(where: { $0 > 15 }) {
				throw JPEGParseError.invalidHuffmanTable(isAC: false, index: table)
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
		let end = try segmentEnd(marker: 0xDD)
		restartInterval = try uint16()
		guard index == end else {
			throw JPEGParseError.invalidSegmentLength(marker: 0xDD)
		}
	}

	// MARK: - Scan

	private mutating func readScan() throws -> [JPEGComponent] {
		guard let frame else { throw JPEGParseError.missingFrameHeader }
		let end = try segmentEnd(marker: 0xDA)

		let count = Int(try byte())
		// The scan has to cover the whole frame. Sequential JPEG may split a
		// frame across several single-component scans, but nothing in practice
		// emits that, so it is declined rather than decoded untested.
		guard count == frame.components.count else {
			throw JPEGParseError.multipleScansNotSupported
		}
		var dcSelectors = [Int](repeating: 0, count: count)
		var acSelectors = [Int](repeating: 0, count: count)
		var order: [Int] = []
		for i in 0..<count {
			let identifier = try byte()
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
		let approximation = try byte()
		guard spectralStart == 0, spectralEnd == 63, approximation == 0 else {
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
		for component in frame.components
		where quantTables[component.quantTableIndex] == nil {
			throw JPEGParseError.undefinedQuantTable(index: component.quantTableIndex)
		}

		return try decodeScan(
			frame: frame, order: order, dcTables: dc, acTables: ac)
	}

	private mutating func decodeScan(
		frame: JPEGFrame, order: [Int], dcTables: [JPEGHuffmanTable],
		acTables: [JPEGHuffmanTable]
	) throws -> [JPEGComponent] {
		let interleaved = frame.components.count > 1
		var blocksPerLine: [Int] = []
		var blocksPerColumn: [Int] = []
		for component in frame.components {
			let horizontal = component.horizontalSampling
			let vertical = component.verticalSampling
			guard interleaved else {
				// A non-interleaved scan codes exactly the component's own
				// blocks, with no MCU padding.
				let width = ceilDiv(frame.width * horizontal, frame.maxHorizontal)
				let height = ceilDiv(frame.height * vertical, frame.maxVertical)
				blocksPerLine.append(ceilDiv(width, 8))
				blocksPerColumn.append(ceilDiv(height, 8))
				continue
			}
			blocksPerLine.append(frame.mcusPerLine * horizontal)
			blocksPerColumn.append(frame.mcusPerColumn * vertical)
		}

		var totalBlocks = 0
		for i in 0..<frame.components.count {
			totalBlocks += blocksPerLine[i] * blocksPerColumn[i]
		}
		// Every block costs at least a DC code and an end-of-block code, so two
		// bits. Without this a tiny file claiming huge dimensions would have us
		// allocate gigabytes before discovering it is truncated.
		guard (data.count - index) * 4 >= totalBlocks else {
			throw JPEGParseError.truncatedEntropyData
		}
		// That rule is the information-theoretic floor, which leaves 256 bytes
		// of coefficients authorised by two bits of input. The budget is what
		// actually bounds it.
		let required = totalBlocks * 64 * MemoryLayout<Int32>.size
		guard required <= maxCoefficientBytes else {
			throw JPEGParseError.coefficientBudgetExceeded(
				required: required, budget: maxCoefficientBytes)
		}

		var planes: [[Int32]] = []
		for i in 0..<frame.components.count {
			planes.append(
				[Int32](
					repeating: 0,
					count: blocksPerLine[i] * blocksPerColumn[i] * 64))
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

		var reader = JPEGBitReader(data: data, index: index)
		var predictors = [Int32](repeating: 0, count: frame.components.count)
		let mcuCount =
			interleaved
			? frame.mcusPerLine * frame.mcusPerColumn
			: blocksPerLine[0] * blocksPerColumn[0]
		var restartsSeen = 0

		for mcu in 0..<mcuCount {
			if restartInterval > 0, mcu > 0, mcu % restartInterval == 0 {
				try consumeRestartMarker(&reader, expected: restartsSeen % 8)
				restartsSeen += 1
				for i in predictors.indices { predictors[i] = 0 }
			}

			let mcuX = mcu % frame.mcusPerLine
			let mcuY = mcu / frame.mcusPerLine
			for slot in slots {
				let component = frame.components[slot.component]
				let row = mcuY * component.verticalSampling + slot.y
				let column = mcuX * component.horizontalSampling + slot.x
				// A non-interleaved scan's MCU is a single block, walked in the
				// component's own raster order rather than over the MCU grid.
				let block =
					interleaved
					? row * blocksPerLine[slot.component] + column : mcu
				try decodeBlock(
					into: &planes[slot.component], offset: block * 64,
					dc: dcTables[slot.scan], ac: acTables[slot.scan],
					predictor: &predictors[slot.component], reader: &reader)
			}

			guard reader.paddedBytes <= paddingBudget else {
				throw JPEGParseError.truncatedEntropyData
			}
		}

		index = reader.index
		return frame.components.enumerated().map { c, component in
			JPEGComponent(
				identifier: component.identifier,
				horizontalSampling: component.horizontalSampling,
				verticalSampling: component.verticalSampling,
				quantTableIndex: component.quantTableIndex,
				blocksPerLine: blocksPerLine[c],
				blocksPerColumn: blocksPerColumn[c],
				coefficients: planes[c])
		}
	}

	/// Restart markers are byte-aligned and cycle RST0...RST7. A mismatch means
	/// the decoder and the stream have lost sync, so it is fatal here rather
	/// than something to resynchronize from.
	private func consumeRestartMarker(
		_ reader: inout JPEGBitReader, expected: Int
	) throws {
		var position = reader.index
		while position + 1 < data.count, data[position] == 0xFF,
			data[position + 1] == 0xFF
		{
			position += 1  // fill byte
		}
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

/// The bit reader zero-pads once it reaches a marker or the end of the input.
/// A few padded bytes are the normal lookahead while finishing the last MCU;
/// more than that means the entropy data ran out early.
private let paddingBudget = 8

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
