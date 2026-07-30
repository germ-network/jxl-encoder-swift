#if canImport(ImageIO)

	import CoreGraphics
	import Foundation
	import ImageIO
	import Testing
	import UniformTypeIdentifiers

	@testable import JXLEncoderApple

	/// The shim is the seam between ImageIO and the portable core, so these tests
	/// close the loop: encode through it, then decode with ImageIO and check the
	/// result is what went in.
	@Suite("JXLEncoderApple")
	struct JXLEncoderAppleTests {
		static func makeImage(
			width: Int, height: Int, alpha: Bool = false,
			draw: (CGContext, Int, Int) -> Void
		) -> CGImage {
			let info =
				alpha
				? CGImageAlphaInfo.premultipliedLast.rawValue
				: CGImageAlphaInfo.noneSkipLast.rawValue
			let context = CGContext(
				data: nil, width: width, height: height, bitsPerComponent: 8,
				bytesPerRow: width * 4,
				space: CGColorSpace(name: CGColorSpace.sRGB)!,
				bitmapInfo: info)!
			draw(context, width, height)
			return context.makeImage()!
		}

		static func gradient(width: Int = 64, height: Int = 64) -> CGImage {
			makeImage(width: width, height: height) { context, w, h in
				let space = CGColorSpace(name: CGColorSpace.sRGB)!
				let gradient = CGGradient(
					colorsSpace: space,
					colors: [
						CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1),
						CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1),
					] as CFArray, locations: [0, 1])!
				context.drawLinearGradient(
					gradient, start: .zero, end: CGPoint(x: w, y: h),
					options: [])
			}
		}

		/// Decodes with ImageIO and returns interleaved 8-bit sRGB.
		static func decodeSamples(_ data: Data) -> (width: Int, height: Int, rgb: [UInt8])?
		{
			guard
				let source = CGImageSourceCreateWithData(data as CFData, nil),
				let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
			else { return nil }
			let w = image.width
			let h = image.height
			let context = CGContext(
				data: nil, width: w, height: h, bitsPerComponent: 8,
				bytesPerRow: w * 4,
				space: CGColorSpace(name: CGColorSpace.sRGB)!,
				bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
			context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
			let raw = context.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
			var rgb = [UInt8](repeating: 0, count: w * h * 3)
			for i in 0..<(w * h) {
				rgb[i * 3] = raw[i * 4]
				rgb[i * 3 + 1] = raw[i * 4 + 1]
				rgb[i * 3 + 2] = raw[i * 4 + 2]
			}
			return (w, h, rgb)
		}

		@Test("encodes a CGImage to a decodable codestream")
		func encodesCGImage() throws {
			let data = try JXLEncoderApple.encode(image: Self.gradient(), distance: 1.0)
			#expect(data.count > 100)
			#expect(Array(data.prefix(2)) == [0xFF, 0x0A])

			let decoded = try #require(Self.decodeSamples(data))
			#expect(decoded.width == 64)
			#expect(decoded.height == 64)
		}

		@Test("round-trips a gradient within lossy tolerance")
		func roundTripFidelity() throws {
			let image = Self.gradient(width: 128, height: 128)
			let original = try JXLEncoderApple.sRGBSamples(
				from: image,
				alphaPolicy: .flatten(background: JXLEncoderApple.defaultBackground)
			)
			let data = try JXLEncoderApple.encode(image: image, distance: 0.5)
			let decoded = try #require(Self.decodeSamples(data))

			var worst = 0
			var total = 0
			for i in 0..<original.count {
				let delta = abs(Int(original[i]) - Int(decoded.rgb[i]))
				worst = max(worst, delta)
				total += delta
			}
			let mean = Double(total) / Double(original.count)
			#expect(mean < 3.0, "mean absolute error \(mean)")
			#expect(worst < 40, "worst sample error \(worst)")
		}

		@Test("maxPixelSize caps the longest edge")
		func thumbnailing() throws {
			let image = Self.gradient(width: 400, height: 200)
			let png = NSMutableData()
			let destination = CGImageDestinationCreateWithData(
				png, UTType.png.identifier as CFString, 1, nil)!
			CGImageDestinationAddImage(destination, image, nil)
			#expect(CGImageDestinationFinalize(destination))

			let data = try JXLEncoderApple.encode(
				data: png as Data, distance: 1.0, maxPixelSize: 100)
			let decoded = try #require(Self.decodeSamples(data))
			#expect(max(decoded.width, decoded.height) == 100)
			#expect(decoded.width == 100)
			#expect(decoded.height == 50)
		}

		/// Transparent regions must take the requested background, not the zeroed
		/// buffer, which would show through as black.
		@Test("flattens alpha onto the requested background")
		func flattensAlpha() throws {
			let image = Self.makeImage(width: 32, height: 32, alpha: true) {
				context, w, h in
				context.clear(CGRect(x: 0, y: 0, width: w, height: h))
				context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
				context.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
			}
			let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
			let samples = try JXLEncoderApple.sRGBSamples(
				from: image, alphaPolicy: .flatten(background: red))

			// left half opaque blue, right half transparent so the background shows
			let left = (16 * 32 + 8) * 3
			let right = (16 * 32 + 24) * 3
			#expect(samples[left + 2] > 200, "left half should stay blue")
			#expect(samples[right] > 200, "right half should take the red background")
			#expect(samples[right + 2] < 60)
		}

		@Test("preserving alpha reports that the core cannot yet carry it")
		func preserveRejected() {
			#expect(throws: JXLEncoderAppleError.alphaNotSupported) {
				try JXLEncoderApple.encode(
					image: Self.gradient(), alphaPolicy: .preserve)
			}
		}

		@Test("rejects input ImageIO cannot decode")
		func rejectsGarbage() {
			#expect(throws: JXLEncoderAppleError.decodeFailed) {
				try JXLEncoderApple.encode(data: Data([0, 1, 2, 3, 4, 5, 6, 7]))
			}
		}
	}

#endif  // canImport(ImageIO)
