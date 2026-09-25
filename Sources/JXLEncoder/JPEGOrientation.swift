//
//  JPEGOrientation.swift
//  JXLEncoder
//
//  Reads the EXIF orientation a JPEG declares, without decoding it, so the
//  recompression path can be gated portably rather than through ImageIO.
//

extension JPEGParser {
	/// The EXIF orientation (IFD0 tag 0x0112), or nil when the JPEG declares
	/// none or its metadata cannot be read.
	///
	/// Only the segments before the first scan are searched: EXIF lives in APP1
	/// ahead of the frame, and stopping at SOS keeps entropy data unread.
	public static func exifOrientation(_ data: [UInt8]) -> Int? {
		guard data.count >= 4, data[0] == 0xFF, data[1] == 0xD8 else { return nil }
		var index = 2
		while index + 4 <= data.count {
			guard data[index] == 0xFF else { return nil }
			let marker = data[index + 1]
			// Fill bytes, and standalone markers that carry no length.
			if marker == 0xFF {
				index += 1
				continue
			}
			if marker == 0x01 || (0xD0...0xD7).contains(marker) {
				index += 2
				continue
			}
			// SOS or EOI: nothing further ahead is metadata.
			if marker == 0xDA || marker == 0xD9 { return nil }
			let length = Int(data[index + 2]) << 8 | Int(data[index + 3])
			let payload = index + 4
			let end = index + 2 + length
			guard length >= 2, end <= data.count else { return nil }
			if marker == 0xE1,
				let orientation = exifOrientation(
					data, payload: payload, end: end)
			{
				return orientation
			}
			index = end
		}
		return nil
	}

	/// Reads the orientation from one APP1 payload if it is an EXIF block.
	private static func exifOrientation(
		_ data: [UInt8], payload: Int, end: Int
	) -> Int? {
		let header: [UInt8] = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]  // "Exif\0\0"
		let tiff = payload + header.count
		guard tiff + 8 <= end, Array(data[payload..<tiff]) == header else {
			return nil
		}

		let littleEndian: Bool
		switch (data[tiff], data[tiff + 1]) {
		case (0x49, 0x49): littleEndian = true
		case (0x4D, 0x4D): littleEndian = false
		default: return nil
		}
		func read(_ offset: Int, _ count: Int) -> Int? {
			let start = tiff + offset
			guard offset >= 0, start + count <= end else { return nil }
			var value = 0
			for i in 0..<count {
				let byte = Int(data[start + (littleEndian ? count - 1 - i : i)])
				value = value << 8 | byte
			}
			return value
		}

		guard read(2, 2) == 42, let ifd0 = read(4, 4),
			let entries = read(ifd0, 2)
		else { return nil }
		for entry in 0..<entries {
			let base = ifd0 + 2 + entry * 12
			guard let tag = read(base, 2) else { return nil }
			guard tag == 0x0112 else { continue }
			// SHORT, count 1: the value sits in the first two bytes of the
			// entry's value field.
			guard read(base + 2, 2) == 3, read(base + 4, 4) == 1 else {
				return nil
			}
			return read(base + 8, 2)
		}
		return nil
	}
}
