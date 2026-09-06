#if canImport(ImageIO)

	import CoreGraphics
	import Foundation
	import ImageIO
	import Testing
	import UniformTypeIdentifiers

	@testable import JXLEncoder
	@testable import JXLEncoderApple

	/// The shim's JPEG path end to end: which inputs take it, which fall back,
	/// and whether what comes out matches the source.
	///
	/// Recompression is opportunistic, so a fixture the parser declines must
	/// still encode — just by decoding and re-encoding the pixels instead. Both
	/// halves of that are asserted here; a fallback that silently produced
	/// nothing would otherwise look like a pass.
	@Suite("JPEG recompression through the shim")
	struct JPEGRecompressionTests {
		/// Everything the transcode should handle.
		static let recompressible = [
			"hopper_444", "hopper_422", "hopper_420_restart", "hopper_420_odd",
			"hopper_420_sof1", "hopper_gray_odd", "small_444", "small_422",
			"small_440",
		]
		/// Everything it should decline, with the reason.
		///
		/// 4:1:1 needs a subsampling shift of two and JXL carries a two-bit mode;
		/// `cjxl --lossless_jpeg=1` refuses the same file. The other two are
		/// entropy coders the parser does not implement.
		static let mustFallBack = ["hopper_411", "reject_progressive", "reject_arithmetic"]

		static func fixture(_ name: String) throws -> Data {
			let url = try #require(
				Bundle.module.url(
					forResource: name, withExtension: "jpg",
					subdirectory: "Fixtures"))
			return try Data(contentsOf: url)
		}

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

		static func meanError(_ encoded: Data, against source: Data) throws -> Double {
			let ours = try #require(Self.samples(encoded))
			let reference = try #require(Self.samples(source))
			try #require(ours.width == reference.width)
			try #require(ours.height == reference.height)
			let total = zip(ours.rgb, reference.rgb).reduce(0.0) {
				$0 + abs(Double($1.0) - Double($1.1))
			}
			return total / Double(ours.rgb.count)
		}

		// MARK: - Which path each input takes

		@Test("recompressible fixtures take the transcode", arguments: recompressible)
		func takesTranscode(name: String) throws {
			#expect(JXLEncoderApple.recompressedJPEG(try Self.fixture(name)) != nil)
		}

		@Test("unsupported fixtures decline it", arguments: mustFallBack)
		func declinesTranscode(name: String) throws {
			#expect(JXLEncoderApple.recompressedJPEG(try Self.fixture(name)) == nil)
		}

		/// Declining must not mean failing: the pixel path still has to produce a
		/// decodable file of the right size.
		@Test("declined fixtures still encode by the pixel path", arguments: mustFallBack)
		func fallbackStillEncodes(name: String) throws {
			let source = try Self.fixture(name)
			let encoded = try JXLEncoderApple.encode(data: source)
			let ours = try #require(Self.samples(encoded))
			let reference = try #require(Self.samples(source))
			#expect(ours.width == reference.width)
			#expect(ours.height == reference.height)
		}

		/// A thumbnail changes the resolution, which a transcode cannot do — it
		/// reproduces the source's own grid. So a size cap has to take the pixel
		/// path even for a JPEG the transcode would otherwise accept.
		@Test("a size cap forces the pixel path")
		func thumbnailBypassesTranscode() throws {
			let source = try Self.fixture("hopper_444")
			#expect(JXLEncoderApple.recompressedJPEG(source) != nil)
			let encoded = try JXLEncoderApple.encode(data: source, maxPixelSize: 64)
			let decoded = try #require(Self.samples(encoded))
			#expect(max(decoded.width, decoded.height) == 64)
		}

		/// Not-a-JPEG must not even reach the parser.
		@Test("non-JPEG input skips the transcode")
		func nonJPEGSkipped() throws {
			#expect(
				JXLEncoderApple.recompressedJPEG(Data([0x89, 0x50, 0x4E, 0x47]))
					== nil)
			#expect(JXLEncoderApple.recompressedJPEG(Data()) == nil)
		}

		// MARK: - Multi-group geometry

		/// A subsampled JPEG large enough to span several AC groups (256 px) and,
		/// past 2048 px, a DC-group boundary too — sized in blocks of a colour that
		/// repeats with a period coprime to both, so a block landing in the wrong
		/// place reliably shows up as the wrong colour rather than by chance
		/// matching its neighbour.
		///
		/// Every named fixture is well under 256 px, so none of them exercises a
		/// DC group folding in more than one AC group's worth of subsampled
		/// chroma. That gap let a real bug through: the fold-in indexed every
		/// channel's DC plane with the luma stride, which is only correct when
		/// chroma is not subsampled or a DC group holds exactly one AC group.
		/// Mean error on a 600x600 case that should have caught it was 87.7 —
		/// found only once something bigger than a single group existed to test.
		static func checkerboardJPEG(size: Int) -> Data {
			let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
			let context = CGContext(
				data: nil, width: size, height: size, bitsPerComponent: 8,
				bytesPerRow: 0, space: colorSpace,
				bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
			let colors: [(CGFloat, CGFloat, CGFloat)] = [
				(1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0), (1, 0, 1), (0, 1, 1),
				(1, 0.5, 0), (0.5, 0, 1),
			]
			let block = 91
			let blocksPerSide = size / block + 1
			for by in 0..<blocksPerSide {
				for bx in 0..<blocksPerSide {
					let (r, g, b) = colors[(by * 13 + bx * 7) % colors.count]
					context.setFillColor(
						CGColor(red: r, green: g, blue: b, alpha: 1))
					context.fill(
						CGRect(
							x: bx * block, y: by * block, width: block,
							height: block))
				}
			}
			let image = context.makeImage()!
			let dest = NSMutableData()
			let destination = CGImageDestinationCreateWithData(
				dest, UTType.jpeg.identifier as CFString, 1, nil)!
			CGImageDestinationAddImage(
				destination, image,
				[kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
			CGImageDestinationFinalize(destination)
			return dest as Data
		}

		/// 600 px spans several AC groups within a single DC group; 2200 px also
		/// crosses the 2048 px DC-group boundary, so the DC group's own destination
		/// offset is exercised too, not just the AC group's.
		@Test("multi-group subsampled JPEGs recompress correctly", arguments: [600, 2200])
		func multiGroupFidelity(size: Int) throws {
			let source = Self.checkerboardJPEG(size: size)
			let encoded = try #require(JXLEncoderApple.recompressedJPEG(source))
			let error = try Self.meanError(encoded, against: source)
			#expect(error < 2.5, "\(size)x\(size): mean absolute error \(error)")
		}

		/// Pixel fidelity alone would not catch a regression to a degenerate
		/// block context map (e.g. `blockContextMap` silently going back to
		/// nil) — a trivial map still decodes correctly, just larger. None of
		/// the small hopper/small fixtures reach enough blocks to exercise more
		/// than one threshold; this one already does (2026-08-08 measurement:
		/// 6 thresholds, 15 of the format's 16-category ceiling).
		@Test("a large transcode's block context map is genuinely adaptive")
		func blockContextMapIsAdaptive() throws {
			let source = Self.checkerboardJPEG(size: 2200)
			let image = try JPEGParser.parse([UInt8](source))
			let transcode = try JPEGTranscode(image)
			let result = JPEGBlockContextMap.compute(transcode)
			#expect(result.thresholds.count > 1)
			#expect(result.numContexts > 4)
		}

		// MARK: - Fidelity

		/// A transcode carries the source's own coefficients, so the only honest
		/// difference from decoding the JPEG itself is the inverse transform.
		///
		/// The threshold is the measurement's floor rather than the encoder's:
		/// `cjxl --lossless_jpeg=1` scores the same on these files to three
		/// decimals — 2.076 on `hopper_420_odd`, 1.215 on `hopper_422` — because
		/// ImageIO's JPEG inverse transform is not libjxl's. Anything materially
		/// above this means coefficients are not arriving intact.
		@Test("recompression matches the source", arguments: recompressible)
		func fidelity(name: String) throws {
			let source = try Self.fixture(name)
			let encoded = try #require(JXLEncoderApple.recompressedJPEG(source))
			let error = try Self.meanError(encoded, against: source)
			#expect(error < 2.5, "\(name): mean absolute error \(error)")
		}

		/// The whole point of the path: no generation of loss. Encoding the
		/// recompressed output's *source* twice must give the same bytes, and the
		/// transcode must be reached through the public entry point rather than
		/// only through the internal one.
		@Test(
			"the public entry point uses the transcode",
			arguments: ["hopper_444", "hopper_422"])
		func publicEntryPointRecompresses(name: String) throws {
			let source = try Self.fixture(name)
			let direct = try #require(JXLEncoderApple.recompressedJPEG(source))
			let viaEncode = try JXLEncoderApple.encode(data: source)
			#expect(viaEncode == direct)
		}

		/// The concurrent entry point must agree with the serial one byte for
		/// byte, on both the pixel path and the recompression path it shares.
		@Test(
			"concurrent and serial entry points agree",
			arguments: ["hopper_444", "hopper_411"])
		func concurrentMatchesSerial(name: String) async throws {
			let source = try Self.fixture(name)
			#expect(
				try await JXLEncoderApple.encodeConcurrently(data: source)
					== (try JXLEncoderApple.encode(data: source)))
			// And through the pixel path, which a size cap forces.
			#expect(
				try await JXLEncoderApple.encodeConcurrently(
					data: source, maxPixelSize: 96)
					== (try JXLEncoderApple.encode(
						data: source, maxPixelSize: 96)))
		}

		/// Recompression never materialises pixels, so it is not bound by the
		/// decode budget — a photograph too large for the pixel path can still
		/// take this one.
		@Test("recompression is not subject to the decode budget")
		func ignoresDecodeBudget() throws {
			let source = try Self.fixture("hopper_444")
			#expect(throws: Never.self) {
				try JXLEncoderApple.encode(data: source, maxSourceBytes: 1)
			}
		}

		// MARK: - EXIF orientation

		/// A 200x120 landscape image with a red block in the visual top-left
		/// corner, written as a baseline JPEG tagged with `orientation`.
		///
		/// The tag is asserted to round-trip. Writing it is fragile: a
		/// properties dict that coerces the Int orientation to a Double
		/// alongside the Double quality is silently dropped by ImageIO, which
		/// would leave an upright fixture and false-green every test that means
		/// to feed an oriented one. `[CFString: Any]` keeps the Int an Int.
		static func orientedJPEG(orientation: Int) throws -> Data {
			let width = 200
			let height = 120
			let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
			let context = CGContext(
				data: nil, width: width, height: height, bitsPerComponent: 8,
				bytesPerRow: 0, space: colorSpace,
				bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
			context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
			context.fill(CGRect(x: 0, y: 0, width: width, height: height))
			context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
			// A corner block, not a full-width bar: asymmetric under every
			// orientation, so a wrong rotation or a mirror shows up in the pixels
			// (via the transform-applied reference), not only in the dimensions.
			// CoreGraphics origin is bottom-left, so high y is the visual top —
			// this is the top-left corner.
			context.fill(CGRect(x: 0, y: height - 20, width: 20, height: 20))
			let image = context.makeImage()!

			let dest = NSMutableData()
			let destination = CGImageDestinationCreateWithData(
				dest, UTType.jpeg.identifier as CFString, 1, nil)!
			let properties: [CFString: Any] = [
				kCGImagePropertyOrientation: orientation,
				kCGImageDestinationLossyCompressionQuality: 0.9,
			]
			CGImageDestinationAddImage(
				destination, image, properties as CFDictionary)
			CGImageDestinationFinalize(destination)
			let data = dest as Data

			try #require(
				Self.orientationTag(data) == orientation,
				"fixture lost its orientation tag")
			return data
		}

		/// The EXIF orientation ImageIO reports for `data`, or nil if none — the
		/// same value the gate reads and the pixel path bakes.
		static func orientationTag(_ data: Data) -> Int? {
			CGImageSourceCreateWithData(data as CFData, nil)
				.flatMap {
					CGImageSourceCopyPropertiesAtIndex($0, 0, nil)
						as? [CFString: Any]
				}
				.flatMap { $0[kCGImagePropertyOrientation] as? Int }
		}

		/// Full-size decode with the EXIF transform applied — the upright pixels
		/// the pixel path feeds the encoder, and so the reference the baked
		/// output should match.
		static func transformedSamples(
			_ data: Data
		) -> (width: Int, height: Int, rgb: [UInt8])? {
			guard
				let source = CGImageSourceCreateWithData(data as CFData, nil),
				let image = CGImageSourceCreateThumbnailAtIndex(
					source, 0,
					[
						kCGImageSourceCreateThumbnailFromImageAlways: true,
						kCGImageSourceCreateThumbnailWithTransform: true,
					] as CFDictionary)
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

		/// The fast path must decline every non-identity orientation — flips and
		/// rotations alike — because it copies coefficients verbatim and cannot
		/// bake the transform. The anchor: this returns non-nil against pre-fix
		/// code, where the transcode ran regardless of orientation.
		@Test(
			"a non-identity EXIF orientation declines the transcode",
			arguments: [2, 3, 4, 5, 6, 7, 8])
		func orientationDeclinesTranscode(orientation: Int) throws {
			let source = try Self.orientedJPEG(orientation: orientation)
			#expect(JXLEncoderApple.recompressedJPEG(source) == nil)
		}

		/// The gate must not over-reach: an upright source still recompresses.
		@Test("an upright source still recompresses")
		func uprightStillRecompresses() throws {
			let identity = try Self.orientedJPEG(orientation: 1)
			#expect(JXLEncoderApple.recompressedJPEG(identity) != nil)
		}

		/// End to end: a full-size encode of an orientation-6 JPEG bakes the 90°
		/// rotation, so it decodes portrait — dimensions swapped from the raw
		/// 200x120 grid — and matches the transform-applied source. Pre-fix it
		/// took the transcode and decoded landscape, orientation dropped.
		@Test("a full-size encode bakes EXIF orientation")
		func fullSizeBakesOrientation() throws {
			let source = try Self.orientedJPEG(orientation: 6)
			let encoded = try JXLEncoderApple.encode(data: source)
			let ours = try #require(Self.samples(encoded))
			let reference = try #require(Self.transformedSamples(source))
			#expect(
				ours.height > ours.width,
				"expected portrait, got \(ours.width)x\(ours.height)")
			try #require(ours.width == reference.width)
			try #require(ours.height == reference.height)
			let total = zip(ours.rgb, reference.rgb).reduce(0.0) {
				$0 + abs(Double($1.0) - Double($1.1))
			}
			let error = total / Double(ours.rgb.count)
			#expect(error < 6, "mean absolute error \(error)")
			// The other half of the contract: orientation is baked into the
			// pixels, so the output declares none of its own.
			let outputOrientation = Self.orientationTag(encoded)
			#expect(outputOrientation == nil || outputOrientation == 1)
		}

		/// The flip side of `ignoresDecodeBudget`: an oriented JPEG now takes the
		/// pixel path, so it *is* bound by the decode budget — a tight one refuses
		/// it where the transcode would have ignored the budget entirely. Pins the
		/// behaviour change this fix introduces.
		@Test("an oriented JPEG is subject to the decode budget")
		func orientedSubjectToBudget() throws {
			let source = try Self.orientedJPEG(orientation: 6)
			#expect(throws: JXLEncoderAppleError.self) {
				try JXLEncoderApple.encode(data: source, maxSourceBytes: 1)
			}
		}

		/// The issue's user-facing invariant: a full image and its own thumbnail
		/// must not disagree on orientation. Both take the pixel path, so both
		/// decode portrait. Pre-fix the full image alone came out landscape.
		@Test("full image and thumbnail agree on orientation")
		func fullAndThumbnailAgree() throws {
			let source = try Self.orientedJPEG(orientation: 6)
			let full = try #require(
				Self.samples(try JXLEncoderApple.encode(data: source)))
			let thumb = try #require(
				Self.samples(
					try JXLEncoderApple.encode(data: source, maxPixelSize: 64)))
			#expect(full.height > full.width)
			#expect(thumb.height > thumb.width)
		}

		/// The concurrent entry point shares the gate, so it too declines the
		/// transcode and bakes the orientation. Asserting it decodes portrait —
		/// not merely that it equals the serial path, which held pre-fix too when
		/// both recompressed identity output — is what pins the baking here.
		@Test("concurrent entry point bakes orientation too")
		func concurrentBakesOrientation() async throws {
			let source = try Self.orientedJPEG(orientation: 6)
			let concurrent = try await JXLEncoderApple.encodeConcurrently(
				data: source)
			let decoded = try #require(Self.samples(concurrent))
			#expect(
				decoded.height > decoded.width,
				"expected portrait, got \(decoded.width)x\(decoded.height)")
			#expect(concurrent == (try JXLEncoderApple.encode(data: source)))
		}
	}

#endif  // canImport(ImageIO)
