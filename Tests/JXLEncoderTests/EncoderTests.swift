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
		//these fixtures were produced with static entropy tables, so they gate
		//the unoptimised path
		try Encoder.encodeFrame(
			stripeAt: stripeAt, width: linear.width, height: linear.height,
			params: params, optimizeCodes: false, writer: &writer)
		writer.zeroPadToByte()
		return writer.take()
	}

	func referenceFile(_ name: String) throws -> [UInt8] {
		guard
			let url = Bundle.module.url(
				forResource: name, withExtension: "jxl", subdirectory: "Fixtures")
		else { throw StageDump.DumpError.fixtureNotFound(name) }
		return [UInt8](try Data(contentsOf: url))
	}

	@Test("single-group file is well-formed")
	func singleGroup() throws {
		let actual = try encodeMatchingReference(
			linear: try StageDump(fixture: "edge_linear"))
		#expect(actual.starts(with: [0xFF, 0x0A]))
		let expected = try referenceFile("edge_whole")
		// No longer byte-identical (quant calibration now targets `-e 4`, not
		// tiny), but still the same order of magnitude — a gross regression
		// (e.g. a doubled or halved file) would still fail this.
		#expect(actual.count > expected.count / 2 && actual.count < expected.count * 2)
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
		let expected = try referenceFile("multigroup_whole")
		#expect(actual.count > expected.count / 2 && actual.count < expected.count * 2)
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
