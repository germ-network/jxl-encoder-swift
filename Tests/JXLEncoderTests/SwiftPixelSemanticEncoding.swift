@testable import JXLEncoder

extension SwiftSemanticEncoding {
	static func coefficients(
		from groups: [Encoder.ACGroupCompute], dimension: ImageDim, scaleDC: Float
	) throws -> (ac: [[Int32]], dc: [[Int32]], rawDC: [[Float]]) {
		let blockCount = dimension.widthInBlocks * dimension.heightInBlocks
		var ac = (0..<3).map { _ in [Int32](repeating: 0, count: blockCount * 64) }
		var dc = (0..<3).map { _ in [Int32](repeating: 0, count: blockCount) }
		var rawDC = (0..<3).map { _ in [Float](repeating: 0, count: blockCount) }
		for group in groups {
			for y in 0..<group.heightInBlocks {
				for x in 0..<group.widthInBlocks {
					let globalX = group.groupX * Geometry.groupDimInBlocks + x
					let globalY = group.groupY * Geometry.groupDimInBlocks + y
					let block = globalY * dimension.widthInBlocks + globalX
					let source = y * group.widthInBlocks + x
					for channel in 0..<3 {
						let acSource = source * 64
						let acDest = block * 64
						ac[channel].replaceSubrange(
							acDest..<(acDest + 64),
							with: group.coefficients[channel][
								acSource..<(acSource + 64)])
						rawDC[channel][block] = group.rawDC[channel][source]
					}
				}
			}
		}
		let dcGroupSpan = Geometry.dcGroupDim / Geometry.blockDim
		for originY in stride(from: 0, to: dimension.heightInBlocks, by: dcGroupSpan) {
			for originX in stride(from: 0, to: dimension.widthInBlocks, by: dcGroupSpan)
			{
				let width = min(dcGroupSpan, dimension.widthInBlocks - originX)
				let height = min(dcGroupSpan, dimension.heightInBlocks - originY)
				let groupRawDC = (0..<3).map { channel in
					(0..<height).flatMap { y in
						(originX..<(originX + width)).map { x in
							rawDC[channel][
								(originY + y)
									* dimension.widthInBlocks
									+ x]
						}
					}
				}
				var prepared = DCGroupData(
					widthInBlocks: width, heightInBlocks: height)
				try DCGroupEncoder.preparePixel(
					rawDC: groupRawDC, scaleDC: scaleDC, data: &prepared)
				for channel in 0..<3 {
					for y in 0..<height {
						for x in 0..<width {
							dc[channel][
								(originY + y)
									* dimension.widthInBlocks
									+ originX + x] =
								prepared.quantDC[channel][
									y * width + x]
						}
					}
				}
			}
		}
		return (ac, dc, rawDC)
	}
}
