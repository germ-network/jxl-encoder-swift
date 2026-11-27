import Testing

@testable import JXLEncoder

/// EXIF orientation read without a decoder, the portable recompression entry
/// point, and JPEG XL signature detection.
@Suite("Portable JPEG recompression")
struct PortableJPEGRecompressionTests {

	@Test(
		"Ordered RGB IDs and Adobe transform zero each select coefficient recompression",
	)
	func recognizedRGBRoutesRecompress() throws {
		let base = JPEGParserTests.withoutMarker(
			0xE0, in: try JPEGParserTests.fixture("small_444"))
		let adobe = JPEGParserTests.withMarker(
			0xEE, payload: JPEGParserTests.adobe(0), in: base)
		let ids = JPEGParserTests.withRGBIDs(base)
		for jpeg in [adobe, ids] {
			#expect(try JPEGParser.parse(jpeg).sourceIsRGB)
			let stream = try #require(Encoder.recompressJPEG(jpeg))
			#expect(JXLSignature.matches(stream))
		}
	}

	@Test(
		"RGB coefficient recompression requires 1×1 sampling for every component")
	func rgbRejectsSubsampling() throws {
		let subsampled = JPEGParserTests.withRGBIDs(
			JPEGParserTests.withoutMarker(
				0xE0, in: try JPEGParserTests.fixture("small_422")))
		let image = try JPEGParser.parse(subsampled)
		#expect(image.sourceIsRGB)
		#expect(throws: JPEGTranscode.TranscodeError.unsupportedSubsampling) {
			try JPEGTranscode(image)
		}
		#expect(Encoder.recompressJPEG(subsampled) == nil)

		let parsed = try JPEGParser.parse(try JPEGParserTests.fixture("small_444"))
		let repeated = JPEGImage(
			width: parsed.width,
			height: parsed.height,
			components: parsed.components.map {
				JPEGComponent(
					identifier: $0.identifier, horizontalSampling: 2,
					verticalSampling: 2, quantTableIndex: $0.quantTableIndex,
					blocksPerLine: $0.blocksPerLine,
					blocksPerColumn: $0.blocksPerColumn,
					coefficients: $0.coefficients)
			},
			quantTables: parsed.quantTables,
			restartInterval: parsed.restartInterval)
		var rgb = repeated
		rgb.sourceIsRGB = true
		#expect(throws: JPEGTranscode.TranscodeError.unsupportedSubsampling) {
			try JPEGTranscode(rgb)
		}
	}

	@Test(
		"DC boundary JPEGs recompress through the public API",
		arguments: [-1025, -1024, -1023, 1023, 1024]
	)
	func dcBoundaryRecompresses(dc: Int) throws {
		let data = Self.singleBlockJPEG(dc: dc)
		let image = try JPEGParser.parse(data)
		#expect(image.components[0].coefficients[0] == Int32(dc))
		#expect(image.components[0].coefficients.dropFirst().allSatisfy { $0 == 0 })
		let recompressed = try #require(Encoder.recompressJPEG(data))
		#expect(JXLSignature.matches(recompressed))
	}

	static func singleBlockJPEG(dc: Int) -> [UInt8] {
		func segment(_ marker: UInt8, _ payload: [UInt8]) -> [UInt8] {
			let length = payload.count + 2
			return [0xFF, marker, UInt8(length >> 8), UInt8(length & 0xFF)] + payload
		}

		func amplitude(_ value: Int, category: Int) -> [UInt8] {
			guard category > 0 else { return [] }
			let encoded = value >= 0 ? value : value + (1 << category) - 1
			return (0..<category).reversed().map { UInt8(encoded >> $0 & 1) }
		}

		let category = dc == 0 ? 0 : Int.bitWidth - abs(dc).leadingZeroBitCount
		var bits: [UInt8] = [0]
		bits += amplitude(dc, category: category)
		bits.append(0)  // AC EOB
		while !bits.count.isMultiple(of: 8) { bits.append(1) }
		var entropy: [UInt8] = []
		for start in stride(from: 0, to: bits.count, by: 8) {
			let byte = bits[start..<start + 8].reduce(UInt8(0)) { ($0 << 1) | $1 }
			entropy.append(byte)
			if byte == 0xFF { entropy.append(0) }
		}

		let quant = segment(0xDB, [0] + [UInt8](repeating: 1, count: 64))
		let frame = segment(0xC0, [8, 0, 8, 0, 8, 1, 1, 0x11, 0])
		let dcTable: [UInt8] =
			[0, 1] + [UInt8](repeating: 0, count: 15) + [UInt8(category)]
		let acTable: [UInt8] = [0x10, 1] + [UInt8](repeating: 0, count: 15) + [0]
		let huffman = segment(0xC4, dcTable + acTable)
		let scan = segment(0xDA, [1, 1, 0, 0, 63, 0])
		var jpeg: [UInt8] = [0xFF, 0xD8]
		jpeg.append(contentsOf: quant)
		jpeg.append(contentsOf: frame)
		jpeg.append(contentsOf: huffman)
		jpeg.append(contentsOf: scan)
		jpeg.append(contentsOf: entropy)
		jpeg.append(contentsOf: [0xFF, 0xD9])
		return jpeg
	}

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

	/// Orientation is the caller's to gate: the coefficients cross over as they
	/// are, and the output declares none.
	@Test("orientation does not change the recompressed output", arguments: 2...8)
	func orientationIgnored(orientation: Int) throws {
		let rotated = try #require(
			Encoder.recompressJPEG(try Self.jpeg(orientation: orientation)))
		#expect(rotated == Encoder.recompressJPEG(try Self.jpeg(orientation: nil)))
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

extension PortableJPEGRecompressionTests {
	static func iccChunks(_ profile: [UInt8], chunkSize: Int = 65_519) -> [(UInt8, [UInt8])] {
		let starts = Array(stride(from: 0, to: profile.count, by: chunkSize))
		return starts.enumerated().map { index, start in
			(
				0xE2,
				Array("ICC_PROFILE\0".utf8) + [
					UInt8(index + 1), UInt8(starts.count),
				]
					+ profile[start..<min(start + chunkSize, profile.count)]
			)
		}
	}

	static func withoutICC(_ data: [UInt8]) -> [UInt8] {
		var data = data
		while JPEGParserTests.segmentOffset(data, marker: 0xE2) != nil {
			data = JPEGParserTests.withoutMarker(0xE2, in: data)
		}
		return data
	}

	/// Reads a codestream's image header up to the coded ICC's transformed
	/// size: (want_icc, color space, size), or nil size when want_icc is 0.
	static func colorSignal(_ stream: [UInt8]) -> (wantICC: Int, colorSpace: Int, size: UInt64?)
	{
		var bits = ImageHeaderTests.HeaderBits(bytes: stream)
		_ = bits.read(16)
		if bits.read(1) == 1 {
			_ = bits.read(5)
			if bits.read(3) == 0 { _ = bits.read(5) }
		} else {
			_ = bits.size()
			if bits.read(3) == 0 { _ = bits.size() }
		}
		_ = bits.read(1 + 1 + 1 + 2 + 1 + 2 + 1 + 1)
		let wantICC = bits.read(1)
		let colorSpace = bits.read(2)
		guard wantICC == 1 else { return (wantICC, colorSpace, nil) }
		_ = bits.u64()
		_ = bits.read(1)
		return (wantICC, colorSpace, bits.u64())
	}

	static func headerBytes(_ transcode: JPEGTranscode) throws -> [UInt8] {
		var writer = BitWriter()
		try ImageHeader.write(
			width: transcode.width, height: transcode.height, transferFunction: .sRGB,
			xybEncoded: false, isGrayscale: transcode.isGrayscale,
			iccProfile: transcode.iccProfile, to: &writer)
		return writer.take()
	}

	/// The profile is signalled and coded in the header, and the frame after it
	/// is byte-identical to the ICC-stripped source's.
	static func expectProfiled(
		_ fixture: String, sourceLocation: SourceLocation = #_sourceLocation
	) throws {
		let jpeg = try JPEGParserTests.fixture(fixture)
		let image = try JPEGParser.parse(jpeg)
		let bytes = try #require(image.iccProfile, sourceLocation: sourceLocation)
		let transcode = try JPEGTranscode(image)
		#expect(transcode.iccProfile?.bytes == bytes, sourceLocation: sourceLocation)
		let stripped = try JPEGTranscode(JPEGParser.parse(Self.withoutICC(jpeg)))
		#expect(stripped.iccProfile == nil, sourceLocation: sourceLocation)
		#expect(
			Encoder.recompressJPEG(jpeg) == (try Encoder.encodeJPEG(transcode)),
			sourceLocation: sourceLocation)
		let header = try Self.headerBytes(transcode)
		let strippedHeader = try Self.headerBytes(stripped)
		let stream = try Encoder.encodeJPEG(transcode)
		let plain = try Encoder.encodeJPEG(stripped)
		#expect(JXLSignature.matches(stream), sourceLocation: sourceLocation)
		let signal = Self.colorSignal(stream)
		#expect(signal.wantICC == 1, sourceLocation: sourceLocation)
		#expect(signal.colorSpace == 0, sourceLocation: sourceLocation)
		#expect(
			signal.size == UInt64(ICCCodec.predict(bytes).count),
			sourceLocation: sourceLocation)
		#expect(
			Self.colorSignal(plain).wantICC == 0, sourceLocation: sourceLocation
		)
		#expect(stream.starts(with: header), sourceLocation: sourceLocation)
		#expect(plain.starts(with: strippedHeader), sourceLocation: sourceLocation)
		#expect(
			stream.dropFirst(header.count)
				== plain.dropFirst(strippedHeader.count),
			sourceLocation: sourceLocation)
	}

	@Test("a YCbCr JPEG with an in-family profile recompresses")
	func profiledYCbCrRecompresses() throws {
		try Self.expectProfiled("display_p3_profile")
	}

	@Test("an RGB JPEG with an in-family profile recompresses")
	func profiledRGBRecompresses() throws {
		#expect(try JPEGParser.parse(JPEGParserTests.fixture("rgb_p3_profile")).sourceIsRGB)
		try Self.expectProfiled("rgb_p3_profile")
	}

	@Test("a profile split over two APP2 chunks recompresses")
	func multiChunkProfileRecompresses() throws {
		let jpeg = try JPEGParserTests.fixture("p3_random40000_profile_420")
		#expect(try #require(JPEGParser.parse(jpeg).iccProfile).count > 65_519)
		try Self.expectProfiled("p3_random40000_profile_420")
	}

	@Test("a profile past the kLZ77 switch recompresses")
	func greedyLZ77ProfileRecompresses() throws {
		try Self.expectProfiled("p3_desc1000_profile_420")
	}

	@Test("a profile libjxl's ICC reader would reject declines to nil")
	func overcompressedProfileDeclines() throws {
		for fixture in [
			"p3_desc3300_profile_420", "p3_ratio_below_420", "p3_ratio_late_420",
		] {
			let jpeg = try JPEGParserTests.fixture(fixture)
			let image = try JPEGParser.parse(jpeg)
			#expect(try #require(image.iccProfile).count > 65_519, "\(fixture)")
			let transcode = try JPEGTranscode(image)
			#expect(throws: EncoderError.unsupportedICCProfile) {
				try Encoder.encodeJPEG(transcode)
			}
			#expect(Encoder.recompressJPEG(jpeg) == nil, "\(fixture)")
		}
	}

	@Test("a profile just inside the reader's compression limit recompresses")
	func profileJustInsideReaderLimitRecompresses() throws {
		try Self.expectProfiled("p3_ratio_above_420")
	}

	@Test("a small profile whose coded ICC enables optimal LZ77 recompresses")
	func lz77ProfileRecompresses() throws {
		try Self.expectProfiled("p3_desc4_profile")
	}

	@Test("a nonempty profile outside the family falls back to nil")
	func invalidProfileFallsBack() throws {
		for name in ["small_444", "rgb_color"] {
			let jpeg = JPEGParserTests.withMarkers(
				Self.iccChunks([0xAB]), in: try JPEGParserTests.fixture(name))
			let image = try JPEGParser.parse(jpeg)
			#expect(image.iccProfile == [0xAB])
			#expect(throws: JPEGTranscode.TranscodeError.unsupportedColorInterpretation)
			{
				try JPEGTranscode(image)
			}
			#expect(Encoder.recompressJPEG(jpeg) == nil)
		}
	}

	@Test("a malformed chunk set recompresses as unprofiled")
	func malformedAssemblyRecompressesUnprofiled() throws {
		let profile = try ICCCodecTests.displayP3()
		let halves = Self.iccChunks(profile, chunkSize: (profile.count + 1) / 2)
		for name in ["small_444", "rgb_color", "hopper_gray_odd"] {
			let source = try JPEGParserTests.fixture(name)
			let unprofiled = try #require(Encoder.recompressJPEG(source))
			for chunks in [
				[halves[1], halves[0]], [halves[0]], [halves[0], halves[0]],
			] {
				let jpeg = JPEGParserTests.withMarkers(chunks, in: source)
				#expect(try JPEGParser.parse(jpeg).iccProfile == nil)
				#expect(Encoder.recompressJPEG(jpeg) == unprofiled)
			}
		}
	}

	@Test("an empty assembled profile recompresses as unprofiled")
	func emptyProfileRecompressesUnprofiled() throws {
		for name in ["small_444", "rgb_color", "hopper_gray_odd"] {
			let source = try JPEGParserTests.fixture(name)
			let unprofiled = try #require(Encoder.recompressJPEG(source))
			let jpeg = JPEGParserTests.withMarkers(Self.iccChunks([]), in: source)
			#expect(try JPEGParser.parse(jpeg).iccProfile == nil)
			#expect(Encoder.recompressJPEG(jpeg) == unprofiled)
			#expect(Self.colorSignal(unprofiled).wantICC == 0)
		}
	}

	@Test("a grayscale JPEG with a profile falls back to nil")
	func grayscaleProfileFallsBack() throws {
		let jpeg = JPEGParserTests.withMarkers(
			Self.iccChunks(try ICCCodecTests.displayP3()),
			in: try JPEGParserTests.fixture("hopper_gray_odd"))
		#expect(throws: JPEGTranscode.TranscodeError.unsupportedColorInterpretation) {
			try JPEGTranscode(JPEGParser.parse(jpeg))
		}
		#expect(Encoder.recompressJPEG(jpeg) == nil)
	}

	@Test("v2, sampled-curve, LUT, cicp and gray profiles fall back to nil")
	func unsupportedFamiliesFallBack() throws {
		typealias Builder = ICCProfileTests.Builder
		var v2 = Builder()
		v2.setHeader(8, [2, 0x10, 0, 0])
		var sampled = Builder()
		sampled.setTRCs(
			Builder.ascii("curv") + [0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0xFF, 0xFF])
		var lut = Builder()
		lut.setTag("A2B0", Builder.ascii("mAB ") + [UInt8](repeating: 0, count: 28))
		var cicp = Builder()
		cicp.setTag("cicp", Builder.ascii("cicp") + [0, 0, 0, 0, 1, 13, 0, 1])
		var gray = Builder()
		gray.setHeader(16, Builder.ascii("GRAY"))
		for name in ["small_444", "rgb_color"] {
			let source = try JPEGParserTests.fixture(name)
			let admitted = JPEGParserTests.withMarkers(
				Self.iccChunks(Builder().bytes), in: source)
			#expect(Encoder.recompressJPEG(admitted) != nil)
			for profile in [v2, sampled, lut, cicp, gray] {
				let jpeg = JPEGParserTests.withMarkers(
					Self.iccChunks(profile.bytes), in: source)
				#expect(try JPEGParser.parse(jpeg).iccProfile == profile.bytes)
				#expect(Encoder.recompressJPEG(jpeg) == nil)
			}
		}
	}
}
