//
//  Float16Coder.swift
//  JXLEncoder
//
//  Port of `F16Coder::Write` from libjxl's lib/jxl/enc_fields.cc. Half floats
//  carry the quantization values a JPEG transcode has to transmit, which
//  libjxl-tiny never needs because it only ever signals the default tables.
//
//  The mantissa is truncated rather than rounded — `mantissa32 >> 13`, with no
//  round-to-nearest. Rounding here would be more accurate and would disagree
//  with every decoder, so the reference's behaviour is the correct one.
//

enum Float16Coder {
	/// Largest magnitude a half float can hold.
	static let maxMagnitude: Float = 65504

	enum Float16Error: Error, Equatable, Sendable {
		/// Infinity, NaN, or beyond the half-float range.
		case notRepresentable(Float)
	}

	/// The 16 bits `value` encodes to.
	static func bits(_ value: Float) throws -> UInt16 {
		guard value.isFinite, value.magnitude <= maxMagnitude else {
			throw Float16Error.notRepresentable(value)
		}

		let bits32 = value.bitPattern
		let sign = bits32 >> 31
		let biasedExponent32 = (bits32 >> 23) & 0xFF
		let mantissa32 = bits32 & 0x7F_FFFF
		let exponent = Int32(biasedExponent32) - 127

		// Anything below the smallest subnormal collapses to zero, sign included.
		if exponent < -24 { return 0 }

		let biasedExponent16: UInt32
		let mantissa16: UInt32
		if exponent < -14 {
			// Subnormal: the implicit leading one becomes explicit, and the
			// mantissa shifts down by however far the exponent underflows.
			biasedExponent16 = 0
			let subExponent = UInt32(-14 - exponent)
			mantissa16 = (1 << (10 - subExponent)) + (mantissa32 >> (13 + subExponent))
		} else {
			biasedExponent16 = UInt32(exponent + 15)
			mantissa16 = mantissa32 >> 13
		}

		return UInt16((sign << 15) | (biasedExponent16 << 10) | mantissa16)
	}

	static func write(_ value: Float, to writer: inout BitWriter) throws {
		writer.write(16, UInt64(try bits(value)))
	}

	/// What a decoder reads back, so a round-trip can be checked without one.
	/// Ported from `F16Coder::Read`.
	static func value(fromBits bits16: UInt16) -> Float {
		let sign = UInt32(bits16) >> 15
		let biasedExponent = (UInt32(bits16) >> 10) & 0x1F
		let mantissa = UInt32(bits16) & 0x3FF

		if biasedExponent == 0 {
			let magnitude = (1.0 / 16384) * (Float(mantissa) * (1.0 / 1024))
			return sign == 1 ? -magnitude : magnitude
		}
		let biasedExponent32 = biasedExponent + (127 - 15)
		let mantissa32 = mantissa << (23 - 10)
		return Float(bitPattern: (sign << 31) | (biasedExponent32 << 23) | mantissa32)
	}
}
