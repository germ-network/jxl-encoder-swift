//
//  Quantizer.swift
//  JXLEncoder
//
//  Port of full libjxl `QuantizeBlockAC` for the e4 Cheetah path.
//

enum Quantizer {
	/// Per-quadrant e4 dead zones, indexed by row and column half-block.
	static func thresholds(channel: Int) -> (Float, Float, Float, Float) {
		if channel == 1 {
			return (0.56, 0.62, 0.62, 0.62)
		}
		return (0.58, 0.62, 0.62, 0.62)
	}

	/// Quantizes one 8x8 block of DCT coefficients.
	///
	/// `quant` is the block's value from the adaptive quant field and `scale`
	/// the frame-global quantizer scale. The DC coefficient always lands on
	/// zero because its inverse weight is zeroed — see `QuantMatrices`.
	static func quantizeBlockAC(
		coefficients: ArraySlice<Float>,
		channel: Int,
		inverseMatrix: ArraySlice<Float>,
		quant: Int32,
		scale: Float,
		matrixMultiplier: Float = 1.0
	) -> [Int32] {
		let qac = scale * Float(quant)
		let quantScale = qac * matrixMultiplier
		let t = thresholds(channel: channel)

		let coeffBase = coefficients.startIndex
		let matrixBase = inverseMatrix.startIndex
		var out = [Int32](repeating: 0, count: DCT.blockSize)

		for y in 0..<DCT.blockDim {
			let lowRow = y < DCT.blockDim / 2
			for x in 0..<DCT.blockDim {
				let lowCol = x < DCT.blockDim / 2
				let threshold =
					lowRow
					? (lowCol ? t.0 : t.1)
					: (lowCol ? t.2 : t.3)

				let i = y * DCT.blockDim + x
				let q = inverseMatrix[matrixBase + i] * quantScale
				let value = q * coefficients[coeffBase + i]
				guard abs(value) >= threshold else { continue }
				// Highway's Round is round-half-to-even, unlike Swift's default
				// round-half-away-from-zero.
				out[i] = Int32(value.rounded(.toNearestOrEven))
			}
		}
		return out
	}

	/// Quantizes every block of a plane laid out in block-raster order, as
	/// produced by `DCT.forwardBlocks`.
	static func quantizePlane(
		coefficients: [Float],
		channel: Int,
		quant: Int32,
		scale: Float,
		matrixMultiplier: Float = 1.0
	) -> [Int32] {
		let matrix = QuantMatrices.inverseMatrix(channel: channel)
		var out = [Int32](repeating: 0, count: coefficients.count)
		for block in 0..<(coefficients.count / DCT.blockSize) {
			let base = block * DCT.blockSize
			let quantized = quantizeBlockAC(
				coefficients: coefficients[base..<base + DCT.blockSize],
				channel: channel,
				inverseMatrix: matrix,
				quant: quant,
				scale: scale,
				matrixMultiplier: matrixMultiplier
			)
			for i in 0..<DCT.blockSize { out[base + i] = quantized[i] }
		}
		return out
	}
}
