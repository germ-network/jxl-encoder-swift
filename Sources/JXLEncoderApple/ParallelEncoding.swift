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
			fatalError("Synchronous parallel image encoding is not implemented")
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
			fatalError("Synchronous parallel data encoding is not implemented")
		}
	}
#endif
