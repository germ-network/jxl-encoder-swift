import Testing

@testable import JXLEncoder

/// Compared against `vrecpeq_f32` results captured by
/// `Reference/tools/genrecip.cc`. The instruction's output is architecturally
/// specified, so this can be exact rather than approximate — which matters
/// because the value feeds B-channel decorrelation through `AdjustQuantBias`.
@Suite("Reciprocal estimate")
struct ReciprocalEstimateTests {
	@Test("matches vrecpeq_f32 bit-for-bit across the captured sweep")
	func matchesHardware() throws {
		let fixture = try UInt32Fixture(name: "recip_estimate")
		#expect(fixture.values.count % 2 == 0)

		var checked = 0
		var mismatches: [(Float, Float, Float)] = []
		for i in stride(from: 0, to: fixture.values.count, by: 2) {
			let input = Float(bitPattern: fixture.values[i])
			let expected = Float(bitPattern: fixture.values[i + 1])
			let actual = ReciprocalEstimate.apply(input)
			checked += 1
			if actual.bitPattern != expected.bitPattern, mismatches.count < 5 {
				mismatches.append((input, actual, expected))
			}
		}
		#expect(checked > 12000)
		#expect(mismatches.isEmpty, "first mismatches: \(mismatches)")
	}

	/// An estimate, not a division: roughly 8 bits of precision is the point.
	@Test("stays within the instruction's documented accuracy")
	func accuracy() {
		for value in stride(from: Float(0.5), to: 100, by: 0.37) {
			let estimate = ReciprocalEstimate.apply(value)
			let exact = 1 / value
			#expect(abs(estimate - exact) / exact < 1.0 / 256)
		}
	}

	@Test("handles zero, infinity and NaN")
	func specialValues() {
		#expect(ReciprocalEstimate.apply(0).isInfinite)
		#expect(ReciprocalEstimate.apply(0) > 0)
		#expect(ReciprocalEstimate.apply(-0.0).isInfinite)
		#expect(ReciprocalEstimate.apply(-0.0) < 0)
		#expect(ReciprocalEstimate.apply(.infinity) == 0)
		#expect(ReciprocalEstimate.apply(-.infinity) == 0)
		#expect(ReciprocalEstimate.apply(.nan).isNaN)
	}
}
