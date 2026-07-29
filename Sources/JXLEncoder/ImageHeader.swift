//
//  ImageHeader.swift
//  JXLEncoder
//
//  Port of the codestream signature + image metadata written by libjxl-tiny's
//  encoder/enc_file.cc. Bare codestream only — no ISOBMFF container, which
//  ImageIO on macOS/iOS accepts directly.
//

/// How the decoder should interpret the sample values it reconstructs.
public enum TransferFunction: Sendable {
	/// What libjxl-tiny hardcodes. Kept so output stays byte-comparable with
	/// the reference encoder during differential testing.
	case linear
	/// Production default: input arrives as 8-bit sRGB, so the decoder should
	/// hand back sRGB rather than 16-bit linear.
	case sRGB

	var enumValue: UInt64 {
		switch self {
		case .linear: 8
		case .sRGB: 13
		}
	}
}

public enum ImageHeader {
	/// Reserved by ISO/IEC 10918-1; the 0xFF prefix also rules out 7-bit
	/// transmission damage.
	static let codestreamMarker: UInt64 = 0x0A

	static let maxDimension = 0x3FFF_FFFF

	public static func write(
		width: Int,
		height: Int,
		transferFunction: TransferFunction,
		to writer: inout BitWriter
	) throws {
		guard width > 0, height > 0 else { throw EncoderError.emptyImage }
		guard width <= maxDimension, height <= maxDimension else {
			throw EncoderError.imageTooLarge(width: width, height: height)
		}

		writer.write(8, 0xFF)
		writer.write(8, codestreamMarker)

		writer.write(1, 0)  // not small
		writeSize(height, to: &writer)
		writer.write(3, 0)  // no aspect ratio shortcut
		writeSize(width, to: &writer)

		writer.write(1, 0)  // not all default image metadata
		writer.write(1, 0)  // no extra fields
		writer.write(1, 1)  // floating point samples
		writer.write(2, 0)  // 32 bits per sample
		writer.write(4, 7)  // 8 exponent bits
		writer.write(1, 0)  // modular 16 bit sufficient
		writer.write(2, 0)  // no extra channels
		writer.write(1, 1)  // xyb encoded
		writer.write(1, 0)  // not all default color encoding
		writer.write(1, 0)  // no icc
		writer.write(2, 0)  // RGB color space
		writer.write(2, 1)  // D65 white point
		writer.write(2, 1)  // sRGB primaries
		writer.write(1, 0)  // no gamma
		writer.write(2, 2)  // transfer function selector bits (2 .. 17)
		writer.write(4, transferFunction.enumValue - 2)
		writer.write(2, 1)  // relative rendering intent
		writer.write(2, 0)  // no extensions
		writer.write(1, 1)  // all default transform data
		writer.zeroPadToByte()
	}

	static func writeSize(_ size: Int, to writer: inout BitWriter) {
		let value = UInt64(size - 1)
		for (selector, bits) in [9, 13, 18, 30].enumerated() {
			if value < (UInt64(1) << UInt64(bits)) {
				writer.write(2, UInt64(selector))
				writer.write(bits, value)
				return
			}
		}
	}
}
