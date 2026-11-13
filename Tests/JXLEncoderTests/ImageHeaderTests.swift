import Testing

@testable import JXLEncoder

/// Expected bytes are the leading header of real `cjxl_tiny` output, so these
/// are differential tests against the reference encoder rather than against our
/// own reading of the spec. Header length is 11 bytes when a dimension needs
/// the 13-bit size selector (600) and 10 bytes when 9 bits suffice (200, 512).
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
