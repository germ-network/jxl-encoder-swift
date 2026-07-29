//
//  QuantizeRoundtrip.swift
//  JXLEncoder
//
//  Port of `AdjustQuantBias` and `QuantizeRoundtripYBlockAC` from
//  libjxl-tiny's encoder/enc_group.cc.
//
//  The Y channel is quantized and then dequantized again, because the X and B
//  channels are decorrelated against the *reconstructed* Y rather than the
//  original — the decoder only has the reconstruction, so the encoder must use
//  the same thing.
//

extension Quantizer {
	/// Nudges dequantized values toward zero, with a per-channel bias for
	/// magnitude-one coefficients.
	static let defaultQuantBias: [Float] = [
		1.0 - 0.054_650_073_307_154_01,
		1.0 - 0.070_054_498_917_485_93,
		1.0 - 0.049_935_103_337_343_655,
		0.145,
	]

	static func adjustQuantBias(channel: Int, quantized: Int32) -> Float {
		let quant = Float(quantized)
		let signBit = quant.bitPattern & 0x8000_0000
		let magnitude = Float(bitPattern: quant.bitPattern & 0x7FFF_FFFF)

		// Magnitude 0 and 1 get a fixed bias; anything larger is pulled toward
		// zero by a reciprocal term.
		if magnitude < 1.125 {
			guard magnitude > 0 else { return 0 }
			return Float(bitPattern: defaultQuantBias[channel].bitPattern ^ signBit)
		}
		return quant.addingProduct(
			-defaultQuantBias[3], ReciprocalEstimate.apply(quant))
	}

	/// Quantizes the Y block and writes the dequantized reconstruction back.
	static func roundtripYBlockAC(
		coefficients: ArraySlice<Float>,
		quant: Int32,
		scale: Float
	) -> (quantized: [Int32], reconstructed: [Float]) {
		let inverseMatrix = QuantMatrices.inverseMatrix(channel: 1)
		let forwardMatrix = QuantMatrices.matrix(channel: 1)

		let quantized = quantizeBlockAC(
			coefficients: coefficients,
			channel: 1,
			inverseMatrix: inverseMatrix,
			quant: quant,
			scale: scale)

		// The reference divides in double here before narrowing.
		let inverseQac = Float(1.0 / Double(scale * Float(quant)))
		let forwardBase = forwardMatrix.startIndex

		var reconstructed = [Float](repeating: 0, count: DCT.blockSize)
		for k in 0..<DCT.blockSize {
			let adjusted = adjustQuantBias(channel: 1, quantized: quantized[k])
			reconstructed[k] = (adjusted * forwardMatrix[forwardBase + k]) * inverseQac
		}
		return (quantized, reconstructed)
	}
}
