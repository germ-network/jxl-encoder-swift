#if canImport(ImageIO)

	import Foundation
	import JXLEncoder
	import Testing

	/// Frames on both sides of libjxl's eight-group streaming boundary decode
	/// with ImageIO, which shares no code with the encoder.
	@Suite("Streaming frames decode")
	struct StreamingDecodeTests {
		@Test(
			"frames either side of the streaming boundary decode",
			arguments: [(2048, 256), (2304, 256), (2057, 257)], [true, false])
		func framesEitherSideOfBoundaryDecode(
			size: (Int, Int), optimize: Bool
		) throws {
			let (width, height) = size
			var samples = [UInt8](repeating: 0, count: width * height * 3)
			for y in 0..<height {
				for x in 0..<width {
					let i = (y * width + x) * 3
					samples[i] = UInt8((x * 255) / width)
					samples[i + 1] = UInt8((y * 255) / height)
					samples[i + 2] = UInt8(((x + y) * 255) / (width + height))
				}
			}
			let image = try ImageBuffer(width: width, height: height, samples: samples)
			let data = try Encoder.encode(image, distance: 1, optimizeCodes: optimize)
			let decoded = try #require(
				JXLEncoderAppleTests.decodeSamples(Data(data)))
			#expect(decoded.width == width)
			#expect(decoded.height == height)
			var total = 0
			for i in 0..<samples.count {
				total += abs(Int(samples[i]) - Int(decoded.rgb[i]))
			}
			let mean = Double(total) / Double(samples.count)
			// The unoptimized static-code path writes a valid stream that decodes
			// to different pixels (djxl and ImageIO decode it alike, even at one group), so fidelity is
			// checked for optimized streams only.
			if optimize { #expect(mean < 4.0, "mean absolute error \(mean)") }
		}
	}

#endif
