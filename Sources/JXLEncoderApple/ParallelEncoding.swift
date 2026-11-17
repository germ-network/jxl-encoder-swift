#if canImport(ImageIO)
	import CoreGraphics
	import Foundation
	import JXLEncoder

	extension JXLEncoderApple {
		/// Encodes an image synchronously using bounded internal parallelism.
		@available(iOS 18, macOS 15, *)
		public static func encode(
			image: CGImage,
			distance: Float = 1.0,
			alphaPolicy: AlphaPolicy = .flatten(background: defaultBackground),
			runner: any ParallelRunner
		) throws -> Data {
			guard runner.maximumWorkers > 0 else {
				throw EncoderError.invalidWorkerCount(runner.maximumWorkers)
			}
			let buffer = try imageBuffer(from: image, alphaPolicy: alphaPolicy)
			return Data(try Encoder.encode(buffer, distance: distance, runner: runner))
		}

		/// Encodes image data synchronously using bounded internal parallelism.
		///
		/// Eligible JPEG coefficient recompression remains serial. Other inputs use
		/// the runner after the existing decode, geometry, alpha and budget policies.
		@available(iOS 18, macOS 15, *)
		public static func encode(
			data: Data,
			distance: Float = 1.0,
			maxPixelSize: Int? = nil,
			alphaPolicy: AlphaPolicy = .flatten(background: defaultBackground),
			maxSourceBytes: Int = defaultMaxSourceBytes,
			runner: any ParallelRunner
		) throws -> Data {
			guard runner.maximumWorkers > 0 else {
				throw EncoderError.invalidWorkerCount(runner.maximumWorkers)
			}
			if maxPixelSize == nil, let recompressed = recompressedJPEG(data) {
				return recompressed
			}
			let image = try decodedImage(
				data: data, maxPixelSize: maxPixelSize,
				maxSourceBytes: maxSourceBytes)
			let buffer = try imageBuffer(from: image, alphaPolicy: alphaPolicy)
			return Data(try Encoder.encode(buffer, distance: distance, runner: runner))
		}
	}
#endif
