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
	/// With chroma-from-luma dropped, X keeps its own coefficients while B is
	/// decorrelated against the reconstructed Y. These are the `x_factor` and
	/// `b_factor` the reference substitutes when CfL is compiled out.
	static let xFactor: Float = 0
	static let bFactor: Float = 1

	/// DC quantization steps, from encoder/quant_weights.h.
	static let inverseDCQuant: [Float] = [4096.0, 512.0, 256.0]
	static let dcQuant: [Float] = [1.0 / 4096.0, 1.0 / 512.0, 1.0 / 256.0]

	/// B's DC is decorrelated against Y's DC even with chroma-from-luma off:
	/// `kInvDCQuant[2] * kDCQuant[1]` is 0.5.
	static let dcCflFactor: [Float] = [0, 0, inverseDCQuant[2] * dcQuant[1]]

	/// Quantizes one DC coefficient.
	///
	/// The multiply-subtract is written as an explicit fused multiply-add
	/// because clang contracts `a * b - c * d` into `fma(a, b, -(c * d))` by
	/// default while Swift never contracts. Rounding both products separately
	/// differs in the last bit, which is enough to flip a value sitting on a
	/// rounding boundary — it cost exactly one block in one 44 800-block DC
	/// group before this was matched.
	///
	/// Rounding is ties-away-from-zero (`std::round`), unlike the ties-to-even
	/// used when quantizing AC coefficients.
	static func quantizedDC(
		coefficient: Float, inverseFactor: Float, yDC: Int16, cflFactor: Float
	) -> Int16 {
		let correction = Float(yDC) * cflFactor
		let value = (-correction).addingProduct(coefficient, inverseFactor)
		return Int16(value.rounded(.toNearestOrAwayFromZero))
	}

	/// Computes one group's quantized AC coefficients and fills in its DC
	/// image, without tokenizing — tokenization needs the frame-global
	/// coefficient order (`CoeffOrder`), which in turn needs every group's
	/// coefficients counted first, so the two are separate passes over the
	/// same per-block computation.
	///
	/// `xyb` is the padded XYB image for the group; `quantField` holds one value
	/// per block in group-raster order. `quantDC` receives one DC value per
	/// block per channel — DC is just the lowest-frequency coefficient of the
	/// same transform, so this pass produces both outputs. Returns one flat
	/// array of quantized coefficients per channel, block-major
	/// (`coefficients[channel][block * 64 ..< block * 64 + 64]`).
	public static func computeGroup(
		xyb: PaddedStripe,
		widthInBlocks: Int,
		heightInBlocks: Int,
		quantField: [UInt8],
		scale: Float,
		scaleDC: Float,
		xQuantMatrixScale: UInt32,
		quantDC: inout [[Int16]]
	) -> [[Int32]] {
		computeGroup(
			planes: xyb.channelPlanes,
			widthInBlocks: widthInBlocks,
			heightInBlocks: heightInBlocks,
			subsampling: .none,
			quantField: quantField,
			scale: scale,
			scaleDC: scaleDC,
			xQuantMatrixScale: xQuantMatrixScale,
			quantDC: &quantDC)
	}

	/// As above, with per-channel resolutions.
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
		scaleDC: Float,
		xQuantMatrixScale: UInt32,
		quantDC: inout [[Int16]]
	) -> [[Int32]] {
		let inverseFactor = inverseDCQuant.map { $0 * scaleDC }
		// The X channel's quant matrix is scaled by distance-dependent steps.
		let xMatrixMultiplier = Float.pow(1.25, Float(xQuantMatrixScale) - 2.0)

		let channelWidths = (0..<3).map {
			subsampling.blocksAcross(channel: $0, fullWidthInBlocks: widthInBlocks)
		}
		let channelHeights = (0..<3).map {
			subsampling.blocksDown(channel: $0, fullHeightInBlocks: heightInBlocks)
		}
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
					sy[channel] * channelWidths[channel] + sx[channel]
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
				coefficients[1].replaceSubrange(yBase..<yBase + DCT.blockSize, with: yQuantized)

				// For DCT8 the DC is simply the lowest-frequency coefficient.
				// `std::round` here rounds ties away from zero, unlike the
				// half-to-even rounding the AC quantizer uses.
				quantDC[1][index(1)] = Int16(
					(inverseFactor[1] * yCoefficients[0])
						.rounded(.toNearestOrAwayFromZero))

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
					let factor = channel == 0 ? xFactor : bFactor
					for k in 0..<DCT.blockSize {
						blockCoefficients[k] = blockCoefficients[k].addingProduct(
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
						channelBase..<channelBase + DCT.blockSize, with: quantized)

					// Taken from the decorrelated coefficients, then B has Y's
					// DC subtracted on top.
					//
					// Written as an explicit fused multiply-add because clang
					// contracts `a * b - c * d` into `fma(a, b, -(c * d))` by
					// default, while Swift never contracts. Computing both
					// products separately differs in the last bit, which is
					// enough to flip a value sitting on a rounding boundary.
					quantDC[channel][index(channel)] = quantizedDC(
						coefficient: blockCoefficients[0],
						inverseFactor: inverseFactor[channel],
						yDC: quantDC[1][index(1)],
						cflFactor: dcCflFactor[channel])
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
					let index =
						sy[channel] * channelWidths[channel] + sx[channel]
					let base = index * DCT.blockSize
					ACTokenizer.writeBlock(
						quantized: coefficients[channel][base..<base + DCT.blockSize],
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
	/// Encodes one group from a JPEG's own quantized coefficients.
	///
	/// The pixel path's middle is all absent here: no forward DCT, no
	/// quantization, and no decorrelation of X and B against Y. The JPEG already
	/// quantized these values and a transcode must not touch them — libjxl
	/// applies chroma-from-luma only behind `force_cfl_jpeg_recompression`, which
	/// is off by default and out of scope here.
	///
	/// The block walk is the same as the pixel path's, including how a subsampled
	/// channel codes only where its own grid aligns.
	public static func encodeJPEG(
		transcode: JPEGTranscode,
		blockX0: Int,
		blockY0: Int,
		widthInBlocks: Int,
		heightInBlocks: Int,
		quantDC: inout [[Int16]],
		/// Non-nil switches every block to the adaptive per-image context
		/// assignment; nil keeps the fixed formula `ACContext.blockContext`
		/// already computes, unchanged. The static-table (`optimizeCodes:
		/// false`) path always passes nil — this adaptive scheme has no
		/// meaning without per-image optimisation to carry it.
		blockContextMap: JPEGBlockContextMap.Result?,
		order: [[Int]],
		writer: inout SectionWriter
	) {
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

					let block = transcode.block(
						channel: channel, x: sourceX, y: sourceY)
					quantized[channel] = block

					let localX = subsampling.subsampledX(
						channel: channel, blockX: bx)
					let localY = subsampling.subsampledY(
						channel: channel, blockY: by)
					quantDC[channel][localY * channelWidths[channel] + localX] =
						Int16(clamping: block[0])
				}

				// Every channel's context at this position shares the same
				// bucket: it comes from luma's own DC value, read once here,
				// not resampled per channel (confirmed at the source —
				// `row_qdc[bx]` is indexed by the full-resolution position).
				let dcBucket = blockContextMap?.bucket(
					dc: quantized[1].isEmpty ? 0 : quantized[1][0])

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
								channel: channel, dcBucket: dcBucket),
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

	/// Counts zero coefficients per channel over one group's worth of a JPEG
	/// transcode's already-parsed coefficients, feeding `CoeffOrder`'s
	/// frame-global statistics. Unlike the pixel path, a JPEG's coefficients
	/// are already fully materialized (`transcode.block`), so no separate
	/// compute pass is needed here — this mirrors `encodeJPEG`'s block
	/// selection (grayscale skip, MCU-padding bounds) read-only, ahead of the
	/// real per-group loop that tokenizes.
	static func countZerosJPEG(
		transcode: JPEGTranscode,
		blockX0: Int,
		blockY0: Int,
		widthInBlocks: Int,
		heightInBlocks: Int,
		into counts: inout [CoeffOrder.ZeroCounts]
	) {
		let subsampling = transcode.subsampling
		for by in 0..<heightInBlocks {
			for bx in 0..<widthInBlocks {
				for channel in 0..<3 {
					guard
						subsampling.codesBlock(
							channel: channel, blockX: blockX0 + bx,
							blockY: blockY0 + by),
						!(transcode.isGrayscale && channel != 1)
					else { continue }

					let sourceX = subsampling.subsampledX(
						channel: channel, blockX: blockX0 + bx)
					let sourceY = subsampling.subsampledY(
						channel: channel, blockY: blockY0 + by)
					let component = transcode.component(channel)
					guard
						sourceX < component.blocksPerLine,
						sourceY < component.blocksPerColumn
					else { continue }

					counts[channel].add(
						transcode.block(channel: channel, x: sourceX, y: sourceY)[...])
				}
			}
		}
	}
}
