//
//  JXLEncoderApple.swift
//  JXLEncoderApple
//
//  The platform shim: decodes anything ImageIO supports, hands 8-bit sRGB
//  samples to the portable core, and returns `Data`.
//
//  This is the only target that touches CoreGraphics, ImageIO or Foundation.
//  It is also the only place with pointer interop, which CoreGraphics requires;
//  the core stays free of it.
//

// The whole shim is Apple-only. `swift test` builds every target, so without
// this guard the portable core's Linux CI job fails to build.
#if canImport(ImageIO)

	import CoreGraphics
	import Foundation
	import ImageIO
	import JXLEncoder
	import UniformTypeIdentifiers

	public enum JXLEncoderAppleError: Error, Equatable {
		case decodeFailed
		case contextCreationFailed
		/// Alpha preservation is deliberately not implemented; flatten instead.
		case alphaNotSupported
		/// Encoding would exceed the caller's memory budget. `width` and `height`
		/// are the source's; `required` is for the size it would decode to, so a
		/// `maxPixelSize` that scales the source down is already reflected in it.
		case sourceBudgetExceeded(width: Int, height: Int, required: Int, budget: Int)
	}

	/// What to do with an input that carries transparency.
	public enum AlphaPolicy: Sendable {
		/// Composite over a solid colour and encode opaque RGB.
		case flatten(background: CGColor)
		/// Keep alpha as a JXL extra channel.
		///
		/// Deliberately unimplemented. Carrying alpha means modular extra
		/// channels — header signalling, a global declaration, and a
		/// `ModularAC` stream appended to every AC group — and libjxl-tiny has
		/// no alpha at all, so unlike every other stage there would be no
		/// reference to diff against. Callers composite over a background
		/// instead, which is what the app intends to do anyway. Throws
		/// `alphaNotSupported` rather than silently degrading.
		case preserve
	}

	public enum JXLEncoderApple {
		/// Opaque white, constructed explicitly because `CGColor.white` exists only
		/// on macOS.
		public static let defaultBackground = CGColor(
			colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
			components: [1, 1, 1, 1])!

		/// Encodes a `CGImage`, compositing away any alpha per `alphaPolicy`.
		///
		/// `distance` is a butteraugli target: lower means higher quality.
		public static func encode(
			image: CGImage,
			distance: Float = 1.0,
			alphaPolicy: AlphaPolicy = .flatten(background: defaultBackground)
		) throws -> Data {
			let samples = try sRGBSamples(from: image, alphaPolicy: alphaPolicy)
			let buffer = try ImageBuffer(
				width: image.width, height: image.height, samples: samples,
				channels: 3)
			return Data(try Encoder.encode(buffer, distance: distance))
		}

		/// Peak bytes an encode holds per *decoded* pixel.
		///
		/// Nineteen are accounted for — four for the drawing context, three for
		/// the extracted samples, twelve for the linear plane — and measured peak
		/// RSS runs well above that, the rest being ImageIO's own decode.
		/// Measured at full size: 110 MB at 2 MP, 503 MB at 12 MP, 772 MB at
		/// 24 MP, 1388 MB at 48 MP.
		static let bytesPerDecodedPixel = 40

		/// Working set an encode holds regardless of size, which a per-pixel
		/// figure alone cannot express: a 200 px thumbnail costs 17 to 24 MB
		/// depending on how large the source it came from was.
		///
		/// Carries margin for run-to-run variance as well — the same encode was
		/// seen at 158 MB and 178 MB on consecutive runs, so a bound fitted
		/// tightly to one set of measurements would not hold on the next.
		///
		/// Together with `bytesPerDecodedPixel` this sits above every measurement
		/// taken, at the cost of over-estimating a large encode by up to about
		/// half. Erring high is the safe direction — the estimate decides what
		/// gets refused.
		static let fixedOverheadBytes = 80 << 20

		/// Memory budget applied when the caller does not name one.
		///
		/// 640 MB, which admits about 14 MP — past the 12 MP the encoder is
		/// designed around, which measures 503 MB.
		///
		/// This bounds the *decode*, so it is not a limit on how large a source
		/// may be: `maxPixelSize` scales during decoding rather than after it, so
		/// a 48 MP photograph asked for at 200 px costs 24 MB and is nowhere near
		/// this. Only a full-size encode of such a photograph is refused, and
		/// that one needs roughly 1.4 GB.
		public static let defaultMaxSourceBytes = 640 << 20

		/// The size ImageIO will decode to, after `maxPixelSize` caps the longest
		/// edge. Aspect ratio is preserved and the cap never enlarges.
		public static func decodedSize(
			width: Int, height: Int, maxPixelSize: Int?
		) -> (width: Int, height: Int) {
			guard let maxPixelSize, maxPixelSize > 0,
				max(width, height) > maxPixelSize
			else { return (width, height) }
			let scale = Double(maxPixelSize) / Double(max(width, height))
			return (
				max(1, Int((Double(width) * scale).rounded())),
				max(1, Int((Double(height) * scale).rounded()))
			)
		}

		/// Peak bytes encoding a source of these dimensions is expected to hold,
		/// as an upper bound over everything measured.
		///
		/// Exposed so a caller can decide what to allow from what the device can
		/// spare — picking `maxPixelSize` by device model, say — rather than
		/// discovering the cost by running out of memory. Returns `Int.max` if
		/// the dimensions overflow.
		public static func estimatedEncodeBytes(
			width: Int, height: Int, maxPixelSize: Int? = nil
		) -> Int {
			let size = decodedSize(
				width: width, height: height, maxPixelSize: maxPixelSize)
			let (pixels, pixelOverflow) = size.width.multipliedReportingOverflow(
				by: size.height)
			guard !pixelOverflow else { return .max }
			let (scaled, scaleOverflow) = pixels.multipliedReportingOverflow(
				by: bytesPerDecodedPixel)
			guard !scaleOverflow else { return .max }
			let (total, sumOverflow) = scaled.addingReportingOverflow(
				fixedOverheadBytes)
			return sumOverflow ? .max : total
		}

		/// The largest `maxPixelSize` whose encode is expected to fit in `budget`,
		/// or `nil` if even the smallest encode would not.
		///
		/// The counterpart to `estimatedEncodeBytes` for callers who know what
		/// the device can spare and want the cap that fits it. `aspectRatio` is
		/// long edge over short, since the cap applies to the long edge: 4:3 by
		/// default, which is what phone cameras produce.
		public static func maxPixelSize(
			fitting budget: Int, aspectRatio: Double = 4.0 / 3.0
		) -> Int? {
			let usable = budget - fixedOverheadBytes
			guard usable > 0, aspectRatio >= 1 else { return nil }
			// longEdge * (longEdge / aspectRatio) * bytesPerPixel <= usable
			let longEdge =
				(Double(usable) / Double(bytesPerDecodedPixel) * aspectRatio)
				.squareRoot()
			let cap = Int(longEdge)
			return cap >= 1 ? cap : nil
		}

		/// Decodes any ImageIO-supported input and re-encodes it as JPEG XL.
		///
		/// `maxPixelSize` caps the longest edge, for thumbnails. Decoding goes
		/// through the thumbnail API in both cases because it applies the EXIF
		/// orientation, which the plain image API does not.
		///
		/// `maxSourceBytes` bounds what encoding the source would hold, judged
		/// from the size the container declares and read before anything is
		/// decoded. Headers are cheap to write and expensive to believe: a 12 kB
		/// JPEG rewritten to claim 8000×8000 costs over a gigabyte to honour.
		/// ImageIO applies a plausibility test of its own and refuses the wilder
		/// claims — it declines to report a size at 16000×16000 — but it accepts
		/// that 64 MP one, so this is the backstop under it. `maxPixelSize` is
		/// not a substitute: that bounds the output, this bounds what the
		/// decoder is asked to produce.
		public static func encode(
			data: Data,
			distance: Float = 1.0,
			maxPixelSize: Int? = nil,
			alphaPolicy: AlphaPolicy = .flatten(background: defaultBackground),
			maxSourceBytes: Int = defaultMaxSourceBytes
		) throws -> Data {
			// A JPEG can be re-coded from its own coefficients, which avoids a
			// generation of loss and costs a fraction of the memory — no pixels
			// are ever materialised, so `maxSourceBytes` does not apply and a
			// photograph too large for the pixel path can still go through here.
			//
			// Only at full size: the transcode reproduces the source's own
			// resolution, so a thumbnail has to be decoded and re-encoded.
			if maxPixelSize == nil, let recompressed = recompressedJPEG(data) {
				return recompressed
			}

			let image = try decodedImage(
				data: data, maxPixelSize: maxPixelSize,
				maxSourceBytes: maxSourceBytes)
			return try encode(
				image: image, distance: distance, alphaPolicy: alphaPolicy)
		}

		/// Decodes for either entry point, budget check included.
		///
		/// Both go through the thumbnail API even at full size, because it applies
		/// the EXIF orientation and the plain image API does not.
		static func decodedImage(
			data: Data, maxPixelSize: Int?, maxSourceBytes: Int
		) throws -> CGImage {
			guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
				throw JXLEncoderAppleError.decodeFailed
			}
			try checkSourceSize(
				source, maxPixelSize: maxPixelSize, budget: maxSourceBytes)
			var options: [CFString: Any] = [
				kCGImageSourceCreateThumbnailFromImageAlways: true,
				kCGImageSourceCreateThumbnailWithTransform: true,
			]
			if let maxPixelSize {
				options[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize
			}
			guard
				let image = CGImageSourceCreateThumbnailAtIndex(
					source, 0, options as CFDictionary)
			else {
				throw JXLEncoderAppleError.decodeFailed
			}
			return image
		}

		/// As `encode(data:…)`, with the AC groups computed concurrently.
		///
		/// Byte-identical to the serial path — the groups are independent by
		/// construction — and worth about twice the speed on a full-size
		/// photograph. Below 256 px the image is a single group and this is a
		/// wash, so a thumbnail may as well use the serial entry point.
		///
		/// A JPEG still takes the recompression path, which is serial: it does no
		/// per-pixel work worth splitting.
		public static func encodeConcurrently(
			data: Data,
			distance: Float = 1.0,
			maxPixelSize: Int? = nil,
			alphaPolicy: AlphaPolicy = .flatten(background: defaultBackground),
			maxSourceBytes: Int = defaultMaxSourceBytes
		) async throws -> Data {
			if maxPixelSize == nil, let recompressed = recompressedJPEG(data) {
				return recompressed
			}
			let image = try decodedImage(
				data: data, maxPixelSize: maxPixelSize,
				maxSourceBytes: maxSourceBytes)
			let samples = try sRGBSamples(from: image, alphaPolicy: alphaPolicy)
			let buffer = try ImageBuffer(
				width: image.width, height: image.height, samples: samples,
				channels: 3)
			return Data(
				try await Encoder.encodeConcurrently(buffer, distance: distance))
		}

		/// Re-codes a JPEG from its own quantized coefficients, or returns nil if
		/// this one cannot take that path.
		///
		/// Recompression is an optimisation, never a requirement: anything the
		/// parser or the layout declines — progressive, arithmetic-coded, CMYK,
		/// 4:1:1, a frame JPEG XL cannot express — falls back to decoding and
		/// re-encoding the pixels, which handles everything ImageIO does. So the
		/// failure is swallowed deliberately rather than surfaced.
		static func recompressedJPEG(_ data: Data) -> Data? {
			guard data.count >= 2, data[data.startIndex] == 0xFF,
				data[data.startIndex + 1] == 0xD8
			else { return nil }  // not a JPEG; skip the parse entirely
			do {
				let image = try JPEGParser.parse([UInt8](data))
				let transcode = try JPEGTranscode(image)
				return Data(try Encoder.encodeJPEG(transcode))
			} catch {
				return nil
			}
		}

		/// Reads the declared dimensions from the container's metadata, which
		/// does not decode the image.
		///
		/// A source that will not report its size is passed through rather than
		/// rejected: the formats that do this are ones ImageIO is about to refuse
		/// anyway, and failing here would turn a decode error into a size error.
		static func checkSourceSize(
			_ source: CGImageSource, maxPixelSize: Int?, budget: Int
		) throws {
			guard
				let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
					as? [CFString: Any],
				let width = properties[kCGImagePropertyPixelWidth] as? Int,
				let height = properties[kCGImagePropertyPixelHeight] as? Int,
				width > 0, height > 0
			else { return }

			let required = estimatedEncodeBytes(
				width: width, height: height, maxPixelSize: maxPixelSize)
			guard required <= budget else {
				throw JXLEncoderAppleError.sourceBudgetExceeded(
					width: width, height: height, required: required,
					budget: budget)
			}
		}

		/// Draws into a known 8-bit sRGB layout and returns interleaved RGB.
		static func sRGBSamples(
			from image: CGImage, alphaPolicy: AlphaPolicy
		) throws -> [UInt8] {
			let background: CGColor
			switch alphaPolicy {
			case .preserve:
				throw JXLEncoderAppleError.alphaNotSupported
			case .flatten(let colour):
				background = colour
			}

			let width = image.width
			let height = image.height
			let bytesPerRow = width * 4

			guard
				let context = CGContext(
					data: nil,
					width: width,
					height: height,
					bitsPerComponent: 8,
					bytesPerRow: bytesPerRow,
					space: CGColorSpace(name: CGColorSpace.sRGB)!,
					bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
			else {
				throw JXLEncoderAppleError.contextCreationFailed
			}

			// The context starts zeroed, which would show through as black wherever
			// the source is transparent, so paint the background first.
			context.setFillColor(background)
			context.fill(CGRect(x: 0, y: 0, width: width, height: height))
			context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

			guard let raw = context.data else {
				throw JXLEncoderAppleError.contextCreationFailed
			}
			let rgba = raw.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)

			var samples = [UInt8](repeating: 0, count: width * height * 3)
			for i in 0..<(width * height) {
				samples[i * 3] = rgba[i * 4]
				samples[i * 3 + 1] = rgba[i * 4 + 1]
				samples[i * 3 + 2] = rgba[i * 4 + 2]
			}
			return samples
		}
	}

#endif  // canImport(ImageIO)
