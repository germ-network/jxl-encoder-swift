import Testing

@testable import JXLEncoder

/// Guards the fused multiply-add in DC quantization.
///
/// clang contracts `a * b - c * d` into `fma(a, b, -(c * d))` by default; Swift
/// never contracts. Rounding both products separately differs in the last bit,
/// and these inputs sit close enough to a rounding boundary that the difference
/// changes the emitted integer. That cost exactly one block out of 44 800 in a
/// 2100x1400 photo before the port matched the contraction — invisible in the AC
/// bitstream, because coefficient 0 is zeroed there and carried by the DC image.
@Suite("DC quantization")
struct DCQuantizationTests {
	/// Quantizer values for distance 1.0: scale = 7340 / 2^16, quantDC = 10.
	static let scaleDC: Float = Float(10) * (Float(7340) * (1.0 / Float(1 << 16)))
	static var inverseFactorB: Float { 256.0 * scaleDC }

	/// Found by search: fused and unfused rounding disagree here.
	@Test(
		"fused arithmetic is used where it changes the result",
		arguments: [
			(UInt32(0xBF64_2040), Int16(2), Int16(-256)),
			(UInt32(0xBEE3_ADF7), Int16(2), Int16(-128)),
			(UInt32(0xBDE1_003F), Int16(2), Int16(-32)),
		])
	func fusedMatters(coefficientBits: UInt32, yDC: Int16, expected: Int16) {
		let coefficient = Float(bitPattern: coefficientBits)
		let actual = ACGroupEncoder.quantizedDC(
			coefficient: coefficient,
			inverseFactor: Self.inverseFactorB,
			yDC: yDC,
			cflFactor: 0.5)
		#expect(actual == expected)

		// the unfused form would give a different answer, so this test has teeth
		let unfused = Int16(
			(coefficient * Self.inverseFactorB - Float(yDC) * 0.5)
				.rounded(.toNearestOrAwayFromZero))
		#expect(unfused != expected, "inputs no longer discriminate the contraction")
	}

	@Test("rounds ties away from zero, unlike AC quantization")
	func tiesAwayFromZero() {
		// coefficient * 1 - 0 == 2.5 and -2.5
		#expect(
			ACGroupEncoder.quantizedDC(
				coefficient: 2.5, inverseFactor: 1, yDC: 0, cflFactor: 0) == 3)
		#expect(
			ACGroupEncoder.quantizedDC(
				coefficient: -2.5, inverseFactor: 1, yDC: 0, cflFactor: 0) == -3)
		// ties-to-even would give 2 and -2
	}

	@Test("B channel subtracts half of Y's DC")
	func bSubtractsY() {
		let withY = ACGroupEncoder.quantizedDC(
			coefficient: 1, inverseFactor: 100, yDC: 40, cflFactor: 0.5)
		#expect(withY == 80)  // 100 - 20
		let withoutY = ACGroupEncoder.quantizedDC(
			coefficient: 1, inverseFactor: 100, yDC: 40, cflFactor: 0)
		#expect(withoutY == 100)
	}
}
