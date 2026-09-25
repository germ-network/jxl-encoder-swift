//
//  JPEGRecompression.swift
//  JXLEncoder
//
//  Portable entry points for platform shims: recognise JPEG XL that needs no
//  work, and take a JPEG down the coefficient path when it can.
//

/// Recognises JPEG XL by its signature: the bare codestream or the ISOBMFF
/// container.
public enum JXLSignature {
	static let codestream: [UInt8] = [0xFF, 0x0A]
	static let container: [UInt8] = [
		0x00, 0x00, 0x00, 0x0C, 0x4A, 0x58, 0x4C, 0x20, 0x0D, 0x0A, 0x87, 0x0A,
	]

	public static func matches(_ data: [UInt8]) -> Bool {
		data.starts(with: codestream) || data.starts(with: container)
	}
}

extension Encoder {
	/// Re-codes a JPEG from its own quantized coefficients, or returns nil if
	/// this one cannot take that path.
	///
	/// A non-JPEG, or a layout the parser declines (progressive,
	/// arithmetic-coded, CMYK, …), returns nil so the caller can decode and
	/// re-encode the pixels instead. The output declares no orientation, so a
	/// caller that must keep a rotated source upright checks
	/// `JPEGParser.exifOrientation` first.
	public static func recompressJPEG(
		_ data: [UInt8],
		maxCoefficientBytes: Int = JPEGParser.defaultMaxCoefficientBytes
	) -> [UInt8]? {
		guard data.count >= 2, data[0] == 0xFF, data[1] == 0xD8 else { return nil }
		do {
			let image = try JPEGParser.parse(
				data, maxCoefficientBytes: maxCoefficientBytes)
			return try encodeJPEG(try JPEGTranscode(image))
		} catch {
			return nil
		}
	}
}
