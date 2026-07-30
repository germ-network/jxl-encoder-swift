import Testing

@testable import JXLEncoder

/// A JPEG transcode signals YCbCr rather than XYB, which moves three things in
/// the headers. Getting any of them wrong shifts every following field, so the
/// stream decodes as noise rather than reporting an error.
///
/// Field order verified against `lib/jxl/frame_header.cc` and against a
/// codestream extracted from `cjxl --lossless_jpeg=1`, whose image header reads
/// back with `xyb_encoded = 0`.
@Suite("YCbCr signalling")
struct YCbCrHeaderTests {
	/// Reads back what `BitWriter` packs: LSB first within each byte.
	struct BitReader {
		let bytes: [UInt8]
		var position = 0

		mutating func read(_ count: Int) -> UInt64 {
			var value: UInt64 = 0
			for i in 0..<count {
				let bit = (bytes[position >> 3] >> (position & 7)) & 1
				value |= UInt64(bit) << UInt64(i)
				position += 1
			}
			return value
		}
	}

	static func header(_ mode: FrameAssembly.ColorMode) -> BitWriter {
		var writer = BitWriter()
		FrameAssembly.writeFrameHeader(
			colorMode: mode, epfIterations: 2, writer: &writer)
		return writer
	}

	/// The colour-transform bit and the subsampling modes only exist in YCbCr;
	/// the two quant-matrix scales only exist in XYB. Net, YCbCr is one bit
	/// longer: +1 transform, +6 subsampling, −6 scales.
	@Test("YCbCr trades the quant-matrix scales for a transform and subsampling")
	func fieldsSwapped() {
		let xyb = Self.header(.xyb(xQuantMatrixScale: 3))
		let ycbcr = Self.header(.ycbcr(subsampling: .none))
		#expect(ycbcr.bitsWritten == xyb.bitsWritten + 1)
	}

	/// Walk the header to the colour transform and check it, rather than trusting
	/// the length arithmetic alone.
	@Test("the transform bit says YCbCr and subsampling follows it")
	func transformBitSet() {
		let subsampling = ChromaSubsampling(channelMode: [1, 0, 1])  // 4:2:0
		// A frame header does not end on a byte, and `take()` insists on one.
		var writer = Self.header(.ycbcr(subsampling: subsampling))
		writer.zeroPadToByte()
		var reader = BitReader(bytes: writer.take())

		#expect(reader.read(1) == 0)  // not all default
		#expect(reader.read(2) == 0)  // regular frame
		#expect(reader.read(1) == 0)  // VarDCT
		#expect(reader.read(2) == 2)  // flags selector
		#expect(reader.read(8) == 111)  // flags payload
		#expect(reader.read(1) == 1, "colour transform: YCbCr, not none")
		for channel in 0..<3 {
			#expect(reader.read(2) == UInt64(subsampling.channelMode[channel]))
		}
		#expect(reader.read(2) == 0)  // no upsampling
		// In XYB the next six bits would be x_qm_scale and b_qm_scale. Here the
		// pass count follows immediately.
		#expect(reader.read(2) == 0, "one pass")
	}

	/// The image header's `xyb_encoded` bit is what makes the frame header's
	/// colour-transform field exist at all, so the two have to be set together.
	@Test("xyb_encoded reaches the image header", arguments: [true, false])
	func xybEncodedBit(xyb: Bool) throws {
		var writer = BitWriter()
		try ImageHeader.write(
			width: 64, height: 64, transferFunction: .sRGB, xybEncoded: xyb,
			to: &writer)
		var reader = BitReader(bytes: writer.take())

		#expect(reader.read(8) == 0xFF)
		#expect(reader.read(8) == 0x0A)
		#expect(reader.read(1) == 0)  // not small
		#expect(reader.read(2) == 0)  // height selector: 9 bits
		#expect(reader.read(9) == 63)  // height - 1
		#expect(reader.read(3) == 0)  // no aspect ratio shortcut
		#expect(reader.read(2) == 0)  // width selector
		#expect(reader.read(9) == 63)  // width - 1
		#expect(reader.read(1) == 0)  // not all default metadata
		#expect(reader.read(1) == 0)  // no extra fields
		#expect(reader.read(1) == 1)  // floating point samples
		#expect(reader.read(2) == 0)  // 32 bits per sample
		#expect(reader.read(4) == 7)  // 8 exponent bits
		#expect(reader.read(1) == 0)  // modular 16 bit sufficient
		#expect(reader.read(2) == 0)  // no extra channels
		#expect(reader.read(1) == (xyb ? 1 : 0))
	}
}
