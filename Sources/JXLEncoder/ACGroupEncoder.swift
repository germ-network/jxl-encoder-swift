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

	/// DC quantization steps, from encoder/quant_weights.h.
	static let inverseDCQuant: [Float] = [4096.0, 512.0, 256.0]
	static let dcQuant: [Float] = [1.0 / 4096.0, 1.0 / 512.0, 1.0 / 256.0]

	/// B's DC is decorrelated against Y's DC even with chroma-from-luma off:
	/// `kInvDCQuant[2] * kDCQuant[1]` is 0.5.
	static let dcCflFactor: [Float] = [0, 0, inverseDCQuant[2] * dcQuant[1]]

	/// Quantizes one DC coefficient.
	///
	/// The multiply-subtract is written as an explicit fused multiply-add
	/// because clang contracts `a * b - c * d` into `fma(a, b, -(c * d))` by
	/// default while Swift never contracts. Rounding both products separately
	/// differs in the last bit, which is enough to flip a value sitting on a
	/// rounding boundary — it cost exactly one block in one 44 800-block DC
	/// group before this was matched.
	///
	/// Rounding is ties-away-from-zero (`std::round`), unlike the ties-to-even
	/// used when quantizing AC coefficients.
	static func quantizedDC(
		coefficient: Float, inverseFactor: Float, yDC: Int16, cflFactor: Float
	) -> Int16 {
		let correction = Float(yDC) * cflFactor
		let value = (-correction).addingProduct(coefficient, inverseFactor)
		return Int16(value.rounded(.toNearestOrAwayFromZero))
	}

	/// Encodes one group's AC coefficients and fills in its DC image.
	///
	/// `xyb` is the padded XYB image for the group; `quantField` holds one value
	/// per block in group-raster order. `quantDC` receives one DC value per
	/// block per channel — the AC pass produces both outputs, since DC is just
	/// the lowest-frequency coefficient of the same transform.
	public static func encode(
		xyb: PaddedStripe,
		widthInBlocks: Int,
		heightInBlocks: Int,
		quantField: [UInt8],
		scale: Float,
		scaleDC: Float,
		xQuantMatrixScale: UInt32,
		code: EntropyCode,
		quantDC: inout [[Int16]],
		writer: inout BitWriter
	) {
		let inverseFactor = inverseDCQuant.map { $0 * scaleDC }
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

				// For DCT8 the DC is simply the lowest-frequency coefficient.
				// `std::round` here rounds ties away from zero, unlike the
				// half-to-even rounding the AC quantizer uses.
				let blockIndex = by * widthInBlocks + bx
				quantDC[1][blockIndex] = Int16(
					(inverseFactor[1] * yCoefficients[0])
						.rounded(.toNearestOrAwayFromZero))

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

					// Taken from the decorrelated coefficients, then B has Y's
					// DC subtracted on top.
					//
					// Written as an explicit fused multiply-add because clang
					// contracts `a * b - c * d` into `fma(a, b, -(c * d))` by
					// default, while Swift never contracts. Computing both
					// products separately differs in the last bit, which is
					// enough to flip a value sitting on a rounding boundary.
					quantDC[channel][blockIndex] = quantizedDC(
						coefficient: coefficients[0],
						inverseFactor: inverseFactor[channel],
						yDC: quantDC[1][blockIndex],
						cflFactor: dcCflFactor[channel])
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
