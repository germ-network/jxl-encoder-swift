//
//  ACGroupEncoder.swift
//  JXLEncoder
//
//  Port of the per-block body of `WriteACGroup` from
//  libjxl-tiny's encoder/enc_group.cc, for the 8x8-only path.
//
//  Only tokens reach the bit writer; DC is carried separately by the DC image.
//

public enum ACGroupEncoder {
	/// With chroma-from-luma dropped, X keeps its own coefficients while B is
	/// decorrelated against the reconstructed Y. These are the `x_factor` and
	/// `b_factor` the reference substitutes when CfL is compiled out.
	static let xFactor: Float = 0
	static let bFactor: Float = 1

	/// Encodes one group's AC coefficients.
	///
	/// `xyb` is the padded XYB image for the group; `quantField` holds one value
	/// per block in group-raster order.
	public static func encode(
		xyb: PaddedStripe,
		widthInBlocks: Int,
		heightInBlocks: Int,
		quantField: [UInt8],
		scale: Float,
		xQuantMatrixScale: UInt32,
		code: EntropyCode,
		writer: inout BitWriter
	) {
		// The X channel's quant matrix is scaled by distance-dependent steps.
		let xMatrixMultiplier = Float.pow(1.25, Float(xQuantMatrixScale) - 2.0)

		var nonZeros: [[UInt8]] = Array(
			repeating: [UInt8](repeating: 0, count: widthInBlocks), count: 3)
		var nonZerosAbove: [[UInt8]]? = nil

		for by in 0..<heightInBlocks {
			for bx in 0..<widthInBlocks {
				let quant = Int32(quantField[by * widthInBlocks + bx])

				// Y first: its reconstruction is what X and B decorrelate against.
				let yCoefficients = DCT.forward8x8(
					pixels: xyb.planes[1], stride: xyb.width,
					originX: bx * DCT.blockDim, originY: by * DCT.blockDim)
				let (yQuantized, yReconstructed) = Quantizer.roundtripYBlockAC(
					coefficients: yCoefficients[...], quant: quant, scale: scale
				)

				var quantized = [[Int32]](repeating: [], count: 3)
				quantized[1] = yQuantized

				for channel in [0, 2] {
					var coefficients = DCT.forward8x8(
						pixels: xyb.planes[channel], stride: xyb.width,
						originX: bx * DCT.blockDim,
						originY: by * DCT.blockDim)
					let factor = channel == 0 ? xFactor : bFactor
					for k in 0..<DCT.blockSize {
						coefficients[k] = coefficients[k].addingProduct(
							-factor, yReconstructed[k])
					}
					quantized[channel] = Quantizer.quantizeBlockAC(
						coefficients: coefficients[...],
						channel: channel,
						inverseMatrix: QuantMatrices.inverseMatrix(
							channel: channel),
						quant: quant,
						scale: scale,
						matrixMultiplier: channel == 0
							? xMatrixMultiplier : 1.0)
				}

				for channel in ACTokenizer.channelOrder {
					ACTokenizer.writeBlock(
						quantized: quantized[channel][...],
						channel: channel,
						blockX: bx,
						nonZeroRow: &nonZeros[channel],
						nonZeroRowAbove: nonZerosAbove?[channel],
						code: code,
						writer: &writer)
				}
			}
			nonZerosAbove = nonZeros
		}
	}
}
