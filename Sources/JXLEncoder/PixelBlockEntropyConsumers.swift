extension JPEGBlockContextMap.Result {
	func category(channel: Int, dcBucket: Int, rawQuant: UInt32) -> Int {
		var quantBucket = 0
		for threshold in qfThresholds where rawQuant > threshold { quantBucket += 1 }
		let base =
			JPEGBlockContextMap.slot(forChannel: channel)
			* JPEGBlockContextMap.numOrders * (qfThresholds.count + 1)
		return Int(contextMap[base + quantBucket])
	}
}

extension ACGroupEncoder {
	static func tokenizeGroup(
		coefficients: [[Int32]], widthInBlocks: Int, heightInBlocks: Int,
		subsampling: ChromaSubsampling, order: [[Int]],
		blockContextMap: JPEGBlockContextMap.Result, rawQuantField: [UInt8],
		writer: inout SectionWriter
	) {
		let widths = (0..<3).map {
			subsampling.blocksAcross(channel: $0, fullWidthInBlocks: widthInBlocks)
		}
		var nonZeros: [[UInt8]] = (0..<3).map {
			[UInt8](repeating: 0, count: widths[$0])
		}
		var nonZerosAbove: [[UInt8]?] = [nil, nil, nil]
		for by in 0..<heightInBlocks {
			var codedThisRow = [false, false, false]
			for bx in 0..<widthInBlocks {
				let quant = UInt32(rawQuantField[by * widthInBlocks + bx])
				let sx = (0..<3).map {
					subsampling.subsampledX(channel: $0, blockX: bx)
				}
				let sy = (0..<3).map {
					subsampling.subsampledY(channel: $0, blockY: by)
				}
				for channel in ACTokenizer.channelOrder
				where subsampling.codesBlock(
					channel: channel, blockX: bx, blockY: by)
				{
					codedThisRow[channel] = true
					let block =
						(sy[channel] * widths[channel] + sx[channel])
						* DCT.blockSize
					ACTokenizer.writeBlockAdaptive(
						quantized: coefficients[channel][
							block..<(block + DCT.blockSize)],
						blockCategory: blockContextMap.category(
							channel: channel, dcBucket: 0,
							rawQuant: quant),
						numCategories: blockContextMap.numContexts,
						blockX: sx[channel], order: order[channel],
						nonZeroRow: &nonZeros[channel],
						nonZeroRowAbove: nonZerosAbove[channel],
						writer: &writer)
				}
			}
			for channel in 0..<3 where codedThisRow[channel] {
				nonZerosAbove[channel] = nonZeros[channel]
			}
		}
	}
}
