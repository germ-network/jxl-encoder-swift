import Testing

@testable import JXLEncoder

/// Expected bytes are the leading header of real `cjxl_tiny` output, so these
/// are differential tests against the reference encoder rather than against our
/// own reading of the spec. Header length is 11 bytes when a dimension needs
/// the 13-bit size selector (600) and 10 bytes when 9 bits suffice (200, 512).
@Suite("ImageHeader")
struct ImageHeaderTests {
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

	@Test("size selector widens with dimension", arguments: [1, 512, 513, 8192, 8193, 262_144])
	func sizeSelectors(dimension: Int) throws {
		let bytes = try header(width: dimension, height: dimension)
		#expect(bytes.starts(with: [0xFF, 0x0A]))
	}
}
