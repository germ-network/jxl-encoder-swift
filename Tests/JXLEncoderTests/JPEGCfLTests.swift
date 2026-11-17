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
			try Self.transcode(
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
	}

	static func transcode(
		luma: [Int32], cb: [Int32], cr: [Int32],
		blocksPerLine: Int = 1, blocksPerColumn: Int = 1,
		componentQuantTableIndexes: [Int] = [1, 0, 2],
		quantTables: [[UInt16]] = (0..<3).map { _ in [UInt16](repeating: 1, count: 64) }
	) throws -> JPEGTranscode {
		let components = [luma, cb, cr].enumerated().map { index, coefficients in
			JPEGComponent(
				identifier: UInt8(index + 1), horizontalSampling: 1,
				verticalSampling: 1,
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

	@Test("Grayscale and subsampled inputs retain zero maps and original AC")
	func jpegCfLIsDisabledForGrayscaleAndSubsampling() throws {
		for name in ["hopper_gray_odd", "small_422", "small_440"] {
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
