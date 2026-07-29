//
//  AdaptiveQuantTile.swift
//  JXLEncoder
//
//  The tile driver for the adaptive quant field: local difference map,
//  4x subsampling, fuzzy erosion, and the per-block modulation chain.
//  Continues the port of encoder/enc_adaptive_quantization.cc.
//

extension AdaptiveQuant {
	static let acQuant: Float = 0.8294
	static let matchGammaOffset: Float = 0.019
	static let xMul: Float = 23.426_802_998_210_313

	/// Keeps the four smallest values seen so far, in order.
	static func storeMin4(_ v: Float, _ m: inout (Float, Float, Float, Float)) {
		guard v < m.3 else { return }
		if v < m.0 {
			m.3 = m.2
			m.2 = m.1
			m.1 = m.0
			m.0 = v
		} else if v < m.1 {
			m.3 = m.2
			m.2 = m.1
			m.1 = v
		} else if v < m.2 {
			m.3 = m.2
			m.2 = v
		} else {
			m.3 = v
		}
	}

	/// Looks for smooth areas near a degradation; if the surroundings are
	/// generally smooth, masking is suppressed. Output is downsampled 2x, with
	/// each output accumulating the four inputs of its 2x2 source.
	static func fuzzyErosion(
		fromRect: Rect,
		source: [Float], sourceWidth: Int, sourceHeight: Int,
		destination: inout [Float], destinationWidth: Int
	) {
		for fy in 0..<fromRect.height {
			let y = fy + fromRect.y0
			let ym1 = y >= 1 ? y - 1 : y
			let yp1 = y + 1 < sourceHeight ? y + 1 : y
			let rowTop = ym1 * sourceWidth
			let row = y * sourceWidth
			let rowBottom = yp1 * sourceWidth
			let rowOut = (fy / 2) * destinationWidth

			for fx in 0..<fromRect.width {
				let x = fx + fromRect.x0
				let xm1 = x >= 1 ? x - 1 : x
				let xp1 = x + 1 < sourceWidth ? x + 1 : x

				var m = (
					source[row + x], source[row + xm1], source[row + xp1],
					source[rowTop + xm1]
				)
				// Sort the first four.
				if m.0 > m.1 { swap(&m.0, &m.1) }
				if m.0 > m.2 { swap(&m.0, &m.2) }
				if m.0 > m.3 { swap(&m.0, &m.3) }
				if m.1 > m.2 { swap(&m.1, &m.2) }
				if m.1 > m.3 { swap(&m.1, &m.3) }
				if m.2 > m.3 { swap(&m.2, &m.3) }
				// The remaining five of the 3x3 neighbourhood.
				storeMin4(source[rowTop + x], &m)
				storeMin4(source[rowTop + xp1], &m)
				storeMin4(source[rowBottom + xm1], &m)
				storeMin4(source[rowBottom + x], &m)
				storeMin4(source[rowBottom + xp1], &m)

				let k: Float = 0.05
				let v = k * source[row + x] + k * m.0 + k * m.1 + k * m.2 + k * m.3
				if fx % 2 == 0 && fy % 2 == 0 {
					destination[rowOut + fx / 2] = v
				} else {
					destination[rowOut + fx / 2] += v
				}
			}
		}
	}

	/// Computes the quant field for one tile of a padded XYB stripe.
	///
	/// `rect` is in blocks within the stripe. The analysis window is extended by
	/// 4 pixels on every side that is not an image edge, which is why this
	/// cannot be hoisted to whole-plane processing.
	static func computeTile(
		stripe: PaddedStripe,
		rect: Rect,
		distance: Float
	) -> [Float] {
		let xsize = stripe.width
		let ysize = stripe.height
		let scale = acQuant / distance

		var yStart = rect.y0 * 8
		var yEnd = yStart + rect.height * 8
		var x0 = rect.x0 * 8
		var x1 = x0 + rect.width * 8
		if x0 != 0 { x0 -= 4 }
		if x1 != xsize { x1 += 4 }
		if yStart != 0 { yStart -= 4 }
		if yEnd != ysize { yEnd += 4 }

		let preErosionWidth = (x1 - x0) / 4
		let preErosionHeight = (yEnd - yStart) / 4
		var preErosion = [Float](repeating: 0, count: preErosionWidth * preErosionHeight)
		var diffBuffer = [Float](repeating: 0, count: x1 - x0)

		let planeY = stripe.planes[1]
		let planeX = stripe.planes[0]

		for y in yStart..<yEnd {
			let y2 = y + 1 < ysize ? y + 1 : y
			let y1 = y > 0 ? y - 1 : y
			let row = y * xsize
			let row1 = y1 * xsize
			let row2 = y2 * xsize

			// The reference sums the neighbourhood in two different orders: its
			// scalar edge path adds ((down + up) + left) + right, while its
			// vector path adds (right + left) + (down + up). Float addition is
			// not associative, so both orders must be reproduced, over exactly
			// the same ranges, or edge pixels drift.
			func accumulate(_ x: Int, _ diff: Float) {
				if y % 4 != 0 {
					diffBuffer[x - x0] += diff
				} else {
					diffBuffer[x - x0] = diff
				}
			}

			func scalarPixel(_ x: Int) {
				let x2 = x + 1 < xsize ? x + 1 : x
				let xm1 = x > 0 ? x - 1 : x

				let base =
					0.25
					* (planeY[row2 + x] + planeY[row1 + x] + planeY[row + xm1]
						+ planeY[row + x2])
				let gammac = FastMath.ratioOfDerivativesOfCubicRootToSimpleGamma(
					planeY[row + x] + matchGammaOffset, invert: false)
				var diff = gammac * (planeY[row + x] - base)
				diff *= diff

				let baseX =
					0.25
					* (planeX[row2 + x] + planeX[row1 + x] + planeX[row + xm1]
						+ planeX[row + x2])
				var diffX = gammac * (planeX[row + x] - baseX)
				diffX *= diffX
				diff = diff.addingProduct(xMul, diffX)
				accumulate(x, FastMath.maskingSqrt(diff))
			}

			func vectorPixel(_ x: Int) {
				let base =
					0.25
					* ((planeY[row + x + 1] + planeY[row + x - 1])
						+ (planeY[row2 + x] + planeY[row1 + x]))
				let gammac = FastMath.ratioOfDerivativesOfCubicRootToSimpleGamma(
					planeY[row + x] + matchGammaOffset, invert: false)
				var diff = gammac * (planeY[row + x] - base)
				diff *= diff

				let baseX =
					0.25
					* ((planeX[row + x + 1] + planeX[row + x - 1])
						+ (planeX[row2 + x] + planeX[row1 + x]))
				var diffX = gammac * (planeX[row + x] - baseX)
				diffX *= diffX
				diff = diff.addingProduct(xMul, diffX)
				accumulate(x, FastMath.maskingSqrt(diff))
			}

			var x = x0
			// The leftmost pixel of the image has no left neighbour to load.
			if x0 == 0 {
				scalarPixel(x0)
				x += 1
			}
			while x + 1 + lanes < x1 {
				for lane in 0..<lanes { vectorPixel(x + lane) }
				x += lanes
			}
			while x < x1 {
				scalarPixel(x)
				x += 1
			}

			if y % 4 == 3 {
				let rowOut = ((y - yStart) / 4) * preErosionWidth
				for x in 0..<preErosionWidth {
					preErosion[rowOut + x] =
						(diffBuffer[x * 4] + diffBuffer[x * 4 + 1]
							+ diffBuffer[x * 4 + 2]
							+ diffBuffer[x * 4 + 3]) * 0.25
				}
			}
		}

		var aqMap = [Float](repeating: 0, count: rect.width * rect.height)
		let fromRect = Rect(
			x0: x0 % 8 == 0 ? 0 : 1,
			y0: yStart % 8 == 0 ? 0 : 1,
			width: rect.width * 2,
			height: rect.height * 2)
		fuzzyErosion(
			fromRect: fromRect,
			source: preErosion, sourceWidth: preErosionWidth,
			sourceHeight: preErosionHeight,
			destination: &aqMap, destinationWidth: rect.width)

		perBlockModulations(
			butteraugliTarget: distance,
			stripe: stripe,
			scale: scale,
			rect: rect,
			aqMap: &aqMap)
		return aqMap
	}

	static func perBlockModulations(
		butteraugliTarget: Float,
		stripe: PaddedStripe,
		scale: Float,
		rect: Rect,
		aqMap: inout [Float]
	) {
		let baseLevel = 0.5 * scale
		let dampenRampStart: Float = 7.0
		let dampenRampEnd: Float = 14.0
		var dampen: Float = 1.0
		if butteraugliTarget >= dampenRampStart {
			dampen =
				1.0
				- ((butteraugliTarget - dampenRampStart)
					/ (dampenRampEnd - dampenRampStart))
			if dampen < 0 { dampen = 0 }
		}
		let mul = scale * dampen
		let add = (1.0 - dampen) * baseLevel

		let stride = stripe.width
		for iy in rect.y0..<(rect.y0 + rect.height) {
			let y = iy * 8
			let outRow = (iy - rect.y0) * rect.width
			for ix in rect.x0..<(rect.x0 + rect.width) {
				let x = ix * 8
				var outValue = aqMap[outRow + (ix - rect.x0)]
				outValue = computeMask(outValue)
				outValue = hfModulation(
					x: x, y: y, plane: stripe.planes[1], stride: stride,
					outValue: outValue)
				outValue = colorModulation(
					x: x, y: y,
					planeX: stripe.planes[0], planeY: stripe.planes[1],
					planeB: stripe.planes[2], stride: stride,
					butteraugliTarget: butteraugliTarget, outValue: outValue)
				outValue = gammaModulation(
					x: x, y: y, planeX: stripe.planes[0],
					planeY: stripe.planes[1],
					stride: stride, outValue: outValue)
				// Everything above modulates an exponent; the field itself is
				// multiplicative.
				aqMap[outRow + (ix - rect.x0)] =
					FastMath.pow2(outValue * 1.442_695_041) * mul + add
			}
		}
	}

	/// Quantizes the field to the per-block integers the encoder stores.
	static func rawQuantField(aqMap: [Float], inverseScale: Float) -> [UInt8] {
		aqMap.map { UInt8(clamp1(Int($0 * inverseScale + 0.5), 1, 255)) }
	}
}
