#if canImport(ImageIO)

	import CoreGraphics
	import Foundation
	import ImageIO
	import JXLEncoder
	import Testing

	@testable import JXLEncoderApple

	/// Optimized modular DC and AC codes are decoded by ImageIO, which uses an
	/// independent JPEG XL decoder.
	///
	/// The win is largest on small images, where the ~1 kB of static tables
	/// dominates — which is exactly the thumbnail case the app cares about.
	@Suite("Optimized prefix codes")
	struct OptimizedCodeTests {
		static func image(_ size: Int) -> CGImage {
			let context = CGContext(
				data: nil, width: size, height: size, bitsPerComponent: 8,
				bytesPerRow: size * 4,
				space: CGColorSpace(name: CGColorSpace.sRGB)!,
				bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
			let space = CGColorSpace(name: CGColorSpace.sRGB)!
			let gradient = CGGradient(
				colorsSpace: space,
				colors: [
					CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1),
					CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1),
				] as CFArray, locations: [0, 1])!
			context.drawLinearGradient(
				gradient, start: .zero, end: CGPoint(x: size, y: size), options: [])
			return context.makeImage()!
		}

		static func encode(_ image: CGImage, optimize: Bool) throws -> [UInt8] {
			let samples = try JXLEncoderApple.sRGBSamples(
				from: image,
				alphaPolicy: .flatten(background: JXLEncoderApple.defaultBackground)
			)
			let buffer = try ImageBuffer(
				width: image.width, height: image.height, samples: samples)
			return try Encoder.encode(buffer, distance: 1.0, optimizeCodes: optimize)
		}

		static func decode(_ bytes: [UInt8]) -> [UInt8]? {
			guard
				let source = CGImageSourceCreateWithData(
					Data(bytes) as CFData, nil),
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
			return (0..<(w * h * 4)).map { raw[$0] }
		}

		@Test(
			"optimized modular frame decodes to nonconstant pixels",
			arguments: [64, 200])
		func optimizedFrameDecodes(size: Int) throws {
			let image = Self.image(size)
			let optimized = try Self.encode(image, optimize: true)
			let a = try #require(Self.decode(optimized))
			#expect(a.count == size * size * 4)
			let redSamples = stride(from: 0, to: a.count, by: 4).map { a[$0] }
			#expect(Set(redSamples).count > 16)
		}

		@Test(
			"multi-group pixel output decodes with meaningful reconstruction and clean seams"
		)
		func multiGroupPixelOutputDecodes() throws {
			let size = 600
			var samples = [UInt8](repeating: 0, count: size * size * 3)
			for y in 0..<size {
				for x in 0..<size {
					let i = (y * size + x) * 3
					samples[i] = UInt8(x * 255 / (size - 1))
					samples[i + 1] = UInt8(y * 255 / (size - 1))
					samples[i + 2] = UInt8((x + y) * 255 / (2 * (size - 1)))
				}
			}
			let image = try ImageBuffer(width: size, height: size, samples: samples)
			let decoded = try #require(
				Self.decode(try Encoder.encode(image, distance: 1.0)))
			for channel in 0..<3 {
				let values = stride(from: channel, to: decoded.count, by: 4)
					.map { decoded[$0] }
				#expect(Set(values).count > 128)
			}

			func meanError(xRange: Range<Int>) -> Double {
				var total = 0
				for y in 0..<size {
					for x in xRange {
						let source = (y * size + x) * 3
						let result = (y * size + x) * 4
						for channel in 0..<3 {
							total += abs(
								Int(samples[source + channel])
									- Int(
										decoded[
											result
												+ channel
										]))
						}
					}
				}
				return Double(total) / Double(size * xRange.count * 3)
			}

			let overallError = meanError(xRange: 0..<size)
			#expect(overallError < 12)
			for boundary in [256, 512] {
				let seamError = meanError(xRange: (boundary - 8)..<(boundary + 8))
				#expect(seamError < overallError * 2 + 4)
			}
		}

		@Test("files get smaller, most so when small", arguments: [64, 200])
		func smaller(size: Int) throws {
			let image = Self.image(size)
			let optimized = try Self.encode(image, optimize: true)
			let staticCoded = try Self.encode(image, optimize: false)
			#expect(optimized.count < staticCoded.count)
		}

		/// The static tables impose roughly a 1 kB floor; optimising should take
		/// a small thumbnail well below it.
		@Test("a 64x64 thumbnail drops under the static floor")
		func belowStaticFloor() throws {
			let optimized = try Self.encode(Self.image(64), optimize: true)
			#expect(optimized.count < 1000)
		}

		static let fixtures = [
			"hopper_411", "hopper_420_odd", "hopper_420_restart", "hopper_420_sof1",
			"hopper_422", "hopper_444", "hopper_gray_odd",
		]
		static let distances: [Float] = [0.3, 0.5, 0.7, 1.0, 1.5, 2.0, 3.0]

		/// Every optimized photographic file must decode to meaningful pixels
		/// across the supported distance range.
		///
		/// The tests above only ever encoded a synthetic gradient at d = 1.0, and
		/// that combination happens to dodge degenerate prefix codes entirely.
		/// Photographs hit them constantly: before the fix, 42 of these 49 cases
		/// produced a stream ImageIO refused.
		@Test(
			"optimised photographs match the static path at every distance",
			arguments: fixtures, distances)
		func photographsDecode(fixture: String, distance: Float) throws {
			let url = try #require(
				Bundle.module.url(
					forResource: fixture, withExtension: "jpg",
					subdirectory: "Fixtures"))
			let data = try Data(contentsOf: url)
			let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
			let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))

			let samples = try JXLEncoderApple.sRGBSamples(
				from: image,
				alphaPolicy: .flatten(background: JXLEncoderApple.defaultBackground)
			)
			let buffer = try ImageBuffer(
				width: image.width, height: image.height, samples: samples)
			let optimized = try Encoder.encode(buffer, distance: distance)
			let decoded = try #require(
				Self.decode(optimized),
				"\(fixture) at d=\(distance) produced an undecodable stream")
			#expect(decoded.count == image.width * image.height * 4)
			#expect(
				Set(stride(from: 0, to: decoded.count, by: 4).map { decoded[$0] })
					.count > 8)
		}
	}

#endif  // canImport(ImageIO)
