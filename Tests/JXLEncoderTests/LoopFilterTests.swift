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
			_ = reader.read(2 + 1 + 2 + 8)
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

	@Test("production pixel headers keep Gaborish off across EPF transitions", .disabled())
	func pixelHeadersKeepGaborishOffAtThresholds() throws {
		Issue.record(
			"Read actual Encoder.encode header fields at all nine threshold neighbors")
	}

	@Test("JPEG headers disable both filters", .disabled())
	func jpegHeadersDisableBothFilters() throws {
		Issue.record(
			"Read actual Encoder.encodeJPEG filter fields for supported JPEG fixtures")
	}

	@Test("concurrent pixel assembly preserves serial filter fields", .disabled())
	func concurrentPixelHeadersMatchSerialFilters() async throws {
		Issue.record(
			"Read actual concurrent and serial headers at the same threshold neighbors")
	}
}
