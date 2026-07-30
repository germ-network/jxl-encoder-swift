#if canImport(ImageIO)

	import CoreGraphics
	import Foundation
	import ImageIO
	import JXLEncoder
	import Testing

	/// Takes the coefficients all the way back to pixels and compares against
	/// ImageIO decoding the same file. A wrong scan layout, zig-zag order or DC
	/// predictor shows up here as an obviously broken image.
	///
	/// The bounds are loose because ImageIO is the loose end, not the parser:
	/// this reconstruction agrees with libjpeg's own decoder (`djpeg`) to a mean
	/// of 0.04 and a worst case of 3 levels on every fixture, while ImageIO
	/// differs from libjpeg by the same 0.1-1.9 mean and 27-46 worst case seen
	/// below — isolated dark pixels, so its inverse DCT is not libjpeg's. The
	/// exact check on the parser itself is the coefficient diff in the core
	/// suite; this one is here to catch gross breakage end to end.
	///
	/// Fixtures must carry no ICC profile. ImageIO applies one when it draws,
	/// which shifts every sample — an Adobe RGB original measures a mean of 5
	/// against this reconstruction while still matching libjpeg exactly.
	@Suite("JPEG parser vs ImageIO")
	struct JPEGParserCrossCheckTests {
		enum FixtureError: Error { case notFound(String) }

		static func fixture(_ name: String) throws -> Data {
			guard
				let url = Bundle.module.url(
					forResource: name, withExtension: "jpg",
					subdirectory: "Fixtures")
			else { throw FixtureError.notFound(name) }
			return try Data(contentsOf: url)
		}

		static func decodeRGB(_ data: Data) -> (width: Int, height: Int, rgb: [UInt8])? {
			guard
				let source = CGImageSourceCreateWithData(data as CFData, nil),
				let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
			else { return nil }
			let width = image.width
			let height = image.height
			guard
				let context = CGContext(
					data: nil, width: width, height: height,
					bitsPerComponent: 8,
					bytesPerRow: width * 4,
					space: CGColorSpace(name: CGColorSpace.sRGB)!,
					bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
			else { return nil }
			context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
			guard let raw = context.data else { return nil }
			let bytes = raw.bindMemory(to: UInt8.self, capacity: width * height * 4)
			var rgb = [UInt8](repeating: 0, count: width * height * 3)
			for i in 0..<(width * height) {
				rgb[i * 3] = bytes[i * 4]
				rgb[i * 3 + 1] = bytes[i * 4 + 1]
				rgb[i * 3 + 2] = bytes[i * 4 + 2]
			}
			return (width, height, rgb)
		}

		@Test(
			"reconstructs the same picture ImageIO decodes",
			arguments: [
				"hopper_420_restart", "hopper_444", "hopper_422", "hopper_411",
				"hopper_420_odd", "hopper_gray_odd", "hopper_420_sof1",
			])
		func matchesImageIO(name: String) throws {
			let data = try Self.fixture(name)
			let image = try JPEGParser.parse([UInt8](data))
			let reference = try #require(Self.decodeRGB(data))

			try #require(image.width == reference.width)
			try #require(image.height == reference.height)
			let ours = JPEGReconstruction.rgb(from: image)
			try #require(ours.count == reference.rgb.count)

			var total = 0
			var worst = 0
			for i in 0..<ours.count {
				let delta = abs(Int(ours[i]) - Int(reference.rgb[i]))
				total += delta
				worst = max(worst, delta)
			}
			let mean = Double(total) / Double(ours.count)

			#expect(mean < 2.5, "\(name): mean absolute error \(mean)")
			#expect(worst <= 64, "\(name): worst sample error \(worst)")
		}

	}

#endif  // canImport(ImageIO)
