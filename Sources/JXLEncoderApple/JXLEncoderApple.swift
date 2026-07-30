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

import CoreGraphics
import Foundation
import ImageIO
import JXLEncoder
import UniformTypeIdentifiers

public enum JXLEncoderAppleError: Error, Equatable {
	case decodeFailed
	case contextCreationFailed
	/// Alpha is not yet carried through the encoder; flatten it instead.
	case alphaNotSupported
}

/// What to do with an input that carries transparency.
public enum AlphaPolicy: Sendable {
	/// Composite over a solid colour and encode opaque RGB.
	case flatten(background: CGColor)
	/// Keep alpha as a JXL extra channel. Not yet implemented in the core.
	case preserve
}

public enum JXLEncoderApple {
	/// Encodes a `CGImage`, compositing away any alpha per `alphaPolicy`.
	///
	/// `distance` is a butteraugli target: lower means higher quality.
	public static func encode(
		image: CGImage,
		distance: Float = 1.0,
		alphaPolicy: AlphaPolicy = .flatten(background: .white)
	) throws -> Data {
		let samples = try sRGBSamples(from: image, alphaPolicy: alphaPolicy)
		let buffer = try ImageBuffer(
			width: image.width, height: image.height, samples: samples, channels: 3)
		return Data(try Encoder.encode(buffer, distance: distance))
	}

	/// Decodes any ImageIO-supported input and re-encodes it as JPEG XL.
	///
	/// `maxPixelSize` caps the longest edge, for thumbnails. Decoding goes
	/// through the thumbnail API in both cases because it applies the EXIF
	/// orientation, which the plain image API does not.
	public static func encode(
		data: Data,
		distance: Float = 1.0,
		maxPixelSize: Int? = nil,
		alphaPolicy: AlphaPolicy = .flatten(background: .white)
	) throws -> Data {
		guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
			throw JXLEncoderAppleError.decodeFailed
		}
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
		return try encode(image: image, distance: distance, alphaPolicy: alphaPolicy)
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
