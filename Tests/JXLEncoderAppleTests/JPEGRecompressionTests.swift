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
	}

#endif  // canImport(ImageIO)
