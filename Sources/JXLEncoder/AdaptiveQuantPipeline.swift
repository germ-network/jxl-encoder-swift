//
//  AdaptiveQuantPipeline.swift
//  JXLEncoder
//
//  Walks the stripe/tile geometry to produce the whole-image quant field,
//  mirroring the loop in encoder/enc_frame.cc.
//

public enum AdaptiveQuantPipeline {
	/// Converts a padded stripe of linear samples to planar XYB.
	static func toXYB(_ stripe: PaddedStripe) -> PaddedStripe {
		let count = stripe.width * stripe.height
		var interleaved = [Float](repeating: 0, count: count * 3)
		for i in 0..<count {
			for c in 0..<3 { interleaved[i * 3 + c] = stripe.planes[c][i] }
		}
		let xyb = XYB.toXYB(linearRGB: interleaved, pixelCount: count)
		return PaddedStripe(
			width: stripe.width, height: stripe.height,
			planes: [xyb.x, xyb.y, xyb.b])
	}

	/// Per-block quantization field for a whole image, in block-raster order.
	///
	/// Stripes are walked in order because the reference notes context
	/// dependence between them; only whole groups may run concurrently.
	public static func quantField(
		linearInterleaved: [Float],
		width: Int,
		height: Int,
		distance: Float,
		inverseScale: Float
	) -> [UInt8] {
		let dim = ImageDim(width: width, height: height)
		var field = [UInt8](repeating: 0, count: dim.widthInBlocks * dim.heightInBlocks)

		for gx in 0..<dim.widthInGroups {
			for ty in 0..<dim.heightInTiles {
				let rect = dim.stripeRect(groupX: gx, tileY: ty)
				let padded = PlaneBuffer.copyAndPad(
					source: linearInterleaved, sourceWidth: width, rect: rect)
				let xyb = toXYB(padded)

				let blocksAcross = padded.width / Geometry.blockDim
				let blocksDown = padded.height / Geometry.blockDim
				let tilesAcross = Geometry.divCeil(padded.width, Geometry.tileDim)

				for tx in 0..<tilesAcross {
					let tileRect = Rect(
						x0: tx * Geometry.tileDimInBlocks, y0: 0,
						maxWidth: Geometry.tileDimInBlocks,
						maxHeight: Geometry.tileDimInBlocks,
						xEnd: blocksAcross, yEnd: blocksDown)
					let aqMap = AdaptiveQuant.computeTile(
						stripe: xyb, rect: tileRect, distance: distance)
					let raw = AdaptiveQuant.rawQuantField(
						aqMap: aqMap, inverseScale: inverseScale)

					for y in 0..<tileRect.height {
						let by = ty * Geometry.tileDimInBlocks + y
						guard by < dim.heightInBlocks else { continue }
						for x in 0..<tileRect.width {
							let bx =
								gx * Geometry.groupDimInBlocks
								+ tileRect.x0 + x
							guard bx < dim.widthInBlocks else {
								continue
							}
							field[by * dim.widthInBlocks + bx] =
								raw[y * tileRect.width + x]
						}
					}
				}
			}
		}
		return field
	}
}
