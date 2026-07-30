//
//  PlaneBuffer.swift
//  JXLEncoder
//
//  Interleaved-to-planar extraction with the edge replication the reference
//  applies in `CopyAndPadImage` (encoder/enc_frame.cc).
//
//  Padding matters for correctness, not just tidiness: the encoder transforms
//  whole 8x8 blocks, so any image whose dimensions are not a multiple of 8 has
//  its final row and column of blocks fed partly from replicated edge pixels.
//

/// Three planar float channels covering one rectangle of an image, padded out
/// to whole blocks.
public struct PaddedStripe: Sendable {
	public let width: Int
	public let height: Int
	public var planes: [[Float]]

	public init(width: Int, height: Int, planes: [[Float]]) {
		self.width = width
		self.height = height
		self.planes = planes
	}

	public func plane(_ channel: Int) -> [Float] { planes[channel] }

	/// Every channel at the same resolution, which is what the pixel path
	/// always produces.
	public var channelPlanes: ChannelPlanes {
		ChannelPlanes(
			planes: planes,
			widths: [width, width, width],
			heights: [height, height, height])
	}
}

/// Three planes that may differ in resolution.
///
/// Chroma subsampling is the only thing that makes them differ, and it only
/// arises from JPEG recompression — the pixel path is always 4:4:4.
public struct ChannelPlanes: Sendable {
	public let planes: [[Float]]
	public let widths: [Int]
	public let heights: [Int]

	public init(planes: [[Float]], widths: [Int], heights: [Int]) {
		self.planes = planes
		self.widths = widths
		self.heights = heights
	}
}

public enum PlaneBuffer {
	/// Copies `rect` out of an interleaved source and pads it up to whole
	/// blocks by repeating the last real column, then the last real row.
	///
	/// Order matters: rows are padded first (each row extended to the padded
	/// width), then whole padded rows are duplicated downward — so the
	/// bottom-right corner comes from the last real pixel, matching the
	/// reference.
	public static func copyAndPad(
		source: [Float],
		sourceWidth: Int,
		channels: Int = 3,
		rect: Rect
	) -> PaddedStripe {
		let paddedWidth = Geometry.roundUp(rect.width, to: Geometry.blockDim)
		let paddedHeight = Geometry.roundUp(rect.height, to: Geometry.blockDim)

		var planes = [[Float]](
			repeating: [Float](repeating: 0, count: paddedWidth * paddedHeight),
			count: channels)

		for c in 0..<channels {
			for y in 0..<rect.height {
				let sourceRow = (rect.y0 + y) * sourceWidth + rect.x0
				let destRow = y * paddedWidth
				for x in 0..<rect.width {
					planes[c][destRow + x] =
						source[(sourceRow + x) * channels + c]
				}
				let last = planes[c][destRow + rect.width - 1]
				for x in rect.width..<paddedWidth {
					planes[c][destRow + x] = last
				}
			}
			let lastRow = (rect.height - 1) * paddedWidth
			for y in rect.height..<paddedHeight {
				let destRow = y * paddedWidth
				for x in 0..<paddedWidth {
					planes[c][destRow + x] = planes[c][lastRow + x]
				}
			}
		}

		return PaddedStripe(width: paddedWidth, height: paddedHeight, planes: planes)
	}
}
