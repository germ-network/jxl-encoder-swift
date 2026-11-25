import Testing

@testable import JXLEncoder

/// Expected bytes are the leading header of real `cjxl_tiny` output, so these
/// are differential tests against the reference encoder rather than against our
/// own reading of the spec. Header length is 11 bytes when a dimension needs
/// the 13-bit size selector (600) and 10 bytes when 9 bits suffice (200, 512).
/// The unprofiled 64×64 goldens were captured from the writer before ICC support.
@Suite("ImageHeader")
struct ImageHeaderTests {
	struct HeaderBits {
		let bytes: [UInt8]
		var offset = 0

		mutating func read(_ count: Int) -> Int {
			var value = 0
			for bit in 0..<count {
				value |= Int((bytes[offset / 8] >> (offset % 8)) & 1) << bit
				offset += 1
			}
			return value
		}

		mutating func size() -> (selector: Int, value: Int, bitCount: Int) {
			let selector = read(2)
			let bits = [9, 13, 18, 30][selector]
			return (selector, read(bits) + 1, bits)
		}

		/// Reads a `U64` field as libjxl `U64Coder::Read` does (fields.cc:494-520).
		mutating func u64() -> UInt64 {
			switch read(2) {
			case 0: return 0
			case 1: return 1 + UInt64(read(4))
			case 2: return 17 + UInt64(read(8))
			default:
				var result = UInt64(read(12))
				var shift: UInt64 = 12
				while read(1) == 1 {
					if shift == 60 {
						result |= UInt64(read(4)) << shift
						break
					}
					result |= UInt64(read(8)) << shift
					shift += 8
				}
				return result
			}
		}
	}

	func header(
		width: Int,
		height: Int,
		transferFunction: TransferFunction = .linear
	) throws -> [UInt8] {
		var w = BitWriter()
		try ImageHeader.write(
			width: width, height: height, transferFunction: transferFunction, to: &w)
		return w.take()
	}

	@Test("600x600 linear matches cjxl_tiny")
	func linear600() throws {
		#expect(
			try header(width: 600, height: 600)
				== [
					0xFF, 0x0A, 0xBA, 0x12, 0xE8, 0x4A, 0x90, 0x43, 0x28, 0x5A,
					0x04,
				])
	}

	@Test("600x600 sRGB differs from linear only in the transfer function field")
	func srgb600() throws {
		let linear = try header(width: 600, height: 600, transferFunction: .linear)
		let srgb = try header(width: 600, height: 600, transferFunction: .sRGB)
		#expect(srgb == [0xFF, 0x0A, 0xBA, 0x12, 0xE8, 0x4A, 0x90, 0x43, 0x28, 0x6E, 0x04])
		#expect(zip(linear, srgb).filter { $0 != $1 }.count == 1)
	}

	@Test("200x200 matches cjxl_tiny")
	func linear200() throws {
		#expect(
			try header(width: 200, height: 200)
				== [0xFF, 0x0A, 0x38, 0x06, 0x8E, 0x91, 0x43, 0x28, 0x5A, 0x04])
	}

	@Test("512x512 matches cjxl_tiny")
	func linear512() throws {
		#expect(
			try header(width: 512, height: 512)
				== [0xFF, 0x0A, 0xF8, 0x0F, 0xFE, 0x93, 0x43, 0x28, 0x5A, 0x04])
	}

	@Test("rejects empty and oversized images")
	func bounds() {
		#expect(throws: EncoderError.emptyImage) { try header(width: 0, height: 10) }
		#expect(throws: EncoderError.emptyImage) { try header(width: 10, height: 0) }
		#expect(throws: EncoderError.self) {
			try header(width: ImageHeader.maxDimension + 1, height: 10)
		}
	}

	@Test(
		"size selectors, header length and zero padding match each dimension",
		arguments: [
			1, 7, 8, 9, 15, 16, 17, 255, 256, 257, 512, 513, 8192, 8193, 262_144,
			262_145, ImageHeader.maxDimension,
		])
	func sizeSelectors(dimension: Int) throws {
		let bytes = try header(width: dimension, height: dimension)
		#expect(bytes.starts(with: [0xFF, 0x0A]))
		var bits = HeaderBits(bytes: bytes)
		#expect(bits.read(16) == 0x0AFF)
		#expect(bits.read(1) == 0)
		let height = bits.size()
		#expect(height.value == dimension)
		let expectedSelector =
			dimension <= 512 ? 0 : dimension <= 8192 ? 1 : dimension <= 262_144 ? 2 : 3
		#expect(height.selector == expectedSelector)
		#expect(bits.read(3) == 0)
		let width = bits.size()
		#expect(width.value == dimension)
		#expect(width.selector == expectedSelector)
		let contentBits = 57 + height.bitCount + width.bitCount
		#expect(bytes.count == (contentBits + 7) / 8)
		let usedInLastByte = contentBits % 8
		if usedInLastByte != 0 {
			let paddingMask = UInt8(truncatingIfNeeded: 0xFF << usedInLastByte)
			#expect(bytes.last! & paddingMask == 0)
		}
		let asymmetric = try header(width: dimension, height: 513)
		var asymmetricBits = HeaderBits(bytes: asymmetric)
		_ = asymmetricBits.read(16)
		_ = asymmetricBits.read(1)
		let asymmetricHeight = asymmetricBits.size()
		#expect(asymmetricHeight.value == 513)
		#expect(asymmetricHeight.selector == 1)
		_ = asymmetricBits.read(3)
		let asymmetricWidth = asymmetricBits.size()
		#expect(asymmetricWidth.value == dimension)
		#expect(asymmetricWidth.selector == expectedSelector)
	}

}

extension ImageHeaderTests {
	static func displayP3() throws -> ICCProfile {
		try ICCProfile(validating: ICCCodecTests.displayP3())
	}

	/// A 64×64 JPEG-transcode header, read up to the colour encoding's
	/// all_default bit.
	static func jpegHeaderBits(iccProfile: ICCProfile?) throws -> HeaderBits {
		var w = BitWriter()
		try ImageHeader.write(
			width: 64, height: 64, transferFunction: .sRGB, xybEncoded: false,
			isGrayscale: false, iccProfile: iccProfile, to: &w)
		var bits = HeaderBits(bytes: w.take())
		#expect(bits.read(16) == 0x0AFF)
		#expect(bits.read(1) == 0)
		_ = bits.size()
		#expect(bits.read(3) == 0)
		_ = bits.size()
		// all_default, extra_fields, integer 8-bit samples, modular 16 bit,
		// no extra channels, not xyb, colour encoding not all_default.
		for (count, value) in [
			(1, 0), (1, 0), (1, 0), (2, 0), (1, 1), (2, 0), (1, 0), (1, 0),
		] {
			#expect(bits.read(count) == value)
		}
		return bits
	}

	@Test("a nil profile leaves the header bytes unchanged")
	func unprofiledHeaderUnchanged() throws {
		let expected: [(xyb: Bool, gray: Bool, tf: TransferFunction, bytes: [UInt8])] = [
			(
				true, false, .sRGB,
				[0xFF, 0x0A, 0xF8, 0x01, 0x7E, 0x90, 0x43, 0x28, 0x6E, 0x04]
			),
			(
				true, false, .linear,
				[0xFF, 0x0A, 0xF8, 0x01, 0x7E, 0x90, 0x43, 0x28, 0x5A, 0x04]
			),
			(
				true, true, .sRGB,
				[0xFF, 0x0A, 0xF8, 0x01, 0x7E, 0x90, 0x43, 0x8A, 0x1B, 0x01]
			),
			(
				true, true, .linear,
				[0xFF, 0x0A, 0xF8, 0x01, 0x7E, 0x90, 0x43, 0x8A, 0x16, 0x01]
			),
			(
				false, false, .sRGB,
				[0xFF, 0x0A, 0xF8, 0x01, 0x7E, 0x80, 0x80, 0xE2, 0x46]
			),
			(
				false, false, .linear,
				[0xFF, 0x0A, 0xF8, 0x01, 0x7E, 0x80, 0x80, 0xA2, 0x45]
			),
			(
				false, true, .sRGB,
				[0xFF, 0x0A, 0xF8, 0x01, 0x7E, 0x80, 0xA0, 0xB8, 0x11]
			),
			(
				false, true, .linear,
				[0xFF, 0x0A, 0xF8, 0x01, 0x7E, 0x80, 0xA0, 0x68, 0x11]
			),
		]
		for (xyb, gray, tf, bytes) in expected {
			var w = BitWriter()
			try ImageHeader.write(
				width: 64, height: 64, transferFunction: tf, xybEncoded: xyb,
				isGrayscale: gray, iccProfile: nil, to: &w)
			#expect(w.take() == bytes)
		}
	}

	/// ColorEncoding::VisitFields (color_encoding_internal.cc:151-158) sends
	/// colour_space even with want_icc, then skips every enum.
	@Test("a profile sets want_icc and the RGB colour space and nothing else")
	func iccHeaderSignalsWantICCAndRGB() throws {
		var bits = try Self.jpegHeaderBits(iccProfile: Self.displayP3())
		#expect(bits.read(1) == 1)  // want_icc
		#expect(bits.read(2) == 0)  // RGB
		#expect(bits.u64() == 0)  // no extensions
		#expect(bits.read(1) == 1)  // all default transform data
		#expect(bits.u64() == UInt64(ICCCodec.predict(try Self.displayP3().bytes).count))

		var plain = try Self.jpegHeaderBits(iccProfile: nil)
		#expect(plain.read(1) == 0)
	}

	@Test("the coded ICC follows the transform data and precedes byte padding")
	func codedICCFollowsTransformDataBeforePadding() throws {
		let profile = try Self.displayP3()
		var bits = try Self.jpegHeaderBits(iccProfile: profile)
		_ = bits.read(1 + 2 + 2 + 1)
		var icc = BitWriter()
		ICCCodec.write(profile, to: &icc)
		#expect(icc.bitsWritten > 0)
		var expected = icc
		expected.zeroPadToByte()
		var coded = HeaderBits(bytes: expected.take())
		let header = (0..<icc.bitsWritten).map { _ in bits.read(1) }
		#expect(header == (0..<icc.bitsWritten).map { _ in coded.read(1) })
		#expect(bits.bytes.count == (bits.offset + 7) / 8)
		#expect(bits.read((8 - bits.offset % 8) % 8) == 0)
	}
}
