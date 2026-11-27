import Foundation
import Testing

@testable import JXLEncoder

/// `singleGroup`/`multiGroup` used to be whole-file byte-exact gates against
/// `cjxl_tiny` output — retired now that quant-field calibration targets
/// `cjxl -e 4` instead of tiny (see docs/gap-closure-plan.md, "Quant
/// calibration"): the two no longer produce the same bytes by design. What
/// remains checkable in this Foundation-free core target is structure, not
/// bytes; decode-correctness against real photos at many distances is
/// covered in the Apple target (`OptimizedCodeTests`, `JPEGRecompressionTests`).
///
/// The fixtures are encoded with a linear transfer function because that is what
/// the reference hardcodes; production uses sRGB, which differs only in one
/// header field.
@Suite("Encoder")
struct EncoderTests {
	func encodeMatchingReference(linear: StageDump) throws -> [UInt8] {
		let params = try DistanceParams(distance: 1.0)
		var writer = BitWriter()
		try ImageHeader.write(
			width: linear.width, height: linear.height,
			transferFunction: .linear, to: &writer)
		//the fixture is already-linear float data, so feed it straight through
		//the float stripe reader, bypassing the production 8-bit linearize step
		let interleaved = linear.interleaved
		let width = linear.width
		let stripeAt: @Sendable (Rect) -> PaddedStripe = { rect in
			PlaneBuffer.copyAndPad(
				source: interleaved, sourceWidth: width, rect: rect)
		}
		let pixelFrame = Encoder.preparePixelFrame(
			stripeAt: stripeAt, width: linear.width, height: linear.height,
			params: params)
		try Encoder.encodeFrame(
			pixelFrame: pixelFrame,
			params: params, writer: &writer)
		writer.zeroPadToByte()
		return writer.take()
	}

	@Test("single-group file is well-formed")
	func singleGroup() throws {
		let actual = try encodeMatchingReference(
			linear: try StageDump(fixture: "edge_linear"))
		#expect(actual.starts(with: [0xFF, 0x0A]))
	}

	/// 301x301 spans four AC groups, so the table of contents carries multiple
	/// entries instead of taking the single-section merge path.
	@Test("multi-group file is well-formed")
	func multiGroup() throws {
		let input = try StageDump(fixture: "multigroup_linear")
		let dim = ImageDim(width: input.width, height: input.height)
		#expect(dim.groupCount == 4)

		let actual = try encodeMatchingReference(linear: input)
		#expect(actual.starts(with: [0xFF, 0x0A]))
	}

	@Test("public API produces a bare codestream from 8-bit sRGB")
	func publicAPI() throws {
		let size = 64
		var samples = [UInt8](repeating: 0, count: size * size * 3)
		for y in 0..<size {
			for x in 0..<size {
				let i = (y * size + x) * 3
				samples[i] = UInt8(x * 4 % 256)
				samples[i + 1] = UInt8(y * 4 % 256)
				samples[i + 2] = UInt8((x + y) * 2 % 256)
			}
		}
		let image = try ImageBuffer(width: size, height: size, samples: samples)
		let bytes = try Encoder.encode(image, distance: 1.0)

		#expect(bytes.starts(with: [0xFF, 0x0A]))
		#expect(bytes.count > 100)
	}

	@Test(
		"pixel entry points propagate invalidDistance for non-finite inputs",
		arguments: [Float.nan, .infinity, -.infinity])
	func rejectsNonFiniteDistances(distance: Float) async throws {
		let image = try ImageBuffer(width: 1, height: 1, samples: [0, 0, 0])
		#expect {
			try Encoder.encode(image, distance: distance)
		} throws: { error in
			guard case EncoderError.invalidDistance(let rejected) = error else {
				return false
			}
			return rejected.isNaN ? distance.isNaN : rejected == distance
		}
		await #expect {
			try await Encoder.encodeConcurrently(image, distance: distance)
		} throws: { error in
			guard case EncoderError.invalidDistance(let rejected) = error else {
				return false
			}
			return rejected.isNaN ? distance.isNaN : rejected == distance
		}
	}

	@Test("lower distance yields a larger file")
	func distanceMonotonic() throws {
		let size = 64
		var samples = [UInt8](repeating: 0, count: size * size * 3)
		for i in 0..<(size * size) {
			samples[i * 3] = UInt8((i * 7) % 256)
			samples[i * 3 + 1] = UInt8((i * 13) % 256)
			samples[i * 3 + 2] = UInt8((i * 29) % 256)
		}
		let image = try ImageBuffer(width: size, height: size, samples: samples)
		let fine = try Encoder.encode(image, distance: 0.5)
		let coarse = try Encoder.encode(image, distance: 3.0)
		#expect(fine.count > coarse.count)
	}

	@Test("rejects malformed input")
	func rejectsBadInput() {
		#expect(throws: EncoderError.emptyImage) {
			try ImageBuffer(width: 0, height: 5, samples: [])
		}
		#expect(throws: EncoderError.self) {
			try ImageBuffer(width: 2, height: 2, samples: [1, 2, 3])
		}
	}

	/// Channel counts other than 3 and 4 would misalign every pixel read, so
	/// `ImageBuffer.init` rejects them up front rather than letting a bad stride
	/// reach the sample reads.
	@Test("rejects unsupported channel counts", arguments: [0, 1, 2, 5])
	func rejectsChannels(channels: Int) {
		let samples = [UInt8](repeating: 128, count: 16 * 16 * max(channels, 1))
		#expect(throws: EncoderError.unsupportedChannelCount(channels)) {
			try ImageBuffer(
				width: 16, height: 16, samples: samples, channels: channels)
		}
	}

	/// A throwing initializer must throw on absurd dimensions, not trap on the
	/// sample-count multiplication.
	@Test("overflowing dimensions throw rather than trap")
	func overflowThrows() {
		#expect(throws: EncoderError.imageTooLarge(width: Int.max / 2, height: 4)) {
			try ImageBuffer(width: Int.max / 2, height: 4, samples: [])
		}
	}

	/// The fourth channel is stride only, so RGBA input encodes exactly as the
	/// same pixels without it — alpha never leaks into the output.
	@Test("alpha channel is ignored, not encoded")
	func alphaIgnored() throws {
		let size = 32
		var rgb = [UInt8](repeating: 0, count: size * size * 3)
		var rgba = [UInt8](repeating: 0, count: size * size * 4)
		for i in 0..<(size * size) {
			let r = UInt8((i * 7) % 256)
			let g = UInt8((i * 13) % 256)
			let b = UInt8((i * 29) % 256)
			rgb[i * 3] = r
			rgb[i * 3 + 1] = g
			rgb[i * 3 + 2] = b
			rgba[i * 4] = r
			rgba[i * 4 + 1] = g
			rgba[i * 4 + 2] = b
			rgba[i * 4 + 3] = UInt8(i % 256)
		}
		let a = try Encoder.encode(
			ImageBuffer(width: size, height: size, samples: rgb), distance: 1.0)
		let b = try Encoder.encode(
			ImageBuffer(width: size, height: size, samples: rgba, channels: 4),
			distance: 1.0)
		#expect(a == b)
	}
}

extension EncoderTests {
	@Test
	func positiveFinitePixelEntryPointsSerialize() async throws {
		let width = 9
		let height = 7
		var rgb = [UInt8](repeating: 0, count: width * height * 3)
		var grayRGB = rgb
		for pixel in 0..<(width * height) {
			let value = UInt8((pixel * 37) % 256)
			grayRGB.replaceSubrange(
				pixel * 3..<(pixel + 1) * 3, with: [value, value, value])
			for channel in 0..<3 {
				rgb[pixel * 3 + channel] = UInt8((pixel * (channel * 11 + 7)) % 256)
			}
		}
		let images = [
			try ImageBuffer(width: width, height: height, samples: rgb),
			try ImageBuffer(width: width, height: height, samples: grayRGB),
		]
		let boundary = Float(bitPattern: 0x4760_70FC)
		for distance in [
			Float(0.03), 26, boundary, Float(1 << 55), .greatestFiniteMagnitude,
		] {
			let params = try DistanceParams(distance: distance)
			#expect(params.globalScale >= 1 && params.globalScale <= 1 << 15)
			#expect(params.quantDC >= 1 && params.quantDC <= 1 << 16)
			#expect(params.uniformQuant > 0 && params.uniformQuant <= 255)
			for image in images {
				let serial = try Encoder.encode(image, distance: distance)
				let concurrent = try await Encoder.encodeConcurrently(
					image, distance: distance)
				#expect(serial.starts(with: [0xFF, 0x0A]))
				#expect(serial.count > 20)
				#expect(concurrent == serial)
			}
		}
	}
}
