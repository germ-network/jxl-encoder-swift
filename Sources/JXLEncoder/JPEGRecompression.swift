//
//  JPEGRecompression.swift
//  JXLEncoder
//
//  The portable half of the input policy platform shims share: recognise JPEG
//  XL that needs no work, and take a JPEG down the coefficient path when it can.
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
	/// Recompression is an optimisation, never a requirement: a non-JPEG, a
	/// layout the parser declines (progressive, arithmetic-coded, CMYK, …), or a
	/// non-identity EXIF orientation all return nil so the caller decodes and
	/// re-encodes the pixels instead. Orientation is declined because the
	/// coefficients cross over verbatim and the output declares none, so a
	/// rotated source would decode unrotated.
	public static func recompressJPEG(
		_ data: [UInt8],
		maxCoefficientBytes: Int = JPEGParser.defaultMaxCoefficientBytes
	) -> [UInt8]? {
		guard data.count >= 2, data[0] == 0xFF, data[1] == 0xD8 else { return nil }
		if let orientation = JPEGParser.exifOrientation(data), orientation != 1 {
			return nil
		}
		do {
			let image = try JPEGParser.parse(
				data, maxCoefficientBytes: maxCoefficientBytes)
			return try encodeJPEG(try JPEGTranscode(image))
		} catch {
			return nil
		}
	}
}
