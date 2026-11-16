import Testing

@testable import JXLEncoder

@Suite("Loop filter headers")
struct LoopFilterTests {
	struct BitReader {
		let bytes: [UInt8]
		var position = 0

		mutating func read(_ count: Int) -> UInt64 {
			var value: UInt64 = 0
			for bitIndex in 0..<count {
				value |=
					UInt64((bytes[position >> 3] >> (position & 7)) & 1)
					<< UInt64(bitIndex)
				position += 1
			}
			return value
		}

		mutating func readSize() -> Int {
			let selector = Int(read(2))
			return Int(read([9, 13, 18, 30][selector])) + 1
		}

		mutating func alignToByte() {
			position = (position + 7) & ~7
		}
	}

	enum FixtureError: Error { case missingFilterObservation(Float) }

	static let thresholds: [Float] = [0.7, 1.5, 4].flatMap { boundary in
		[boundary.nextDown, boundary, boundary.nextUp]
	}

	static func loopFilter(in codestream: [UInt8]) -> (gaborish: Bool, epf: UInt32) {
		var reader = BitReader(bytes: codestream)
		#expect(reader.read(16) == 0x0AFF)
		#expect(reader.read(1) == 0)
		_ = reader.readSize()
		_ = reader.read(3)
		_ = reader.readSize()
		_ = reader.read(1 + 1)
		if reader.read(1) == 1 {
			_ = reader.read(2 + 4 + 1)
		} else {
			_ = reader.read(2 + 1)
		}
		_ = reader.read(2)
		let xybEncoded = reader.read(1) == 1
		_ = reader.read(20)
		reader.alignToByte()

		_ = reader.read(1 + 2 + 1)
		let flagsSelector = Int(reader.read(2))
		switch flagsSelector {
		case 1: _ = reader.read(4)
		case 2: _ = reader.read(8)
		case 3:
			_ = reader.read(12)
			while reader.read(1) == 1 { _ = reader.read(8) }
		default: break
		}
		if !xybEncoded { _ = reader.read(1 + 6) }
		_ = reader.read(2)
		if xybEncoded { _ = reader.read(6) }
		_ = reader.read(8)
		if reader.read(1) == 1 {
			_ = reader.read(2)
			return (true, 2)
		}
		let gaborish = reader.read(1) == 1
		if gaborish { _ = reader.read(1) }
		let epf = UInt32(reader.read(2))
		if epf > 0 { _ = reader.read(3) }
		_ = reader.read(2 + 2)
		return (gaborish, epf)
	}

	static func referenceFilters(for distances: [Float]) throws -> [(Bool, UInt32)] {
		let reference = try SemanticDump(fixture: "distance_filters")
		guard
			case .integers(let inputBits)? = reference.fields["distance_filters.inputs"],
			case .integers(let gaborish)? = reference.fields[
				"distance_filters.gaborish_effort4"],
			case .integers(let epf)? = reference.fields[
				"distance_filters.epf_iterations_effort4"]
		else { throw SemanticDumpError.badHeader("missing distance filter fields") }
		return try distances.map { distance in
			guard let index = inputBits.firstIndex(of: Int64(distance.bitPattern))
			else {
				throw FixtureError.missingFilterObservation(distance)
			}
			return (gaborish[index] == 1, UInt32(epf[index]))
		}
	}

	static func image() throws -> ImageBuffer {
		let size: Int = 16
		let pixelCount: Int = size * size
		let sampleCount: Int = pixelCount * 3
		var samples: [UInt8] = []
		samples.reserveCapacity(sampleCount)
		for index in 0..<sampleCount {
			let scaledIndex: Int = index * 37
			let channelOffset: Int = index / 3
			let sampleValue: Int = (scaledIndex + channelOffset) & 255
			samples.append(UInt8(sampleValue))
		}
		return try ImageBuffer(width: size, height: size, samples: samples)
	}

	@Test(
		"independent filter fields preserve every default-weight wire state",
		arguments: [false, true], [UInt32(0), 1, 2, 3])
	func loopFilterFieldsRoundTrip(gaborish: Bool, epfIterations: UInt32) {
		for mode in [
			FrameAssembly.ColorMode.xyb(xQuantMatrixScale: 3),
			.ycbcr(subsampling: .none),
		] {
			var writer = BitWriter()
			FrameAssembly.writeFrameHeader(
				colorMode: mode,
				loopFilter: .init(gaborish: gaborish, epfIterations: epfIterations),
				writer: &writer)
			let headerBitCount = writer.bitsWritten
			writer.write(8, 0xA5)
			writer.write(56, 0)
			writer.zeroPadToByte()
			var reader = BitReader(bytes: writer.take())

			#expect(reader.read(1) == 0)
			_ = reader.read(2 + 1)
			let flagsSelector = Int(reader.read(2))
			switch flagsSelector {
			case 1: _ = reader.read(4)
			case 2: _ = reader.read(8)
			case 3:
				_ = reader.read(12)
				while reader.read(1) == 1 { _ = reader.read(8) }
			default: break
			}
			if case .ycbcr = mode {
				_ = reader.read(1 + 6 + 2)
			} else {
				_ = reader.read(2 + 6)
			}
			_ = reader.read(2 + 1 + 2 + 1 + 2)

			let usesDefaults = gaborish && epfIterations == 2
			#expect(reader.read(1) == (usesDefaults ? 1 : 0))
			if !usesDefaults {
				let encodedGaborish = reader.read(1) == 1
				if encodedGaborish {
					#expect(reader.read(1) == 0)
				}
				#expect(encodedGaborish == gaborish)
				#expect(reader.read(2) == UInt64(epfIterations))
				if epfIterations > 0 {
					#expect(reader.read(1) == 0)
					#expect(reader.read(1) == 0)
					#expect(reader.read(1) == 0)
				}
				#expect(reader.read(2) == 0)
			}
			#expect(reader.read(2) == 0)
			#expect(reader.position == headerBitCount)
			#expect(reader.read(8) == 0xA5)
		}
	}

	@Test("production pixel headers keep Gaborish off across EPF transitions")
	func pixelHeadersKeepGaborishOffAtThresholds() throws {
		let image = try Self.image()
		let expected = try Self.referenceFilters(for: Self.thresholds)
		for optimizeCodes in [true, false] {
			for (distance, reference) in zip(Self.thresholds, expected) {
				let encoded = try Encoder.encode(
					image, distance: distance, optimizeCodes: optimizeCodes)
				let actual = Self.loopFilter(in: encoded)
				#expect(actual.gaborish == reference.0)
				#expect(actual.epf == reference.1)
				#expect(!actual.gaborish)
			}
		}
	}

	@Test("JPEG headers disable both filters")
	func jpegHeadersDisableBothFilters() throws {
		for (fixture, semantic) in [
			("small_444", "jpeg_small_444"),
			("small_422", "jpeg_small_422"),
			("hopper_420_odd", "jpeg_hopper_420_odd"),
		] {
			let jpeg = try JPEGParserTests.fixture(fixture)
			let transcode = try JPEGTranscode(JPEGParser.parse(jpeg))
			let actual = Self.loopFilter(in: try Encoder.encodeJPEG(transcode))
			let expected = try SemanticDump(fixture: semantic)
			#expect(expected.fields["gaborish.enabled"] == .integers([0]))
			#expect(expected.fields["epf.iterations"] == .integers([0]))
			#expect(!actual.gaborish)
			#expect(actual.epf == 0)
		}
	}

	@Test("concurrent pixel assembly preserves serial filter fields")
	func concurrentPixelHeadersMatchSerialFilters() async throws {
		let image = try Self.image()
		let expected = try Self.referenceFilters(for: Self.thresholds)
		for (distance, reference) in zip(Self.thresholds, expected) {
			let serial = Self.loopFilter(
				in: try Encoder.encode(image, distance: distance))
			let concurrent = Self.loopFilter(
				in: try await Encoder.encodeConcurrently(image, distance: distance))
			#expect(concurrent.gaborish == reference.0)
			#expect(concurrent.epf == reference.1)
			#expect(concurrent.gaborish == serial.gaborish)
			#expect(concurrent.epf == serial.epf)
		}
	}
}
