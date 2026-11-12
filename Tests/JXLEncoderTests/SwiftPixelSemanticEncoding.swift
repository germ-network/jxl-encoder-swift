@testable import JXLEncoder

extension SwiftSemanticEncoding {
	static func coefficients(
		from groups: [Encoder.ACGroupCompute], dimension: ImageDim
	) -> (ac: [[Int32]], dc: [[Int16]]) {
		let blockCount = dimension.widthInBlocks * dimension.heightInBlocks
		var ac = (0..<3).map { _ in [Int32](repeating: 0, count: blockCount * 64) }
		var dc = (0..<3).map { _ in [Int16](repeating: 0, count: blockCount) }
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
						dc[channel][block] = group.quantDC[channel][source]
					}
				}
			}
		}
		return (ac, dc)
	}
}
