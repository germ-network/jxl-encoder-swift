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

		static func decodes(_ bytes: [UInt8]) -> Bool {
			guard
				let source = CGImageSourceCreateWithData(Data(bytes) as CFData, nil)
			else { return false }
			return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
		}

		/// 4:4:4 and greyscale decode on both paths.
		@Test(
			"unsubsampled transcodes decode",
			arguments: ["hopper_444", "hopper_gray_odd"], [true, false])
		func unsubsampled(name: String, optimize: Bool) throws {
			let bytes = try Encoder.encodeJPEG(
				try Self.transcode(name), optimizeCodes: optimize)
			#expect(Self.decodes(bytes))
		}

		/// The bisect. If the static path decodes and the optimised one does not,
		/// the coefficient layout is sound and the fault is in the entropy code
		/// built from this image's statistics — which is the only thing the two
		/// paths differ by.
		@Test(
			"subsampled transcodes, static entropy tables",
			arguments: ["hopper_422", "hopper_420_restart"])
		func subsampledStatic(name: String) throws {
			let bytes = try Encoder.encodeJPEG(
				try Self.transcode(name), optimizeCodes: false)
			#expect(Self.decodes(bytes))
		}
	}

#endif  // canImport(ImageIO)
