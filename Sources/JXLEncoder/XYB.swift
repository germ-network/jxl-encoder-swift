//
//  XYB.swift
//  JXLEncoder
//
//  Port of libjxl-tiny's encoder/enc_xyb.cc: linear sRGB to the XYB opsin
//  colorspace, in place.
//
//  The multiply-accumulate structure mirrors the reference exactly — Highway's
//  MulAdd/NegMulAdd lower to fused multiply-add on arm64, so `addingProduct` is
//  used wherever the reference fuses and plain arithmetic where it does not.
//  Departing from that shape changes the last bits of the result.
//

enum XYB {
	static let m02: Float = 0.078
	static let m00: Float = 0.30
	static let m01: Float = 1.0 - m02 - m00
	static let m12: Float = 0.078
	static let m10: Float = 0.23
	static let m11: Float = 1.0 - m12 - m10
	static let m20: Float = 0.243_422_689_245_478_19
	static let m21: Float = 0.204_767_444_244_968_21
	static let m22: Float = 1.0 - m20 - m21
	static let opsinAbsorbanceBias: Float = 0.003_793_073_255_275_449_3
	static let negBiasCbrt: Float = -0.155_954_200_54

	/// Cube root via Newton-Raphson on the *reciprocal* cube root, then scaled
	/// back — `x^(-2/3) * x == x^(1/3)`. Reproduces `CubeRootAndAdd` from
	/// encoder/fast_math-inl.h rather than calling libm's `cbrt`, whose results
	/// differ in the low bits.
	static func cubeRootAndAdd(_ x: Float, _ add: Float) -> Float {
		let bits = Int32(bitPattern: x.bitPattern)
		// Zero has a zero exponent, so the bias arithmetic below would produce
		// a wrong result and later NaNs; short-circuit it.
		let seed: Int32 = bits == 0 ? 0 : 0x5480_0000 &- (bits >> 23) &* 0x002A_AAAA
		var r = Float(bitPattern: UInt32(bitPattern: seed))

		let third: Float = 1.0 / 3.0
		let fourThirds: Float = 4.0 / 3.0
		let xThird = third * x

		for _ in 0..<3 {
			let r2 = r * r
			r = (fourThirds * r).addingProduct(-xThird, r2 * r2)
		}

		var r2 = r * r
		r = r.addingProduct(third, r.addingProduct(-x, r2 * r2))
		r2 = r * r
		return add.addingProduct(r2, x)
	}

	/// Converts interleaved linear-sRGB samples to planar XYB.
	static func toXYB(linearRGB: [Float], pixelCount: Int) -> (
		x: [Float], y: [Float], b: [Float]
	) {
		var planeX = [Float](repeating: 0, count: pixelCount)
		var planeY = [Float](repeating: 0, count: pixelCount)
		var planeB = [Float](repeating: 0, count: pixelCount)

		for i in 0..<pixelCount {
			let r = linearRGB[i * 3]
			let g = linearRGB[i * 3 + 1]
			let b = linearRGB[i * 3 + 2]

			let mixed0 =
				opsinAbsorbanceBias
				.addingProduct(m02, b)
				.addingProduct(m01, g)
				.addingProduct(m00, r)
			let mixed1 =
				opsinAbsorbanceBias
				.addingProduct(m12, b)
				.addingProduct(m11, g)
				.addingProduct(m10, r)
			let mixed2 =
				opsinAbsorbanceBias
				.addingProduct(m22, b)
				.addingProduct(m21, g)
				.addingProduct(m20, r)

			// Wide-gamut input can still land slightly negative; the reference
			// clamps before the cube root.
			let tm0 = cubeRootAndAdd(max(mixed0, 0), negBiasCbrt)
			let tm1 = cubeRootAndAdd(max(mixed1, 0), negBiasCbrt)
			let tm2 = cubeRootAndAdd(max(mixed2, 0), negBiasCbrt)

			planeX[i] = 0.5 * (tm0 - tm1)
			planeY[i] = 0.5 * (tm0 + tm1)
			planeB[i] = tm2
		}
		return (planeX, planeY, planeB)
	}
}
