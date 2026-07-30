import Testing

@testable import JXLEncoder

/// The transcode view has to reproduce libjxl's ingestion exactly, because the
/// coefficients cross into the JXL bitstream untouched: any disagreement about
/// which component a channel reads, or which way a block is transposed, decodes
/// as swapped colours or a transposed image rather than as a coding error.
@Suite("JPEG transcode layout")
struct JPEGTranscodeTests {
	static func transcode(_ name: String) throws -> JPEGTranscode {
		try JPEGTranscode(try JPEGParser.parse(try JPEGParserTests.fixture(name)))
	}

	/// libjxl's `JpegOrder(kYCbCr, is_gray: false)` is `{1, 0, 2}`: JXL orders
	/// channels X, Y, B, and a YCbCr transform reads those as Cb, Y, Cr.
	@Test("colour channels map Cb, Y, Cr")
	func colourChannelOrder() throws {
		let transcode = try Self.transcode("small_444")
		#expect(transcode.componentMap == [1, 0, 2])
		// Component identifiers in a JFIF file are 1=Y, 2=Cb, 3=Cr.
		#expect(transcode.component(0).identifier == 2)
		#expect(transcode.component(1).identifier == 1)
		#expect(transcode.component(2).identifier == 3)
	}

	/// `JpegOrder(_, is_gray: true)` is `{0, 0, 0}` — one component, read three
	/// times, and the chroma planes come out zero.
	@Test("grey maps every channel to the single component")
	func greyChannelOrder() throws {
		let transcode = try Self.transcode("hopper_gray_odd")
		#expect(transcode.componentMap == [0, 0, 0])
		#expect(transcode.subsampling.is444)
	}

	/// JXL transposes the DCT relative to JPEG, so both the coefficients and the
	/// quantization table are indexed the other way round.
	@Test("blocks are transposed")
	func blockTransposed() throws {
		let transcode = try Self.transcode("small_444")
		let component = transcode.component(1)
		let block = transcode.block(channel: 1, x: 0, y: 0)
		for row in 0..<8 {
			for column in 0..<8 {
				#expect(
					block[column * 8 + row]
						== component.coefficients[row * 8 + column])
			}
		}
		// A transpose is only observable on an asymmetric block, so make sure the
		// fixture actually has off-diagonal structure to catch it.
		var asymmetric = false
		for row in 0..<8 {
			for column in 0..<8 where row != column {
				let a = component.coefficients[row * 8 + column]
				let b = component.coefficients[column * 8 + row]
				if a != b { asymmetric = true }
			}
		}
		#expect(asymmetric, "fixture block is symmetric — the test cannot fail")
	}

	@Test("quant tables are transposed")
	func quantTransposed() throws {
		let transcode = try Self.transcode("small_444")
		let raw = transcode.image.quantTables[transcode.component(1).quantTableIndex]
		let transposed = transcode.quantTable(channel: 1)
		for y in 0..<8 {
			for x in 0..<8 {
				#expect(transposed[8 * x + y] == raw[8 * y + x])
			}
		}
	}

	/// `dcquantization[c] = 255 * 8 / quant[0]`, and the DC coefficient itself
	/// crosses over untouched because a JPEG transcode signals YCbCr.
	@Test("DC quantization and values")
	func dcHandling() throws {
		let transcode = try Self.transcode("small_444")
		for channel in 0..<3 {
			let quant = transcode.image.quantTables[
				transcode.component(channel).quantTableIndex][0]
			#expect(
				transcode.dcQuantization(channel: channel) == 255 * 8 / Float(quant)
			)
		}
		let dc = transcode.dc(channel: 1, x: 0, y: 0)
		#expect(dc == transcode.component(1).coefficients[0])
		#expect(dc == transcode.block(channel: 1, x: 0, y: 0)[0])
	}

	/// Subsampling comes from the JPEG's sampling factors and has to survive the
	/// same component swap the channels do.
	@Test(
		"subsampling follows the sampling factors",
		arguments: [
			("small_444", true), ("small_422", false), ("small_440", false),
			("hopper_420_odd", false),
		])
	func subsampling(name: String, is444: Bool) throws {
		let transcode = try Self.transcode(name)
		#expect(transcode.subsampling.is444 == is444)
		// Luma is never subsampled, and it sits in channel 1.
		#expect(transcode.subsampling.horizontalShift(1) == 0)
		#expect(transcode.subsampling.verticalShift(1) == 0)
	}

	/// 4:1:1 needs a horizontal shift of two, and JXL carries a two-bit mode per
	/// channel covering shifts of zero and one only. This is a limit of the
	/// format rather than of the port — `cjxl --lossless_jpeg=1` refuses the same
	/// file — so such input has to fall back to the pixel path.
	@Test("4:1:1 is refused because JXL cannot express it")
	func subsamplingBeyondTheFormat() throws {
		let image = try JPEGParser.parse(try JPEGParserTests.fixture("small_411"))
		#expect(image.components[1].horizontalSampling == 1)
		#expect(image.components[0].horizontalSampling == 4)
		#expect(throws: JPEGTranscode.TranscodeError.unsupportedSubsampling) {
			try JPEGTranscode(image)
		}
	}

	/// Every block the JPEG stores must be addressable, including the padding
	/// blocks past the image edge that the MCU grid forces.
	@Test("every stored block is addressable", arguments: ["small_444", "small_422"])
	func blocksAddressable(name: String) throws {
		let transcode = try Self.transcode(name)
		for channel in 0..<3 {
			let component = transcode.component(channel)
			let last = transcode.block(
				channel: channel,
				x: component.blocksPerLine - 1, y: component.blocksPerColumn - 1)
			#expect(last.count == 64)
			#expect(
				component.coefficients.count
					== component.blocksPerLine * component.blocksPerColumn * 64)
		}
	}
}
