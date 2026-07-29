//
//  FastMath.swift
//  JXLEncoder
//
//  Port of the polynomial approximations in libjxl-tiny's
//  encoder/fast_math-inl.h. These are deliberately *not* libm: the encoder's
//  heuristics are tuned around these exact approximations, and substituting
//  accurate versions changes the quantization field.
//

enum FastMath {
	/// Base-2 logarithm via a 2,2 rational polynomial after range reduction.
	/// Undefined for negative or NaN input, matching the reference.
	static func log2(_ x: Float) -> Float {
		let p0: Float = -1.850_383_340_051_831_0e-06
		let p1: Float = 1.428_716_047_008_375_5
		let p2: Float = 7.424_587_332_782_056_6e-01
		let q0: Float = 9.903_281_427_759_071_9e-01
		let q1: Float = 1.009_671_857_224_114_8
		let q2: Float = 1.740_934_300_336_685_3e-01

		let xBits = Int32(bitPattern: x.bitPattern)
		// Range reduction to [-1/3, 1/3]; 0x3f2aaaab is 2/3.
		let expBits = xBits &- 0x3F2A_AAAB
		let expShifted = expBits >> 23
		let mantissa = Float(bitPattern: UInt32(bitPattern: xBits &- (expShifted << 23)))
		let expValue = Float(expShifted)

		let t = mantissa - 1.0
		var yp = p2
		var yq = q2
		yp = p1.addingProduct(yp, t)
		yq = q1.addingProduct(yq, t)
		yp = p0.addingProduct(yp, t)
		yq = q0.addingProduct(yq, t)
		return yp / yq + expValue
	}

	/// 2^x, max relative error ~3e-7.
	static func pow2(_ x: Float) -> Float {
		let floored = x.rounded(.down)
		let exponent = Float(
			bitPattern: UInt32(bitPattern: (Int32(floored) &+ 127) << 23))
		let frac = x - floored

		var num = frac + 1.017_490_63e+01
		num = Float(4.886_877_98e+01).addingProduct(num, frac)
		num = Float(9.855_065_91e+01).addingProduct(num, frac)
		num = num * exponent

		var den = Float(-2.223_288_56e-02).addingProduct(frac, 2.102_429_58e-01)
		den = Float(-1.944_149_90e+01).addingProduct(den, frac)
		den = Float(9.855_066_33e+01).addingProduct(den, frac)
		return num / den
	}

	// Scaling difference between jxl's opsin space and butteraugli's.
	static let sgMul: Float = 226.048_044_670_588_3
	static let sgMul2: Float = 1.0 / 73.377_132_366_608_819
	static let log2Constant: Float = 0.693_147_181
	/// Includes the correction from `std::log` to log2.
	static let sgRetMul: Float = sgMul2 * 18.658_093_213_5 * log2Constant
	static let sgVOffset: Float = 7.146_724_700_03

	/// Ratio of the derivative of jxl's cubic-root opsin space to butteraugli's
	/// simple-gamma space, letting quantization move between the two.
	static func ratioOfDerivativesOfCubicRootToSimpleGamma(
		_ value: Float, invert: Bool
	) -> Float {
		let epsilon: Float = 1e-2
		let v = max(value, 0)
		let numMul = sgRetMul * 3 * sgMul
		let vOffset = sgVOffset * log2Constant + epsilon
		let denMul = log2Constant * sgMul

		let v2 = v * v
		let num = epsilon.addingProduct(numMul, v2)
		let den = vOffset.addingProduct(denMul * v, v2)
		return invert ? num / den : den / num
	}

	static func maskingSqrt(_ v: Float) -> Float {
		let logOffset: Float = 26.481_471_032_459_346
		let mul: Float = 211.507_598_996_380_12
		// `kMul * 1e8` promotes to double in the reference before narrowing.
		let mulV = Float(Double(mul) * 1e8)
		return 0.25 * logOffset.addingProduct(v, mulV.squareRoot()).squareRoot()
	}
}
