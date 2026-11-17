import Foundation
import Testing

@testable import JXLEncoder

@Suite("JPEG chroma from luma")
struct JPEGCfLTests {
	@Test("Zero quantizers and excessive ratios fail before applicability gates")
	func jpegCfLRejectsZeroQuantizationAndExcessiveRatio() throws {
		let unit = [UInt16](repeating: 1, count: 64)
		var zero = unit
		zero[0] = 0
		#expect(
			throws: JPEGTranscode.TranscodeError.invalidQuantizationTable(
				index: 0, coefficient: 0)
		) {
			_ = try Self.transcode(
				luma: [Int32](repeating: 0, count: 64),
				cb: [Int32](repeating: 0, count: 64),
				cr: [Int32](repeating: 0, count: 64),
				quantTables: [zero, unit, unit])
		}
		for index in [-1, 3] {
			#expect(
				throws: JPEGTranscode.TranscodeError.missingQuantTable(index: index)
			) {
				try Self.transcode(
					luma: [Int32](repeating: 0, count: 64),
					cb: [Int32](repeating: 0, count: 64),
					cr: [Int32](repeating: 0, count: 64),
					componentQuantTableIndexes: [1, index, 2])
			}
		}
		var zeroAC = unit
		zeroAC[1] = 0
		#expect(
			throws: JPEGTranscode.TranscodeError.invalidQuantizationTable(
				index: 0, coefficient: 1)
		) {
			_ = try Self.transcode(
				luma: [Int32](repeating: 0, count: 64),
				cb: [Int32](repeating: 0, count: 64),
				cr: [Int32](repeating: 0, count: 64),
				quantTables: [zeroAC, unit, unit])
		}
		let gray = JPEGImage(
			width: 8, height: 8,
			components: [
				JPEGComponent(
					identifier: 1, horizontalSampling: 1, verticalSampling: 1,
					quantTableIndex: 0, blocksPerLine: 1, blocksPerColumn: 1,
					coefficients: [Int32](repeating: 0, count: 64))
			],
			quantTables: [zeroAC], restartInterval: 0)
		#expect(
			throws: JPEGTranscode.TranscodeError.invalidQuantizationTable(
				index: 0, coefficient: 1)
		) {
			try JPEGTranscode(gray)
		}
		#expect(
			throws: JPEGTranscode.TranscodeError.invalidQuantizationTable(
				index: 0, coefficient: 1)
		) {
			try Self.transcode(
				luma: [Int32](repeating: 0, count: 64),
				cb: [Int32](repeating: 0, count: 64),
				cr: [Int32](repeating: 0, count: 64),
				quantTables: [zeroAC, unit, unit],
				horizontalSampling: [2, 1, 1])
		}
		var highLuma = unit
		highLuma[0] = 256
		#expect(
			throws: JPEGTranscode.TranscodeError.excessiveQuantizationRatio(
				channel: 0, coefficient: 0)
		) {
			try Self.transcode(
				luma: [Int32](repeating: 0, count: 64),
				cb: [Int32](repeating: 0, count: 64),
				cr: [Int32](repeating: 0, count: 64),
				quantTables: [unit, highLuma, unit])
		}
		var maxLuma = unit
		maxLuma[0] = 65535
		var maxChroma = unit
		maxChroma[0] = 256
		let largest = try Self.transcode(
			luma: [Int32](repeating: 0, count: 64),
			cb: [Int32](repeating: 0, count: 64),
			cr: [Int32](repeating: 0, count: 64),
			quantTables: [maxChroma, maxLuma, maxChroma])
		#expect(largest.quantizationRatios[0][0] == 524_280)
		#expect(
			throws: JPEGTranscode.TranscodeError.excessiveQuantizationRatio(
				channel: 0, coefficient: 1)
		) {
			var excessiveAC = unit
			excessiveAC[1] = 256
			_ = try Self.transcode(
				luma: [Int32](repeating: 0, count: 64),
				cb: [Int32](repeating: 0, count: 64),
				cr: [Int32](repeating: 0, count: 64),
				quantTables: [unit, excessiveAC, unit],
				horizontalSampling: [2, 1, 1])
		}
		let transcode = try JPEGTranscodeTests.transcode("small_444")
		#expect(transcode.quantizationRatios.count == 3)
		#expect(transcode.quantizationRatios.allSatisfy { $0.count == 64 })
		#expect(transcode.quantizationRatios[0].allSatisfy { $0 > 0 })
	}

	@Test("Tile maps and residuals follow the selected source search")
	func jpegCfLMatchesPinnedTileMapsAndCoefficients() throws {
		var luma = [Int32](repeating: 0, count: 64)
		var cb = [Int32](repeating: 0, count: 64)
		var cr = [Int32](repeating: 0, count: 64)
		for coefficient in [1, 2] {
			luma[coefficient] = 84
			cb[coefficient] = 10
			cr[coefficient] = -10
		}
		let transcode = try Self.transcode(luma: luma, cb: cb, cr: cr)
		var data = DCGroupData(widthInBlocks: 1, heightInBlocks: 1)
		transcode.populateColorCorrelation(data: &data, blockX0: 0, blockY0: 0)
		#expect(data.ytoxMap == [10])
		#expect(data.ytobMap == [-10])
		for (channel, map) in [(0, data.ytoxMap[0]), (2, data.ytobMap[0])] {
			let raw = transcode.block(channel: channel, x: 0, y: 0)
			let residual = try transcode.block(
				channel: channel, x: 0, y: 0, correlation: map)
			#expect(residual[0] == raw[0])
			#expect(residual[1] == 0)
			#expect(residual[2] == 0)
		}
	}

	@Test("Source maps and residuals match across partial tiles and a nonzero origin")
	func jpegCfLMatchesSourceMapsAcrossPartialTilesAndGlobalOrigin() throws {
		let sourceDump = try SemanticDump(fixture: "cfl_tile_65x8_source")
		let expectedSize = SemanticDump.Values.integers([2, 1])
		let expectedYToX = SemanticDump.Values.integers([11, -20])
		let expectedYToB = SemanticDump.Values.integers([-10, 20])
		#expect(sourceDump.fields["jpeg_cfl.map_size"] == expectedSize)
		#expect(sourceDump.fields["jpeg_cfl.ytox_map"] == expectedYToX)
		#expect(sourceDump.fields["jpeg_cfl.ytob_map"] == expectedYToB)
		#expect(
			sourceDump.fields["jpeg_context.reconstructed_coefficients_exact"]
				== .integers([1]))

		let source = try JPEGTranscode(
			JPEGParser.parse(JPEGParserTests.fixture("cfl_tile_65x8")))
		var partialTile = DCGroupData(widthInBlocks: 9, heightInBlocks: 1)
		source.populateColorCorrelation(
			data: &partialTile, blockX0: 0, blockY0: 0)
		#expect(partialTile.cmapWidth == 2)
		#expect(
			SemanticDump.Values.integers(partialTile.ytoxMap.map(Int64.init))
				== sourceDump.fields["jpeg_cfl.ytox_map"])
		#expect(
			SemanticDump.Values.integers(partialTile.ytobMap.map(Int64.init))
				== sourceDump.fields["jpeg_cfl.ytob_map"])

		let origin = Geometry.dcGroupDim / Geometry.blockDim
		let blocksPerLine = origin + source.component(1).blocksPerLine
		var components = (0..<3).map { _ in
			[Int32](repeating: 0, count: blocksPerLine * 64)
		}
		for blockX in 0..<source.component(1).blocksPerLine {
			for channel in 0..<3 {
				let sourceBlock = source.block(channel: channel, x: blockX, y: 0)
				let component = [1, 0, 2][channel]
				for y in 0..<8 {
					for x in 0..<8 {
						components[component][
							(origin + blockX) * 64 + y * 8 + x] =
							sourceBlock[x * 8 + y]
					}
				}
			}
		}
		let offsetTranscode = try Self.transcode(
			luma: components[0], cb: components[1], cr: components[2],
			blocksPerLine: blocksPerLine)
		var offsetData = DCGroupData(widthInBlocks: origin, heightInBlocks: 1)
		offsetTranscode.populateColorCorrelation(
			data: &offsetData, blockX0: origin, blockY0: 0)
		#expect(offsetData.ytoxMap.prefix(2) == [11, -20])
		#expect(offsetData.ytobMap.prefix(2) == [-10, 20])
		#expect(offsetData.ytoxMap.dropFirst(2).allSatisfy { $0 == 0 })
		#expect(offsetData.ytobMap.dropFirst(2).allSatisfy { $0 == 0 })
		for blockX in 0..<source.component(1).blocksPerLine {
			for (channel, map) in [
				(0, offsetData.ytoxMap[blockX / 8]),
				(2, offsetData.ytobMap[blockX / 8]),
			] {
				let x = origin + blockX
				let raw = offsetTranscode.block(channel: channel, x: x, y: 0)
				let residual = try offsetTranscode.block(
					channel: channel, x: x, y: 0, correlation: map)
				let expectedRaw: [Int32]
				let expectedResidual: [Int32]
				if channel == 0 {
					expectedRaw = blockX < 8 ? [10, 11] : [-20, -20]
					expectedResidual = blockX < 8 ? [-1, 0] : [0, 0]
				} else {
					expectedRaw = blockX < 8 ? [-10, -11] : [20, 20]
					expectedResidual = blockX < 8 ? [0, -1] : [0, 0]
				}
				#expect([raw[8], raw[16]] == expectedRaw)
				#expect([residual[8], residual[16]] == expectedResidual)
			}
		}
	}

	@Test("Separated maxima use the endpoint midpoint and strict gain rule")
	func jpegCfLUsesSourceMaximumAndGainRules() throws {
		var differences = [Int32](repeating: 0, count: 257)
		differences[1] = 2
		differences[2] = -2
		differences[255] = 2
		differences[256] = -2
		#expect(
			JPEGTranscode.colorCorrelationFactor(zeroCountDifferences: differences) == 1
		)
		var noGain = [Int32](repeating: 0, count: 257)
		noGain[255] = 1
		noGain[256] = -1
		#expect(JPEGTranscode.colorCorrelationFactor(zeroCountDifferences: noGain) == 0)
	}

	@Test("Signed two-round predictions recover every original coefficient")
	func jpegCfLRecoversEverySourceCoefficient() throws {
		var luma = [Int32](repeating: 0, count: 64)
		var cb = [Int32](repeating: 0, count: 64)
		var cr = [Int32](repeating: 0, count: 64)
		luma[1] = 32
		luma[8] = 32
		cb[1] = 5
		cr[8] = -9
		let cbQuant = [UInt16](repeating: 1, count: 64)
		let lumaQuant = [UInt16](repeating: 2, count: 64)
		let crQuant = [UInt16](repeating: 4, count: 64)
		let transcode = try Self.transcode(
			luma: luma, cb: cb, cr: cr,
			quantTables: [cbQuant, lumaQuant, crQuant])
		let raw = transcode.block(channel: 0, x: 0, y: 0)
		let residual = try transcode.block(channel: 0, x: 0, y: 0, correlation: -7)
		#expect(residual[0] == raw[0])
		#expect(residual != raw)
		let lumaBlock = transcode.block(channel: 1, x: 0, y: 0)
		#expect(transcode.quantizationRatios[0][8] == 4096)
		#expect(transcode.quantizationRatios[2][1] == 1024)
		for i in 1..<64 {
			let scale = Int64(-7) * 2048 / 84
			let coeffScale =
				(scale * Int64(transcode.quantizationRatios[0][i]) + 1024) >> 11
			let prediction = (Int64(lumaBlock[i]) * coeffScale + 1024) >> 11
			#expect(Int64(residual[i]) + prediction == Int64(raw[i]))
		}
		#expect(residual[8] == 10)
		let crResidual = try transcode.block(channel: 2, x: 0, y: 0, correlation: -7)
		#expect(crResidual[1] == -8)
		#expect(
			Int64(crResidual[1]) - 1
				== Int64(transcode.block(channel: 2, x: 0, y: 0)[1]))

		let parsed = try JPEGTranscode(JPEGParser.parse(Self.maximumACJPEG()))
		#expect(parsed.component(1).coefficients[1] == 32_767)
		let parsedLuma = parsed.block(channel: 1, x: 0, y: 0)
		let parsedCb = parsed.block(channel: 0, x: 0, y: 0)
		#expect(parsedLuma[8] == 32_767)
		#expect(parsedCb[8] == 32_767)
		#expect(parsed.block(channel: 2, x: 0, y: 0)[8] == -32_767)
		let parsedCbResidual = try parsed.block(
			channel: 0, x: 0, y: 0, correlation: -7)
		let scale = Int64(-7) * 2048 / 84
		let coefficientScale =
			(scale * Int64(parsed.quantizationRatios[0][8]) + 1024) >> 11
		let prediction = (Int64(parsedLuma[8]) * coefficientScale + 1024) >> 11
		#expect(parsedCbResidual[8] > 32_767)
		#expect(Int64(parsedCbResidual[8]) + prediction == Int64(parsedCb[8]))
	}

	static func transcode(
		luma: [Int32], cb: [Int32], cr: [Int32],
		blocksPerLine: Int = 1, blocksPerColumn: Int = 1,
		componentQuantTableIndexes: [Int] = [1, 0, 2],
		quantTables: [[UInt16]] = (0..<3).map { _ in [UInt16](repeating: 1, count: 64) },
		horizontalSampling: [Int] = [1, 1, 1],
		verticalSampling: [Int] = [1, 1, 1]
	) throws -> JPEGTranscode {
		let components = [luma, cb, cr].enumerated().map { index, coefficients in
			JPEGComponent(
				identifier: UInt8(index + 1),
				horizontalSampling: horizontalSampling[index],
				verticalSampling: verticalSampling[index],
				quantTableIndex: componentQuantTableIndexes[index],
				blocksPerLine: blocksPerLine, blocksPerColumn: blocksPerColumn,
				coefficients: coefficients)
		}
		return try JPEGTranscode(
			JPEGImage(
				width: blocksPerLine * 8, height: blocksPerColumn * 8,
				components: components,
				quantTables: quantTables, restartInterval: 0
			))
	}

	private static func maximumACJPEG() -> [UInt8] {
		func segment(_ marker: UInt8, _ payload: [UInt8]) -> [UInt8] {
			let length = payload.count + 2
			return [0xFF, marker, UInt8(length >> 8), UInt8(length & 0xFF)] + payload
		}
		func amplitude(_ value: Int32) -> [UInt8] {
			let encoded = value >= 0 ? value : value + (1 << 15) - 1
			return (0..<15).reversed().map { UInt8(encoded >> $0 & 1) }
		}

		var bits: [UInt8] = []
		for coefficient: Int32 in [32_767, 32_767, -32_767] {
			bits += [0, 0, 0]
			bits += amplitude(coefficient)
			bits += [0, 1]
		}
		while !bits.count.isMultiple(of: 8) { bits.append(1) }
		var entropy: [UInt8] = []
		for start in stride(from: 0, to: bits.count, by: 8) {
			let byte = bits[start..<start + 8].reduce(UInt8(0)) { ($0 << 1) | $1 }
			entropy.append(byte)
			if byte == 0xFF { entropy.append(0) }
		}

		let quant = segment(0xDB, [0] + [UInt8](repeating: 1, count: 64))
		let frame = segment(
			0xC0,
			[8, 0, 8, 0, 8, 3, 1, 0x11, 0, 2, 0x11, 0, 3, 0x11, 0])
		var huffmanPayload: [UInt8] = [0, 1]
		huffmanPayload += [UInt8](repeating: 0, count: 15)
		huffmanPayload.append(0)
		huffmanPayload += [0x10, 0, 2]
		huffmanPayload += [UInt8](repeating: 0, count: 14)
		huffmanPayload += [0x0F, 0]
		let huffman = segment(0xC4, huffmanPayload)
		let scan = segment(0xDA, [3, 1, 0, 2, 0, 3, 0, 0, 63, 0])
		var jpeg: [UInt8] = [0xFF, 0xD8]
		jpeg += quant
		jpeg += frame
		jpeg += huffman
		jpeg += scan
		jpeg += entropy
		jpeg += [0xFF, 0xD9]
		return jpeg
	}

	@Test("Grayscale and subsampled inputs retain zero maps and original AC")
	func jpegCfLIsDisabledForGrayscaleAndSubsampling() throws {
		for name in ["hopper_gray_odd", "hopper_420_odd", "small_422", "small_440"] {
			let transcode = try JPEGTranscodeTests.transcode(name)
			var data = DCGroupData(
				widthInBlocks: transcode.width / 8,
				heightInBlocks: transcode.height / 8,
				subsampling: transcode.subsampling)
			transcode.populateColorCorrelation(data: &data, blockX0: 0, blockY0: 0)
			#expect(data.ytoxMap.allSatisfy { $0 == 0 })
			#expect(data.ytobMap.allSatisfy { $0 == 0 })
			for channel in [0, 2] {
				let raw = transcode.block(channel: channel, x: 0, y: 0)
				#expect(
					try transcode.block(
						channel: channel, x: 0, y: 0, correlation: 127)
						== raw)
			}
		}
	}

	@Test("An unrepresentable winning factor retains zero correlation")
	func jpegCfLUnrepresentableWinnerUsesZeroCorrelation() throws {
		var differences = [Int32](repeating: 0, count: 257)
		differences[255] = 2
		#expect(
			JPEGTranscode.colorCorrelationFactor(zeroCountDifferences: differences) == 0
		)
		let transcode = try JPEGTranscode(
			JPEGParser.parse(JPEGParserTests.fixture("cfl_endpoint_444")))
		var data = DCGroupData(widthInBlocks: 1, heightInBlocks: 1)
		transcode.populateColorCorrelation(data: &data, blockX0: 0, blockY0: 0)
		#expect(data.ytoxMap == [0])
		let raw = transcode.block(channel: 0, x: 0, y: 0)
		let residual = try transcode.block(
			channel: 0, x: 0, y: 0, correlation: data.ytoxMap[0])
		#expect(raw[8] == 128)
		#expect(raw[16] == 128)
		#expect(residual[8] == 128)
		#expect(residual[16] == 128)
		#expect(residual[8] == raw[8])
	}

	@Test("Only an unrepresentable actual residual raises overflow")
	func jpegCfLChecksActualResidualRange() throws {
		var largeLuma = [Int32](repeating: 0, count: 64)
		var largeCb = [Int32](repeating: 0, count: 64)
		largeLuma[1] = 32_767
		largeCb[1] = 32_767
		let large = try Self.transcode(
			luma: largeLuma, cb: largeCb, cr: [Int32](repeating: 0, count: 64))
		let largeRaw = large.block(channel: 0, x: 0, y: 0)
		let largeResidual = try large.block(channel: 0, x: 0, y: 0, correlation: -7)
		let scale = Int64(-7) * 2048 / 84
		let coefficientScale =
			(scale * Int64(large.quantizationRatios[0][8]) + 1024) >> 11
		let prediction =
			(Int64(large.block(channel: 1, x: 0, y: 0)[8]) * coefficientScale + 1024)
			>> 11
		#expect(largeResidual[8] > 32_767)
		#expect(Int64(largeResidual[8]) + prediction == Int64(largeRaw[8]))

		var luma = [Int32](repeating: 0, count: 64)
		var cb = [Int32](repeating: 0, count: 64)
		luma[1] = .max
		cb[1] = .max
		let transcode = try Self.transcode(
			luma: luma, cb: cb, cr: [Int32](repeating: 0, count: 64))
		#expect(
			throws: JPEGTranscode.TranscodeError.residualOverflow(
				channel: 0, blockX: 0, blockY: 0, coefficient: 8)
		) {
			try transcode.block(channel: 0, x: 0, y: 0, correlation: -128)
		}
	}

}
