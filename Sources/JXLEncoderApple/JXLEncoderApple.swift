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
		/// Encoding the source at its declared size would exceed the caller's
		/// memory budget.
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

		/// Peak bytes a full-size encode holds, per source pixel: four for the
		/// drawing context, three for the extracted samples, twelve for the
		/// linear plane.
		static let bytesPerSourcePixel = 19

		/// Memory budget applied to input whose size the caller has not bounded,
		/// matching `JPEGParser.defaultMaxCoefficientBytes`. At 19 bytes a pixel
		/// this admits about 14 MP, past the 12 MP the encoder is designed
		/// around but short of a 48 MP sensor — raise it deliberately if that
		/// input has to be accepted, and lower it in an extension running under
		/// its own memory limit.
		public static let defaultMaxSourceBytes = JPEGParser.defaultMaxCoefficientBytes

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
			guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
				throw JXLEncoderAppleError.decodeFailed
			}
			try checkSourceSize(source, budget: maxSourceBytes)
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
			return try encode(
				image: image, distance: distance, alphaPolicy: alphaPolicy)
		}

		/// Reads the declared dimensions from the container's metadata, which
		/// does not decode the image.
		///
		/// A source that will not report its size is passed through rather than
		/// rejected: the formats that do this are ones ImageIO is about to refuse
		/// anyway, and failing here would turn a decode error into a size error.
		static func checkSourceSize(_ source: CGImageSource, budget: Int) throws {
			guard
				let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
					as? [CFString: Any],
				let width = properties[kCGImagePropertyPixelWidth] as? Int,
				let height = properties[kCGImagePropertyPixelHeight] as? Int,
				width > 0, height > 0
			else { return }

			let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
			let (required, byteOverflow) =
				pixelOverflow
				? (0, true)
				: pixels.multipliedReportingOverflow(by: bytesPerSourcePixel)
			guard !pixelOverflow, !byteOverflow, required <= budget else {
				throw JXLEncoderAppleError.sourceBudgetExceeded(
					width: width, height: height,
					required: pixelOverflow || byteOverflow ? .max : required,
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
