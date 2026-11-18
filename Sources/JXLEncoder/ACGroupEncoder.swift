//
//  ACGroupEncoder.swift
//  JXLEncoder
//
//  Port of the per-block body of `WriteACGroup` from
//  libjxl-tiny's encoder/enc_group.cc, for the 8x8-only path.
//
//  Only tokens reach the bit writer; DC is carried separately by the DC image.
//

public enum ACGroupEncoder {

	/// `-e 4` never computes a non-default color-correlation map (both
	/// `CfLHeuristics` gates are stricter than `kCheetah` — see
	/// `FrameAssembly.writeColorCorrelationDC`), so these are full libjxl's
	/// own default `YtoXRatio(0)`/`YtoBRatio(0)`, not values this port
	/// invented in place of a dropped feature: X keeps its own coefficients
	/// (`base_correlation_x_ = 0`), B is decorrelated against the
	/// reconstructed Y at the reference's default ratio
	/// (`base_correlation_b_ = kYToBRatio = 1`).
	static let xFactor: Float = 0
	static let bFactor: Float = 1

	/// A channel's flat index into a per-channel, block-major array — both
	/// `computeGroup`'s coefficient storage and `tokenizeGroup`'s read of it
	/// — given that channel's own subsampled block position. Shared so the
	/// two functions' block walks can't independently drift on how they
	/// address the same storage.
	static func flatBlockIndex(channel: Int, sx: [Int], sy: [Int], channelWidths: [Int]) -> Int
	{
		sy[channel] * channelWidths[channel] + sx[channel]
	}

	/// Computes one group's quantized AC coefficients and extracts raw DC
	/// coefficients, without tokenizing — tokenization needs the frame-global
	/// coefficient order (`CoeffOrder`), which in turn needs every group's
	/// coefficients counted first, so the two are separate passes over the
	/// same per-block computation.
	///
	/// `xyb` is the padded XYB image for the group; `quantField` holds one value
	/// per block in group-raster order. `rawDC` has one block-raster Float plane
	/// per channel, each `widthInBlocks × heightInBlocks`, and receives pre-CfL
	/// DC coefficients for later full-DC-group preparation. Returns one flat
	/// array of quantized coefficients per channel, block-major
	/// (`coefficients[channel][block * 64 ..< block * 64 + 64]`).
	public static func computeGroup(
		xyb: PaddedStripe,
		widthInBlocks: Int,
		heightInBlocks: Int,
		quantField: [UInt8],
		scale: Float,
		xQuantMatrixScale: UInt32,
		rawDC: inout [[Float]]
	) -> [[Int32]] {
		computeGroup(
			planes: xyb.channelPlanes,
			widthInBlocks: widthInBlocks,
			heightInBlocks: heightInBlocks,
			subsampling: .none,
			quantField: quantField,
			scale: scale,
			xQuantMatrixScale: xQuantMatrixScale,
			rawDC: &rawDC)
	}

	/// As above, with per-channel resolutions. Each `rawDC[channel]` plane has
	/// `subsampling.blocksAcross(channel:fullWidthInBlocks:)` columns and
	/// `subsampling.blocksDown(channel:fullHeightInBlocks:)` rows, in block-raster
	/// order.
	///
	/// The loop runs over the full-resolution block grid; a subsampled channel
	/// codes only where its own grid aligns, which is how the format interleaves
	/// channels of different resolutions in one scan. With 4:4:4 every channel
	/// codes every block and this reduces to the simple case.
	public static func computeGroup(
		planes: ChannelPlanes,
		widthInBlocks: Int,
		heightInBlocks: Int,
		subsampling: ChromaSubsampling,
		quantField: [UInt8],
		scale: Float,
		xQuantMatrixScale: UInt32,
		rawDC: inout [[Float]]
	) -> [[Int32]] {
		// The X channel's quant matrix is scaled by distance-dependent steps.
		let xMatrixMultiplier = Float.pow(1.25, Float(xQuantMatrixScale) - 2.0)

		let channelWidths = (0..<3).map {
			subsampling.blocksAcross(channel: $0, fullWidthInBlocks: widthInBlocks)
		}
		let channelHeights = (0..<3).map {
			subsampling.blocksDown(channel: $0, fullHeightInBlocks: heightInBlocks)
		}
		precondition(rawDC.count == 3)
		precondition(
			(0..<3).allSatisfy {
				rawDC[$0].count == channelWidths[$0] * channelHeights[$0]
			})
		var coefficients: [[Int32]] = (0..<3).map {
			[Int32](
				repeating: 0,
				count: channelWidths[$0] * channelHeights[$0] * DCT.blockSize)
		}

		for by in 0..<heightInBlocks {
			for bx in 0..<widthInBlocks {
				let quant = Int32(quantField[by * widthInBlocks + bx])

				// Index each channel on its own grid; identical to (bx, by) at
				// 4:4:4.
				let sx = (0..<3).map {
					subsampling.subsampledX(channel: $0, blockX: bx)
				}
				let sy = (0..<3).map {
					subsampling.subsampledY(channel: $0, blockY: by)
				}
				func index(_ channel: Int) -> Int {
					flatBlockIndex(
						channel: channel, sx: sx, sy: sy,
						channelWidths: channelWidths)
				}

				// Y first: its reconstruction is what X and B decorrelate against.
				let yCoefficients = DCT.forward8x8(
					pixels: planes.planes[1], stride: planes.widths[1],
					originX: sx[1] * DCT.blockDim, originY: sy[1] * DCT.blockDim
				)
				let (yQuantized, yReconstructed) = Quantizer.roundtripYBlockAC(
					coefficients: yCoefficients[...], quant: quant, scale: scale
				)
				let yBase = index(1) * DCT.blockSize
				coefficients[1].replaceSubrange(
					yBase..<yBase + DCT.blockSize, with: yQuantized)

				rawDC[1][index(1)] = yCoefficients[0]

				for channel in [0, 2] {
					// Without this guard a subsampled chroma block would be
					// recomputed once per full-resolution position it spans, each
					// time against a different luma DC, and the last write would
					// silently win.
					guard
						subsampling.codesBlock(
							channel: channel, blockX: bx, blockY: by)
					else { continue }

					var blockCoefficients = DCT.forward8x8(
						pixels: planes.planes[channel],
						stride: planes.widths[channel],
						originX: sx[channel] * DCT.blockDim,
						originY: sy[channel] * DCT.blockDim)
					rawDC[channel][index(channel)] = blockCoefficients[0]
					let factor = channel == 0 ? xFactor : bFactor
					for k in 0..<DCT.blockSize {
						blockCoefficients[k] = blockCoefficients[k]
							.addingProduct(
								-factor, yReconstructed[k])
					}
					let quantized = Quantizer.quantizeBlockAC(
						coefficients: blockCoefficients[...],
						channel: channel,
						inverseMatrix: QuantMatrices.inverseMatrix(
							channel: channel),
						quant: quant,
						scale: scale,
						matrixMultiplier: channel == 0
							? xMatrixMultiplier : 1.0)
					let channelBase = index(channel) * DCT.blockSize
					coefficients[channel].replaceSubrange(
						channelBase..<channelBase + DCT.blockSize,
						with: quantized)
				}
			}
		}
		return coefficients
	}

	/// Tokenizes a group's already-computed coefficients (from `computeGroup`)
	/// using the frame-global coefficient order.
	///
	/// Mirrors `computeGroup`'s block walk exactly, since the two must visit
	/// blocks in the same sequence for `index(channel)` to address the same
	/// storage — kept as a literal second loop rather than folded into
	/// `computeGroup` so the coefficient order can be computed from every
	/// group's output before any group tokenizes.
	public static func tokenizeGroup(
		coefficients: [[Int32]],
		widthInBlocks: Int,
		heightInBlocks: Int,
		subsampling: ChromaSubsampling,
		order: [[Int]],
		writer: inout SectionWriter
	) {
		let channelWidths = (0..<3).map {
			subsampling.blocksAcross(channel: $0, fullWidthInBlocks: widthInBlocks)
		}
		var nonZeros: [[UInt8]] = (0..<3).map {
			[UInt8](repeating: 0, count: channelWidths[$0])
		}
		var nonZerosAbove: [[UInt8]?] = [nil, nil, nil]

		for by in 0..<heightInBlocks {
			var codedThisRow = [false, false, false]
			for bx in 0..<widthInBlocks {
				let sx = (0..<3).map {
					subsampling.subsampledX(channel: $0, blockX: bx)
				}
				let sy = (0..<3).map {
					subsampling.subsampledY(channel: $0, blockY: by)
				}
				for channel in ACTokenizer.channelOrder {
					// A subsampled channel has no block here; the full-resolution
					// position it would occupy belongs to an earlier block it
					// already covered.
					guard
						subsampling.codesBlock(
							channel: channel, blockX: bx, blockY: by)
					else { continue }
					codedThisRow[channel] = true
					let index = flatBlockIndex(
						channel: channel, sx: sx, sy: sy,
						channelWidths: channelWidths)
					let base = index * DCT.blockSize
					ACTokenizer.writeBlock(
						quantized: coefficients[channel][
							base..<base + DCT.blockSize],
						channel: channel,
						blockX: sx[channel],
						order: order[channel],
						nonZeroRow: &nonZeros[channel],
						nonZeroRowAbove: nonZerosAbove[channel],
						writer: &writer)
				}
			}
			// Only advance a channel's "row above" when it actually coded one,
			// so a vertically subsampled channel predicts from its own previous
			// row rather than the row it skipped.
			for channel in 0..<3 where codedThisRow[channel] {
				nonZerosAbove[channel] = nonZeros[channel]
			}
		}
	}
}

extension ACGroupEncoder {
	/// Writes raw quantized JPEG blocks through the nonthrowing primitive.
	/// The JPEG frame path uses the required-map overload below so its
	/// coefficient-order and tokenization walks share the populated residuals.
	///
	/// The block walk is the same as the pixel path's, including how a subsampled
	/// channel codes only where its own grid aligns.
	public static func encodeJPEG(
		transcode: JPEGTranscode,
		blockX0: Int,
		blockY0: Int,
		widthInBlocks: Int,
		heightInBlocks: Int,
		quantDC: inout [[Int32]],
		/// Non-nil switches every block to the adaptive per-image context
		/// assignment; nil keeps the fixed formula `ACContext.blockContext`
		/// already computes, unchanged. The static-table (`optimizeCodes:
		/// false`) path always passes nil — this adaptive scheme has no
		/// meaning without per-image optimisation to carry it.
		blockContextMap: JPEGBlockContextMap.Result?,
		order: [[Int]],
		writer: inout SectionWriter
	) {
		encodeJPEGUsingBlocks(
			transcode: transcode, blockX0: blockX0, blockY0: blockY0,
			widthInBlocks: widthInBlocks, heightInBlocks: heightInBlocks,
			quantDC: &quantDC, blockContextMap: blockContextMap, order: order,
			writer: &writer
		) { channel, x, y in transcode.block(channel: channel, x: x, y: y) }
	}

	static func encodeJPEGUsingBlocks(
		transcode: JPEGTranscode,
		blockX0: Int,
		blockY0: Int,
		widthInBlocks: Int,
		heightInBlocks: Int,
		quantDC: inout [[Int32]],
		blockContextMap: JPEGBlockContextMap.Result?,
		order: [[Int]],
		writer: inout SectionWriter,
		blockProvider: (Int, Int, Int) throws -> [Int32]
	) rethrows {
		let subsampling = transcode.subsampling
		// Nonzero-neighbour bookkeeping runs over the coded block grid, which
		// rounds up; the DC planes use the decoder's floor. They are separate
		// numbers and mixing them misplaces DC on an odd block count.
		let channelWidths = (0..<3).map {
			subsampling.blocksAcross(channel: $0, fullWidthInBlocks: widthInBlocks)
		}
		var nonZeros: [[UInt8]] = (0..<3).map {
			[UInt8](repeating: 0, count: channelWidths[$0])
		}
		var nonZerosAbove: [[UInt8]?] = [nil, nil, nil]

		for by in 0..<heightInBlocks {
			var codedThisRow = [false, false, false]
			for bx in 0..<widthInBlocks {
				var quantized = [[Int32]](repeating: [], count: 3)

				for channel in 0..<3 {
					guard
						subsampling.codesBlock(
							channel: channel, blockX: blockX0 + bx,
							blockY: blockY0 + by)
					else { continue }

					// A grey source has nothing to say about chroma; repeating
					// luma there decodes as a colour cast.
					if transcode.isGrayscale && channel != 1 {
						quantized[channel] = [Int32](
							repeating: 0, count: 64)
						continue
					}

					// The group's position in the image, mapped onto this
					// channel's own subsampled grid.
					let sourceX = subsampling.subsampledX(
						channel: channel, blockX: blockX0 + bx)
					let sourceY = subsampling.subsampledY(
						channel: channel, blockY: blockY0 + by)
					let component = transcode.component(channel)

					// The MCU grid can run past the image, but never short of it;
					// a missing block would mean the parser and the geometry
					// disagree, so code zeros rather than read out of bounds.
					guard
						sourceX < component.blocksPerLine,
						sourceY < component.blocksPerColumn
					else {
						quantized[channel] = [Int32](
							repeating: 0, count: 64)
						continue
					}

					let block = try blockProvider(channel, sourceX, sourceY)
					quantized[channel] = block

					let localX = subsampling.subsampledX(
						channel: channel, blockX: bx)
					let localY = subsampling.subsampledY(
						channel: channel, blockY: by)
					quantDC[channel][localY * channelWidths[channel] + localX] =
						Int32(
							clamping: transcode.codedDC(
								block[0], channel: channel))
				}

				// Every channel's context at this position shares the same
				// bucket: it comes from luma's own DC value, read once here,
				// not resampled per channel (confirmed at the source —
				// `row_qdc[bx]` is indexed by the full-resolution position).
				let dcBucket = blockContextMap?.bucket(
					dc: quantized[1].isEmpty
						? 0 : transcode.codedDC(quantized[1][0], channel: 1)
				)

				for channel in ACTokenizer.channelOrder {
					guard
						subsampling.codesBlock(
							channel: channel, blockX: blockX0 + bx,
							blockY: blockY0 + by)
					else { continue }
					codedThisRow[channel] = true
					let subsampledX = subsampling.subsampledX(
						channel: channel, blockX: bx)
					if let blockContextMap, let dcBucket {
						ACTokenizer.writeBlockAdaptive(
							quantized: quantized[channel][...],
							blockCategory: blockContextMap.category(
								channel: channel, dcBucket: dcBucket
							),
							numCategories: blockContextMap.numContexts,
							blockX: subsampledX,
							order: order[channel],
							nonZeroRow: &nonZeros[channel],
							nonZeroRowAbove: nonZerosAbove[channel],
							writer: &writer)
					} else {
						ACTokenizer.writeBlock(
							quantized: quantized[channel][...],
							channel: channel,
							blockX: subsampledX,
							order: order[channel],
							nonZeroRow: &nonZeros[channel],
							nonZeroRowAbove: nonZerosAbove[channel],
							writer: &writer)
					}
				}
			}
			for channel in 0..<3 where codedThisRow[channel] {
				nonZerosAbove[channel] = nonZeros[channel]
			}
		}
	}

	static func jpegCoefficientsForOrdering(
		transcode: JPEGTranscode, blockX0: Int, blockY0: Int,
		widthInBlocks: Int, heightInBlocks: Int
	) -> [[Int32]] {
		jpegCoefficientsForOrderingUsingBlocks(
			transcode: transcode, blockX0: blockX0, blockY0: blockY0,
			widthInBlocks: widthInBlocks, heightInBlocks: heightInBlocks
		) { channel, x, y in transcode.block(channel: channel, x: x, y: y) }
	}

	static func jpegCoefficientsForOrderingUsingBlocks(
		transcode: JPEGTranscode, blockX0: Int, blockY0: Int,
		widthInBlocks: Int, heightInBlocks: Int,
		blockProvider: (Int, Int, Int) throws -> [Int32]
	) rethrows -> [[Int32]] {
		precondition(widthInBlocks >= 0 && heightInBlocks >= 0)
		let groupSize = widthInBlocks * heightInBlocks * DCT.blockSize
		var result = (0..<3).map { _ in [Int32]() }
		for channel in 0..<3 { result[channel].reserveCapacity(groupSize) }
		let subsampling = transcode.subsampling
		for by in 0..<heightInBlocks {
			for bx in 0..<widthInBlocks {
				for channel in 0..<3 {
					guard !transcode.isGrayscale || channel == 1 else {
						continue
					}
					guard
						subsampling.codesBlock(
							channel: channel, blockX: blockX0 + bx,
							blockY: blockY0 + by)
					else { continue }

					let sourceX = subsampling.subsampledX(
						channel: channel, blockX: blockX0 + bx)
					let sourceY = subsampling.subsampledY(
						channel: channel, blockY: blockY0 + by)
					let component = transcode.component(channel)
					if sourceX < component.blocksPerLine,
						sourceY < component.blocksPerColumn
					{
						result[channel].append(
							contentsOf: try blockProvider(
								channel, sourceX, sourceY))
					} else {
						result[channel].append(
							contentsOf: repeatElement(
								0, count: DCT.blockSize))
					}
				}
			}
		}
		for channel in 0..<3 {
			result[channel] += repeatElement(
				0, count: max(0, groupSize - result[channel].count))
		}
		return result
	}
}

extension ACGroupEncoder {
	static func encodeJPEG(
		transcode: JPEGTranscode,
		colorCorrelation: DCGroupData,
		colorCorrelationBlockX0: Int, colorCorrelationBlockY0: Int,
		blockX0: Int, blockY0: Int,
		widthInBlocks: Int, heightInBlocks: Int,
		quantDC: inout [[Int32]],
		blockContextMap: JPEGBlockContextMap.Result?,
		order: [[Int]], writer: inout SectionWriter
	) throws {
		try encodeJPEGUsingBlocks(
			transcode: transcode, blockX0: blockX0, blockY0: blockY0,
			widthInBlocks: widthInBlocks, heightInBlocks: heightInBlocks,
			quantDC: &quantDC, blockContextMap: blockContextMap,
			order: order, writer: &writer
		) { channel, x, y in
			let correlation = colorCorrelation.factor(
				channel: channel, x: x, y: y,
				blockX0: colorCorrelationBlockX0,
				blockY0: colorCorrelationBlockY0)
			return try transcode.block(
				channel: channel, x: x, y: y, correlation: correlation)
		}
	}

	static func jpegCoefficientsForOrdering(
		transcode: JPEGTranscode,
		colorCorrelation: DCGroupData,
		colorCorrelationBlockX0: Int, colorCorrelationBlockY0: Int,
		blockX0: Int, blockY0: Int,
		widthInBlocks: Int, heightInBlocks: Int
	) throws -> [[Int32]] {
		try jpegCoefficientsForOrderingUsingBlocks(
			transcode: transcode, blockX0: blockX0, blockY0: blockY0,
			widthInBlocks: widthInBlocks, heightInBlocks: heightInBlocks
		) { channel, x, y in
			let correlation = colorCorrelation.factor(
				channel: channel, x: x, y: y,
				blockX0: colorCorrelationBlockX0,
				blockY0: colorCorrelationBlockY0)
			return try transcode.block(
				channel: channel, x: x, y: y, correlation: correlation)
		}
	}
}

extension DCGroupData {
	fileprivate func factor(channel: Int, x: Int, y: Int, blockX0: Int, blockY0: Int) -> Int8 {
		guard channel != 1, x >= blockX0, y >= blockY0 else { return 0 }
		let mapX = (x - blockX0) / 8
		let mapY = (y - blockY0) / 8
		guard mapX < cmapWidth, mapY < cmapHeight else { return 0 }
		let index = mapY * cmapWidth + mapX
		return channel == 0 ? ytoxMap[index] : ytobMap[index]
	}
}
