import Testing

@testable import JXLEncoder

/// Differential tests against libjxl-tiny's `ToXYB`. The fixture covers values
/// photographs never produce — exact zero, negatives, and out-of-gamut samples
/// above 1.0 — because those drive the branches in the fast cube root.
///
/// Bit-exactness is achievable here and is asserted rather than a tolerance:
/// reproducing the reference's fused-multiply-add structure gives identical
/// results, so any drift means the port's arithmetic shape has changed.
@Suite("XYB")
struct XYBTests {
	@Test("matches libjxl-tiny bit-for-bit on the edge-case fixture")
	func matchesReference() throws {
		let input = try StageDump(fixture: "edge_linear")
		let expected = try StageDump(fixture: "edge_xyb")

		let got = XYB.toXYB(linearRGB: input.interleaved, pixelCount: input.pixelCount)
		let actual = [got.x, got.y, got.b]

		var worstULP = 0
		for channel in 0..<3 {
			for i in 0..<input.pixelCount {
				worstULP = max(
					worstULP,
					ulpDistance(actual[channel][i], expected.planes[channel][i])
				)
			}
		}
		#expect(worstULP == 0)
	}

	/// Not *exactly* zero: the two opsin rows sum to 1.0 with different
	/// coefficients, so their fused accumulations round differently in the last
	/// bits. The reference behaves identically — it reaches 3e-08 on this same
	/// input — so this asserts negligible chroma, not zero.
	@Test("neutral gray has negligible chroma")
	func neutralIsAchromatic() {
		for level in stride(from: Float(0), through: 1, by: 0.05) {
			let rgb: [Float] = [level, level, level]
			let out = XYB.toXYB(linearRGB: rgb, pixelCount: 1)
			#expect(abs(out.x[0]) < 1e-7)
		}
	}

	@Test("cube root agrees with the exact value to within tolerance")
	func cubeRootAccuracy() {
		for input in [Float(0.001), 0.01, 0.125, 0.5, 1, 2, 8, 100] {
			let approx = XYB.cubeRootAndAdd(input, 0)
			// exact cbrt via repeated Newton in Double, independent of the port
			var exact = Double(input)
			for _ in 0..<200 {
				exact = (2 * exact + Double(input) / (exact * exact)) / 3
			}
			#expect(abs(Double(approx) - exact) / exact < 1e-6)
		}
	}

	@Test("zero maps to the bias constant, not NaN")
	func zeroIsHandled() {
		let out = XYB.cubeRootAndAdd(0, XYB.negBiasCbrt)
		#expect(out == XYB.negBiasCbrt)
		#expect(!out.isNaN)
	}
}
