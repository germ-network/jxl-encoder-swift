extension JPEGTranscode {
	static func colorCorrelationFactor(zeroCountDifferences: [Int32]) -> Int8 {
		0
	}

	func populateColorCorrelation(
		data: inout DCGroupData, blockX0: Int, blockY0: Int
	) {}

	func block(
		channel: Int, x: Int, y: Int, correlation: Int8
	) throws -> [Int32] {
		block(channel: channel, x: x, y: y)
	}
}

extension ACGroupEncoder {
	static func encodeJPEG(
		transcode: JPEGTranscode,
		colorCorrelation: DCGroupData,
		colorCorrelationBlockX0: Int, colorCorrelationBlockY0: Int,
		blockX0: Int, blockY0: Int,
		widthInBlocks: Int, heightInBlocks: Int,
		quantDC: inout [[Int32]],
		blockContextMap: JPEGBlockContextMap.Result?,
		order: [[Int]], writer: inout SectionWriter
	) throws {
		encodeJPEG(
			transcode: transcode, blockX0: blockX0, blockY0: blockY0,
			widthInBlocks: widthInBlocks, heightInBlocks: heightInBlocks,
			quantDC: &quantDC, blockContextMap: blockContextMap,
			order: order, writer: &writer)
	}

	static func jpegCoefficientsForOrdering(
		transcode: JPEGTranscode,
		colorCorrelation: DCGroupData,
		colorCorrelationBlockX0: Int, colorCorrelationBlockY0: Int,
		blockX0: Int, blockY0: Int,
		widthInBlocks: Int, heightInBlocks: Int
	) throws -> [[Int32]] {
		jpegCoefficientsForOrdering(
			transcode: transcode, blockX0: blockX0, blockY0: blockY0,
			widthInBlocks: widthInBlocks, heightInBlocks: heightInBlocks)
	}
}
