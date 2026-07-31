//
//  DCGroupEncoder.swift
//  JXLEncoder
//
//  Port of `WriteDCGroup`, `WriteDCTokens` and `WriteACMetadataTokens` from
//  libjxl-tiny's encoder/enc_frame.cc.
//
//  A DC group carries the DC image plus the per-block control fields: the
//  chroma-from-luma maps, the AC strategy, the quant field and the edge-
//  preserving-filter sharpness. All of them are gradient-predicted and coded
//  with the same modular entropy code.
//

/// Per-block state a DC group encodes alongside the DC image.
public struct DCGroupData: Sendable {
	/// One plane per channel, each at its own subsampled size.
	public var quantDC: [[Int16]]
	public var rawQuantField: [UInt8]
	public let widthInBlocks: Int
	public let heightInBlocks: Int
	public let subsampling: ChromaSubsampling
	/// Per-channel plane dimensions, which differ from the block grid whenever
	/// chroma is subsampled.
	public let planeWidths: [Int]
	public let planeHeights: [Int]
	/// Chroma-from-luma maps, one entry per 64-pixel colour tile. Dropped from
	/// this port's scope, so they stay zero, but they are still transmitted.
	public var ytoxMap: [Int8]
	public var ytobMap: [Int8]
	public let cmapWidth: Int
	public let cmapHeight: Int

	public init(
		widthInBlocks: Int, heightInBlocks: Int,
		subsampling: ChromaSubsampling = .none
	) {
		self.widthInBlocks = widthInBlocks
		self.heightInBlocks = heightInBlocks
		self.subsampling = subsampling
		let widths = (0..<3).map {
			subsampling.dcPlaneSize(channel: $0, blocks: widthInBlocks, vertical: false)
		}
		let heights = (0..<3).map {
			subsampling.dcPlaneSize(channel: $0, blocks: heightInBlocks, vertical: true)
		}
		planeWidths = widths
		planeHeights = heights
		quantDC = (0..<3).map {
			[Int16](repeating: 0, count: widths[$0] * heights[$0])
		}
		rawQuantField = [UInt8](repeating: 1, count: widthInBlocks * heightInBlocks)
		cmapWidth = Geometry.divCeil(widthInBlocks * Geometry.blockDim, 64)
		cmapHeight = Geometry.divCeil(heightInBlocks * Geometry.blockDim, 64)
		ytoxMap = [Int8](repeating: 0, count: cmapWidth * cmapHeight)
		ytobMap = [Int8](repeating: 0, count: cmapWidth * cmapHeight)
	}
}

public enum DCGroupEncoder {
	/// Gradient-predicts one plane and emits the residuals.
	///
	/// The neighbour fallbacks are deliberately asymmetric, matching the
	/// reference: at the left edge `left` borrows the pixel above, and `topLeft`
	/// borrows `left`.
	static func writePlane(
		values: (Int, Int) -> Int32,
		width: Int,
		height: Int,
		context: (Int) -> UInt32,
		writer: inout SectionWriter
	) {
		for y in 0..<height {
			for x in 0..<width {
				let left: Int32 =
					x > 0 ? values(x - 1, y) : (y > 0 ? values(x, y - 1) : 0)
				let top: Int32 = y > 0 ? values(x, y - 1) : left
				let topLeft: Int32 = (x > 0 && y > 0) ? values(x - 1, y - 1) : left
				let guess = DCPredictor.clampedGradient(
					top: top, left: left, topLeft: topLeft)
				let gradientProperty = clamp1(
					DCPredictor.gradRangeMid + Int(top) + Int(left)
						- Int(topLeft),
					DCPredictor.gradRangeMin, DCPredictor.gradRangeMax)
				let residual = values(x, y) &- guess
				writer.write(
					token: Token(
						context: context(gradientProperty),
						value: packSigned(residual)), )
			}
		}
	}

	static func writeDCTokens(
		data: DCGroupData, writer: inout SectionWriter
	) {
		// Channel order is 1, 0, 2, which is also modular channel order 0, 1, 2 —
		// the DC stream swaps the first two, matching `c < 2 ? c ^ 1 : c`.
		for channel in ACTokenizer.channelOrder {
			let plane = data.quantDC[channel]
			let width = data.planeWidths[channel]
			writePlane(
				values: { x, y in Int32(plane[y * width + x]) },
				width: width,
				height: data.planeHeights[channel],
				context: { UInt32(DCPredictor.gradientContextLut[$0]) },
				writer: &writer)
		}
	}

	static func writeACMetadataTokens(
		data: DCGroupData, writer: inout SectionWriter
	) {
		// Chroma-from-luma maps use fixed contexts rather than the gradient LUT.
		for c in 0..<2 {
			let map = c == 0 ? data.ytoxMap : data.ytobMap
			writePlane(
				values: { x, y in Int32(map[y * data.cmapWidth + x]) },
				width: data.cmapWidth,
				height: data.cmapHeight,
				context: { _ in UInt32(2 - c) },
				writer: &writer)
		}

		// AC strategy. Every block is DCT8 here, so the value is always zero, but
		// the context still tracks the previous block.
		var left: Int32 = 0
		for _ in 0..<data.heightInBlocks {
			for _ in 0..<data.widthInBlocks {
				let current = Int32(ACTokenizer.dct8StrategyCode)
				let context: UInt32 =
					left > 11 ? 7 : (left > 5 ? 8 : (left > 3 ? 9 : 10))
				writer.write(
					token: Token(context: context, value: packSigned(current)),
				)
				left = current
			}
		}

		// Quant field, coded as a difference from the previous block. The
		// reference seeds `left` with the first block's *strategy code* rather
		// than a quant value; reproduced as-is.
		left = Int32(ACTokenizer.dct8StrategyCode)
		for y in 0..<data.heightInBlocks {
			for x in 0..<data.widthInBlocks {
				let current =
					Int32(data.rawQuantField[y * data.widthInBlocks + x]) - 1
				let residual = current - left
				let context: UInt32 =
					left > 11 ? 3 : (left > 5 ? 4 : (left > 3 ? 5 : 6))
				writer.write(
					token: Token(context: context, value: packSigned(residual)),
				)
				left = current
			}
		}

		// Edge-preserving filter sharpness, constant across the image.
		for _ in 0..<(data.widthInBlocks * data.heightInBlocks) {
			writer.write(token: Token(context: 0, value: packSigned(4)))
		}
	}

	public static func write(
		data: DCGroupData, writer: inout SectionWriter
	) {
		writer.writeRaw(2, 0)  // extra_dc_precision
		writer.writeRaw(4, 3)  // global tree, default weighted predictor, no transforms

		writeDCTokens(data: data, writer: &writer)

		let blockCount = data.widthInBlocks * data.heightInBlocks
		// Every block is a first block with 8x8 only, so the AC block count
		// equals the block count.
		let bitCount =
			blockCount <= 1 ? 0 : (Int.bitWidth - (blockCount - 1).leadingZeroBitCount)
		if bitCount != 0 {
			writer.writeRaw(bitCount, UInt64(blockCount - 1))
		}
		writer.writeRaw(4, 3)  // global tree again, for the control fields

		writeACMetadataTokens(data: data, writer: &writer)
	}
}
