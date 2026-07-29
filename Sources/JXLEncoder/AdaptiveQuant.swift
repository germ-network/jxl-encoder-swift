//
//  AdaptiveQuant.swift
//  JXLEncoder
//
//  Port of libjxl-tiny's encoder/enc_adaptive_quantization.cc: the per-block
//  quantization field, derived from psychovisual masking heuristics.
//
//  Two things about this stage are easy to get wrong.
//
//  First, it is computed per *tile* over a window extended by 4 pixels on each
//  side, so the result genuinely depends on how the image is divided. It cannot
//  be computed whole-plane.
//
//  Second, the reference accumulates each 8x8 block's modulation into a SIMD
//  vector and finishes with a horizontal `SumOfLanes`. Float addition is not
//  associative, so that sum depends on the lane count — `cjxl_tiny` itself
//  produces different output when built for a different vector width. The
//  reductions below reproduce the 4-lane arm64 layout (`HWY_CAPPED(float, 8)`
//  is 4 lanes on NEON) and `vaddvq_f32`'s `(a0+a1) + (a2+a3)` order. Written
//  explicitly, this is deterministic on every architecture, which is a
//  stronger guarantee than the reference offers.
//

enum AdaptiveQuant {
	/// Lanes in `HWY_CAPPED(float, kBlockDim)` on arm64.
	static let lanes = 4

	/// Reproduces `vaddvq_f32`: pairwise, not left-to-right.
	static func sumOfLanes(_ v: (Float, Float, Float, Float)) -> Float {
		(v.0 + v.1) + (v.2 + v.3)
	}

	static func computeMask(_ outValue: Float) -> Float {
		let base: Float = -0.741_749_93
		let mul4: Float = 3.235_325_732_094_040_1
		let mul2: Float = 12.906_028_311_180_409
		let offset2: Float = 305.040_357_283_114_36
		let mul3: Float = 5.022_031_310_317_123_2
		let offset3: Float = 2.192_573_970_529_840_4
		let offset4: Float = 0.25 * offset3
		let mul0: Float = 0.747_604_222_337_067_47

		// Avoid division by zero.
		let v1 = max(outValue * mul0, 1e-3)
		let v2 = 1.0 / (v1 + offset2)
		let v3 = 1.0 / offset3.addingProduct(v1, v1)
		let v4 = 1.0 / offset4.addingProduct(v1, v1)
		return base + (mul4 * v4 + (mul2 * v2 + mul3 * v3))
	}

	/// Hack for mask estimation, per the reference's own description.
	static func computeMaskForAcStrategyUse(_ outValue: Float) -> Float {
		1.0 / (outValue + 0.001)
	}

	/// Change precision in blocks with high frequency content.
	static func hfModulation(
		x: Int, y: Int, plane: [Float], stride: Int, outValue: Float
	) -> Float {
		var sum: (Float, Float, Float, Float) = (0, 0, 0, 0)

		for dy in 0..<8 {
			let row = (y + dy) * stride + x
			// The last row reuses itself, so its vertical difference is zero.
			let rowNext = dy == 7 ? row : (y + dy + 1) * stride + x

			for dx in stride2(0, 8, lanes) {
				for lane in 0..<lanes {
					let i = dx + lane
					let p = plane[row + i]
					// The rightmost column has no right neighbour; the reference
					// masks that lane rather than skipping it.
					let horizontal = i == 7 ? 0 : abs(p - plane[row + i + 1])
					let vertical = abs(p - plane[rowNext + i])
					let value = horizontal + vertical
					switch lane {
					case 0: sum.0 += value
					case 1: sum.1 += value
					case 2: sum.2 += value
					default: sum.3 += value
					}
				}
			}
		}

		let total = sumOfLanes(sum)
		return outValue.addingProduct(total, Float(-2.005_219_323_368_888_4) / 112)
	}

	static func colorModulation(
		x: Int, y: Int,
		planeX: [Float], planeY: [Float], planeB: [Float], stride: Int,
		butteraugliTarget: Float, outValue: Float
	) -> Float {
		let strengthMul: Float = 2.177_823_400_325_309
		let redRampStart: Float = 0.007_320_014_111_895_123_1
		let redRampLength: Float = 0.019_421_555_948_474_039
		let blueRampLength: Float = 0.086_890_611_400_405_895
		let blueRampStart: Float = 0.269_734_185_078_705_39

		// The reference takes the target as a double, so this expression is
		// evaluated in double before narrowing.
		let strength = Float(
			Double(strengthMul) * (1.0 - 0.25 * Double(butteraugliTarget)))
		if strength < 0 { return outValue }

		// x values are smaller than y and b, so red needs its own scale.
		let redStrength = strength * 5.992_297_772_961_519
		let blueStrength = strength

		// Reduce some bits from areas that are neither blue nor red.
		var result = outValue + strength * -0.009_174_542_291_185_913

		var redCoverage: (Float, Float, Float, Float) = (0, 0, 0, 0)
		var blueCoverage: (Float, Float, Float, Float) = (0, 0, 0, 0)

		for dy in 0..<8 {
			let row = (y + dy) * stride + x
			for dx in stride2(0, 8, lanes) {
				for lane in 0..<lanes {
					let i = row + dx + lane
					let pixelX = max(0, planeX[i] - redRampStart)
					let pixelY = planeY[i]
					let pixelB = max(0, planeB[i] - (pixelY + blueRampStart))
					let redSlope = min(pixelX, redRampLength)
					let blueSlope = min(pixelB, blueRampLength)
					switch lane {
					case 0:
						redCoverage.0 += redSlope
						blueCoverage.0 += blueSlope
					case 1:
						redCoverage.1 += redSlope
						blueCoverage.1 += blueSlope
					case 2:
						redCoverage.2 += redSlope
						blueCoverage.2 += blueSlope
					default:
						redCoverage.3 += redSlope
						blueCoverage.3 += blueSlope
					}
				}
			}
		}

		// Saturate: past this fraction of the block, treat it as fully coloured.
		let ratio: Float = 30.610_615_782_142_737

		var overallRed = sumOfLanes(redCoverage)
		overallRed = min(overallRed, ratio * redRampLength)
		overallRed = overallRed * (redStrength / ratio)

		var overallBlue = sumOfLanes(blueCoverage)
		overallBlue = min(overallBlue, ratio * blueRampLength)
		overallBlue = overallBlue * (blueStrength / ratio)

		return overallRed + (overallBlue + result)
	}

	static func gammaModulation(
		x: Int, y: Int, planeX: [Float], planeY: [Float], stride: Int, outValue: Float
	) -> Float {
		let bias: Float = 0.16
		var overallRatio: (Float, Float, Float, Float) = (0, 0, 0, 0)

		for dy in 0..<8 {
			let row = (y + dy) * stride + x
			for dx in stride2(0, 8, lanes) {
				for lane in 0..<lanes {
					let i = row + dx + lane
					let inY = planeY[i] + bias
					let inX = planeX[i]
					let r = inY - inX
					let g = inY + inX
					let ratioR =
						FastMath.ratioOfDerivativesOfCubicRootToSimpleGamma(
							r, invert: true)
					let ratioG =
						FastMath.ratioOfDerivativesOfCubicRootToSimpleGamma(
							g, invert: true)
					let average = 0.5 * (ratioR + ratioG)
					switch lane {
					case 0: overallRatio.0 += average
					case 1: overallRatio.1 += average
					case 2: overallRatio.2 += average
					default: overallRatio.3 += average
					}
				}
			}
		}

		let ratio = sumOfLanes(overallRatio) * (1.0 / 64)
		// ln(2) folded in because the reference wants std::log but has FastLog2f.
		let gam: Float = -0.155_268_780_236_841_74 * 0.693_147_180_559_945
		return outValue.addingProduct(gam, FastMath.log2(ratio))
	}

	static func stride2(_ from: Int, _ to: Int, _ by: Int) -> StrideTo<Int> {
		Swift.stride(from: from, to: to, by: by)
	}
}
