import Testing

@testable import JXLEncoder

/// The portable input policy: EXIF orientation read without a decoder, the
/// recompression gate built on it, and JPEG XL signature detection.
@Suite("Portable JPEG recompression")
struct PortableJPEGRecompressionTests {
	/// An APP1 EXIF segment whose IFD0 holds only an orientation entry.
	static func exifSegment(orientation: Int, littleEndian: Bool) -> [UInt8] {
		func u16(_ v: Int) -> [UInt8] {
			let bytes = [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
			return littleEndian ? bytes.reversed() : bytes
		}
		func u32(_ v: Int) -> [UInt8] {
			let bytes = [
				UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF),
				UInt8(v & 0xFF),
			]
			return littleEndian ? bytes.reversed() : bytes
		}
		var tiff: [UInt8] = littleEndian ? [0x49, 0x49] : [0x4D, 0x4D]
		tiff += u16(42) + u32(8)
		tiff += u16(1)  // one entry
		// Orientation: SHORT, count 1, value left-justified in the 4-byte field.
		tiff += u16(0x0112) + u16(3) + u32(1) + u16(orientation) + [0, 0]
		tiff += u32(0)  // no next IFD
		let payload: [UInt8] = [0x45, 0x78, 0x69, 0x66, 0, 0] + tiff
		let length = payload.count + 2
		return [0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)] + payload
	}

	/// A fixture JPEG with an EXIF segment spliced in straight after SOI.
	static func jpeg(orientation: Int?, littleEndian: Bool = false) throws -> [UInt8] {
		let source = try JPEGParserTests.fixture("small_444")
		guard let orientation else { return source }
		return Array(source[0..<2])
			+ exifSegment(orientation: orientation, littleEndian: littleEndian)
			+ Array(source[2...])
	}

	@Test("orientation reads in both byte orders", arguments: [false, true])
	func readsOrientation(littleEndian: Bool) throws {
		for orientation in 1...8 {
			let data = try Self.jpeg(
				orientation: orientation, littleEndian: littleEndian)
			#expect(JPEGParser.exifOrientation(data) == orientation)
		}
	}

	@Test("no EXIF reads as no orientation")
	func noExif() throws {
		#expect(JPEGParser.exifOrientation(try Self.jpeg(orientation: nil)) == nil)
	}

	@Test("malformed input reads as no orientation")
	func malformed() throws {
		let data = try Self.jpeg(orientation: 6)
		// Every truncation that cuts the EXIF segment short, and garbage.
		let segmentEnd = 2 + Self.exifSegment(orientation: 6, littleEndian: false).count
		for cut in 0..<segmentEnd {
			#expect(JPEGParser.exifOrientation(Array(data.prefix(cut))) == nil)
		}
		#expect(JPEGParser.exifOrientation([0x00, 0x01, 0x02]) == nil)
		#expect(JPEGParser.exifOrientation([0xFF, 0xD8, 0xFF, 0xE1, 0xFF, 0xFF]) == nil)
	}

	@Test("an upright JPEG recompresses; no EXIF counts as upright")
	func uprightRecompresses() throws {
		let upright = try #require(Encoder.recompressJPEG(try Self.jpeg(orientation: 1)))
		let plain = try #require(Encoder.recompressJPEG(try Self.jpeg(orientation: nil)))
		#expect(upright.starts(with: [0xFF, 0x0A]))
		#expect(upright == plain)
	}

	@Test("a rotated JPEG is declined", arguments: 2...8)
	func rotatedDeclined(orientation: Int) throws {
		#expect(Encoder.recompressJPEG(try Self.jpeg(orientation: orientation)) == nil)
	}

	@Test("non-JPEG and unsupported JPEG are declined")
	func declined() throws {
		#expect(Encoder.recompressJPEG([0x89, 0x50, 0x4E, 0x47]) == nil)
		#expect(
			Encoder.recompressJPEG(try JPEGParserTests.fixture("reject_arithmetic"))
				== nil)
	}

	@Test("JPEG XL signatures")
	func signatures() throws {
		let recompressed = try #require(
			Encoder.recompressJPEG(try Self.jpeg(orientation: nil)))
		#expect(JXLSignature.matches(recompressed))
		#expect(
			JXLSignature.matches([
				0x00, 0x00, 0x00, 0x0C, 0x4A, 0x58, 0x4C, 0x20, 0x0D, 0x0A, 0x87,
				0x0A, 0x00,
			]))
		#expect(!JXLSignature.matches(try Self.jpeg(orientation: nil)))
		#expect(!JXLSignature.matches([0xFF]))
		#expect(!JXLSignature.matches([]))
	}
}
