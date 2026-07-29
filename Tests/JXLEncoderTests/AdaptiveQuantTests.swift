import Testing

@testable import JXLEncoder

/// Differential tests against libjxl-tiny's `ComputeAdaptiveQuantFieldTile`,
/// walked over the real stripe/tile geometry.
///
/// The assertion is on the **quantized** field, which is what the encoder
/// actually transmits, and that matches exactly. The intermediate float field
/// agrees to within a few ULP (~4e-7 relative); the residual comes from
/// floating-point contraction choices inside the reference that a port cannot
/// observe directly. A block would only change if one landed within that
/// distance of a rounding boundary, which does not occur across the sizes and
/// images tested.
@Suite("Adaptive quant")
struct AdaptiveQuantTests {
	/// Matches the constants baked into the `aq` stage of dump_stages.cc.
	static let distance: Float = 1.0
	static let inverseScale: Float = 1.0 / 0.112_075_805_664_062_5

	@Test("quantized field matches libjxl-tiny exactly")
	func matchesReference() throws {
		let input = try StageDump(fixture: "stripe_linear")
		let expected = try StageDump(fixture: "stripe_aq")

		let field = AdaptiveQuantPipeline.quantField(
			linearInterleaved: input.interleaved,
			width: input.width,
			height: input.height,
			distance: Self.distance,
			inverseScale: Self.inverseScale)

		#expect(field.count == expected.planes[0].count)
		var mismatches = 0
		for i in 0..<min(field.count, expected.planes[0].count)
		where field[i] != UInt8(expected.planes[0][i]) {
			mismatches += 1
		}
		#expect(mismatches == 0)
	}

	@Test("field values stay inside the transmissible range")
	func clampsToByteRange() throws {
		let input = try StageDump(fixture: "stripe_linear")
		let field = AdaptiveQuantPipeline.quantField(
			linearInterleaved: input.interleaved,
			width: input.width,
			height: input.height,
			distance: Self.distance,
			inverseScale: Self.inverseScale)
		#expect(field.allSatisfy { $0 >= 1 })
	}

	@Test("storeMin4 keeps the four smallest in order")
	func minTracking() {
		var m: (Float, Float, Float, Float) = (10, 20, 30, 40)
		AdaptiveQuant.storeMin4(5, &m)
		#expect(m == (5, 10, 20, 30))
		AdaptiveQuant.storeMin4(25, &m)
		#expect(m == (5, 10, 20, 25))
		AdaptiveQuant.storeMin4(99, &m)
		#expect(m == (5, 10, 20, 25))
	}

	/// `vaddvq_f32` reduces pairwise, and float addition is not associative, so
	/// this ordering is observable rather than cosmetic.
	@Test("lane reduction is pairwise, not left to right")
	func pairwiseReduction() {
		// 1e8 + 1 rounds back to 1e8, so where the small values land relative to
		// the cancellation decides the result.
		let lanes: (Float, Float, Float, Float) = (1, 1e8, -1e8, 1)

		let pairwise = AdaptiveQuant.sumOfLanes(lanes)
		let sequential = ((lanes.0 + lanes.1) + lanes.2) + lanes.3

		#expect(pairwise == 0)
		#expect(sequential == 1)
		#expect(pairwise != sequential)
	}
}
