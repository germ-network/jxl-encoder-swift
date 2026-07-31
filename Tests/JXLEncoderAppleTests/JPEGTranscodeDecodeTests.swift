#if canImport(ImageIO)

	import CoreGraphics
	import Foundation
	import ImageIO
	import JXLEncoder
	import Testing

	/// Where the JPEG transcode currently stands, per subsampling and per entropy
	/// path. ImageIO is the decoder, so this records what a real consumer accepts.
	///
	/// Written to separate two candidate causes of the subsampled failure: the
	/// coefficient layout, which the static path exercises on its own, and the
	/// per-image entropy code, which only the optimised path builds.
	@Suite("JPEG transcode decoding")
	struct JPEGTranscodeDecodeTests {
		static func transcode(_ name: String) throws -> JPEGTranscode {
			let url = try #require(
				Bundle.module.url(
					forResource: name, withExtension: "jpg",
					subdirectory: "Fixtures"))
			return try JPEGTranscode(
				try JPEGParser.parse([UInt8](try Data(contentsOf: url))))
		}

		/// Decoding to a non-nil image proves very little: ImageIO accepts streams
		/// djxl rejects outright, so an existence check reads as a pass on files
		/// that are plainly wrong. Compare pixels instead.
		static func samples(_ data: Data) -> (width: Int, height: Int, rgb: [UInt8])? {
			guard
				let source = CGImageSourceCreateWithData(data as CFData, nil),
				let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
			else { return nil }
			let w = image.width
			let h = image.height
			var rgba = [UInt8](repeating: 0, count: w * h * 4)
			rgba.withUnsafeMutableBytes { buffer in
				let context = CGContext(
					data: buffer.baseAddress, width: w, height: h,
					bitsPerComponent: 8, bytesPerRow: w * 4,
					space: CGColorSpace(name: CGColorSpace.sRGB)!,
					bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
				context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
			}
			var rgb = [UInt8](repeating: 0, count: w * h * 3)
			for i in 0..<(w * h) {
				rgb[i * 3] = rgba[i * 4]
				rgb[i * 3 + 1] = rgba[i * 4 + 1]
				rgb[i * 3 + 2] = rgba[i * 4 + 2]
			}
			return (w, h, rgb)
		}

		/// Mean absolute difference from what the source JPEG decodes to. A
		/// transcode carries the same coefficients, so the only honest source of
		/// difference is the inverse transform, worth a fraction of a level.
		static func meanError(_ name: String, optimize: Bool) throws -> Double {
			let url = try #require(
				Bundle.module.url(
					forResource: name, withExtension: "jpg",
					subdirectory: "Fixtures"))
			let jpeg = try Data(contentsOf: url)
			let bytes = try Encoder.encodeJPEG(
				try JPEGTranscode(try JPEGParser.parse([UInt8](jpeg))),
				optimizeCodes: optimize)

			let ours = try #require(Self.samples(Data(bytes)))
			let reference = try #require(Self.samples(jpeg))
			try #require(ours.width == reference.width)
			try #require(ours.height == reference.height)
			let total = zip(ours.rgb, reference.rgb).reduce(0.0) {
				$0 + abs(Double($1.0) - Double($1.1))
			}
			return total / Double(ours.rgb.count)
		}

		/// Known broken, recorded so the numbers stay visible and so the day the
		/// transcode starts working this reports an unexpected pass rather than
		/// staying quietly green.
		///
		/// Mean absolute error against the source: 4:4:4 about 27 levels,
		/// greyscale about 67, subsampled about 210 — the last being noise. A
		/// transcode carries the source's own coefficients, so anything past a
		/// level or two means they are not arriving intact.
		@Test(
			"unsubsampled transcodes match the source",
			arguments: ["hopper_444", "hopper_gray_odd"], [true, false])
		func unsubsampled(name: String, optimize: Bool) throws {
			try withKnownIssue("the transcode is not yet correct") {
				let error = try Self.meanError(name, optimize: optimize)
				#expect(error < 2.0, "mean absolute error \(error)")
			}
		}

		/// The failure itself, so it is reproducible here rather than only through a
		/// command-line run. Expected to fail until the optimised entropy path is
		/// fixed for subsampled input.
		@Test(
			"subsampled transcodes, optimised entropy codes",
			arguments: ["hopper_422", "hopper_420_restart"])
		func subsampledOptimized(name: String) throws {
			try withKnownIssue("the transcode is not yet correct") {
				let error = try Self.meanError(name, optimize: true)
				#expect(error < 2.0, "mean absolute error \(error)")
			}
		}

		/// The entropy path makes no difference to the pixels, which is what an
		/// entropy layer should do and what an earlier reading of this got wrong: a
		/// decodability check made the static path look like it worked, when both
		/// paths were producing the same wrong image and only ImageIO's leniency
		/// separated them from djxl's rejection.
		@Test(
			"the entropy path does not change the pixels",
			arguments: ["hopper_444", "hopper_422", "hopper_420_restart"])
		func entropyPathIsNeutral(name: String) throws {
			let optimized = try Self.meanError(name, optimize: true)
			let staticCoded = try Self.meanError(name, optimize: false)
			#expect(optimized == staticCoded)
		}

		/// The bisect. If the static path decodes and the optimised one does not,
		/// the coefficient layout is sound and the fault is in the entropy code
		/// built from this image's statistics — which is the only thing the two
		/// paths differ by.
		@Test(
			"subsampled transcodes, static entropy tables",
			arguments: ["hopper_422", "hopper_420_restart"])
		func subsampledStatic(name: String) throws {
			try withKnownIssue("the transcode is not yet correct") {
				let error = try Self.meanError(name, optimize: false)
				#expect(error < 2.0, "mean absolute error \(error)")
			}
		}
	}

#endif  // canImport(ImageIO)
