//
//  ReciprocalEstimate.swift
//  JXLEncoder
//
//  libjxl-tiny's `AdjustQuantBias` calls Highway's `ApproximateReciprocal`,
//  which lowers to `vrecpeq_f32` on arm64 but to an exact division in the
//  portable fallback. Those disagree by ~1e-3 relative, and the result feeds the
//  dequantized Y used to decorrelate the B channel — so the reference's own
//  output depends on which target it was built for.
//
//  This reproduces the arm64 instruction, whose result Arm specifies exactly
//  (FPRecipEstimate / RecipEstimate). Written in portable Swift it is
//  deterministic on every architecture, so our output does not inherit the
//  reference's target dependence.
//

enum ReciprocalEstimate {
	/// Arm's `RecipEstimate`: reciprocal of a 9-bit fixed-point value.
	static func recipEstimate(_ a: Int) -> Int {
		let rounded = a * 2 + 1
		let b = (1 << 19) / rounded
		return (b + 1) / 2
	}

	/// Reproduces `vrecpeq_f32` for one lane.
	static func apply(_ value: Float) -> Float {
		let bits = value.bitPattern
		let sign = bits & 0x8000_0000
		let exponent = Int((bits >> 23) & 0xFF)
		let fraction = bits & 0x007F_FFFF

		// Infinity and NaN
		if exponent == 0xFF {
			return fraction == 0 ? Float(bitPattern: sign) : Float.nan
		}
		// Zero returns an infinity of the same sign.
		if exponent == 0 && fraction == 0 {
			return Float(bitPattern: sign | 0x7F80_0000)
		}
		// Values whose reciprocal overflows return infinity; those whose input is
		// large enough that the reciprocal underflows return a signed zero.
		if exponent == 0 {
			// Subnormal input: the reciprocal overflows the float range.
			return Float(bitPattern: sign | 0x7F80_0000)
		}
		if exponent >= 253 {
			return Float(bitPattern: sign)
		}

		let scaled = Int(0x100 | (fraction >> 15))
		let resultExponent = 253 - exponent
		let estimate = recipEstimate(scaled)
		let resultFraction = UInt32(estimate & 0xFF) << 15
		return Float(bitPattern: sign | (UInt32(resultExponent) << 23) | resultFraction)
	}
}
