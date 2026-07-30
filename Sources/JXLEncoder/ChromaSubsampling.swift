//
//  ChromaSubsampling.swift
//  JXLEncoder
//
//  Per-channel chroma subsampling, matching `YCbCrChromaSubsampling` in
//  libjxl's lib/jxl/frame_header.h.
//
//  Only reachable through JPEG recompression: the pixel path converts to XYB at
//  full resolution and is always 4:4:4. Encoding a JPEG's coefficients directly
//  means carrying whatever sampling factors it used.
//

/// How much each channel is downsampled, stored as one of four modes per
/// channel and serialized as three 2-bit fields in the frame header.
public struct ChromaSubsampling: Equatable, Sendable {
	/// mode → (horizontal, vertical) shift before normalisation.
	static let rawHShift: [Int] = [0, 1, 1, 0]
	static let rawVShift: [Int] = [0, 1, 0, 1]

	/// Channel order is X, Y, B — which for YCbCr is Cb, Y, Cr.
	public let channelMode: [Int]
	let maxHShift: Int
	let maxVShift: Int

	public init(channelMode: [Int]) {
		precondition(channelMode.count == 3)
		self.channelMode = channelMode
		maxHShift = channelMode.map { Self.rawHShift[$0] }.max() ?? 0
		maxVShift = channelMode.map { Self.rawVShift[$0] }.max() ?? 0
	}

	public static let none = ChromaSubsampling(channelMode: [0, 0, 0])

	/// Shifts are relative to the least-subsampled channel, so the channel with
	/// the highest sampling factor comes out at shift 0.
	public func horizontalShift(_ channel: Int) -> Int {
		maxHShift - Self.rawHShift[channelMode[channel]]
	}

	public func verticalShift(_ channel: Int) -> Int {
		maxVShift - Self.rawVShift[channelMode[channel]]
	}

	public var is444: Bool {
		(0..<3).allSatisfy { horizontalShift($0) == 0 && verticalShift($0) == 0 }
	}

	/// Builds from JPEG sampling factors, which are indexed by JPEG component
	/// order (Y, Cb, Cr) while JXL channels run X, Y, B — so components 0 and 1
	/// swap.
	public static func fromJPEG(
		horizontalSampling: [Int], verticalSampling: [Int]
	) -> ChromaSubsampling? {
		guard horizontalSampling.count == 3, verticalSampling.count == 3 else { return nil }
		var modes = [Int](repeating: 0, count: 3)
		for channel in 0..<3 {
			let component = channel < 2 ? channel ^ 1 : channel
			guard
				let mode = (0..<4).first(where: {
					1 << rawHShift[$0] == horizontalSampling[component]
						&& 1 << rawVShift[$0] == verticalSampling[component]
				})
			else { return nil }
			modes[channel] = mode
		}
		return ChromaSubsampling(channelMode: modes)
	}

	/// Whether this channel codes a block at full-resolution block position
	/// `(bx, by)`. A subsampled channel only codes where its own grid aligns.
	public func codesBlock(channel: Int, blockX: Int, blockY: Int) -> Bool {
		let hs = horizontalShift(channel)
		let vs = verticalShift(channel)
		return (blockX >> hs) << hs == blockX && (blockY >> vs) << vs == blockY
	}

	public func subsampledX(channel: Int, blockX: Int) -> Int {
		blockX >> horizontalShift(channel)
	}

	public func subsampledY(channel: Int, blockY: Int) -> Int {
		blockY >> verticalShift(channel)
	}

	/// Blocks this channel spans given the full-resolution block count.
	public func blocksAcross(channel: Int, fullWidthInBlocks: Int) -> Int {
		Geometry.divCeil(fullWidthInBlocks, 1 << horizontalShift(channel))
	}

	public func blocksDown(channel: Int, fullHeightInBlocks: Int) -> Int {
		Geometry.divCeil(fullHeightInBlocks, 1 << verticalShift(channel))
	}

	/// Three 2-bit mode fields, as the frame header carries them.
	public func write(to writer: inout BitWriter) {
		for mode in channelMode { writer.write(2, UInt64(mode)) }
	}
}
