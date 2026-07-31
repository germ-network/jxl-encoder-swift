import Testing

@testable import JXLEncoder

/// Half floats carry the quantization a JPEG transcode transmits, so a decoder
/// reconstructs its dequantization from exactly these bits. Swift has `Float16`,
/// but it rounds to nearest where the reference truncates — using it would be
/// more accurate and disagree with every decoder.
@Suite("Float16 coder")
struct Float16CoderTests {
	@Test(
		"exact values encode to their known patterns",
		arguments: [
			(Float(0), UInt16(0x0000)),
			// Negative zero loses its sign: its exponent is -127, so it takes the
			// same collapse-to-zero path as any other tiny value.
			(-0.0, 0x0000),
			(1, 0x3C00),
			(-1, 0xBC00),
			(2, 0x4000),
			(0.5, 0x3800),
			(65504, 0x7BFF),  // largest finite
			(6.103515625e-5, 0x0400),  // smallest normal
			(5.960464477539063e-8, 0x0001),  // smallest subnormal
		])
	func knownPatterns(value: Float, expected: UInt16) throws {
		#expect(try Float16Coder.bits(value) == expected)
	}

	/// The reference truncates: `mantissa32 >> 13`, no rounding. A value just
	/// under the next representable step must stay at the lower one.
	@Test("the mantissa truncates rather than rounds")
	func truncates() throws {
		// 1 + 2^-11 sits between 1.0 and the next half float (1 + 2^-10). Rounding
		// to nearest would carry it up; truncation keeps it at 1.0.
		let between = Float(1) + Float(1).ulp * 4096  // 1 + 2^-11
		#expect(try Float16Coder.bits(between) == 0x3C00)
		#expect(Float16Coder.value(fromBits: try Float16Coder.bits(between)) == 1)

		// And a value at the step itself does advance.
		let step = Float(1) + Float(1).ulp * 8192  // 1 + 2^-10
		#expect(try Float16Coder.bits(step) == 0x3C01)
	}

	/// Below the smallest subnormal everything collapses to positive zero — the
	/// sign goes too, which is what the reference does.
	@Test("tiny values collapse to zero")
	func tinyToZero() throws {
		#expect(try Float16Coder.bits(1e-10) == 0)
		#expect(try Float16Coder.bits(-1e-10) == 0)
	}

	@Test(
		"values a half float cannot hold are refused",
		arguments: [Float.infinity, -.infinity, .nan, 65505, 1e30])
	func refusesOutOfRange(value: Float) {
		#expect(throws: Float16Coder.Float16Error.self) {
			try Float16Coder.bits(value)
		}
	}

	/// The values this actually carries are DC quantization steps, `255 * 8 /
	/// quant[0]`, and quant table denominators. Those must survive a round trip
	/// closely enough that dequantization lands on the same coefficients.
	@Test(
		"DC quantization steps round-trip within half-float precision",
		arguments: [1, 2, 3, 8, 16, 27, 64, 99, 128, 255] as [Int])
	func dcQuantRoundTrip(quant: Int) throws {
		let step = 255 * 8 / Float(quant)
		let decoded = Float16Coder.value(fromBits: try Float16Coder.bits(step))
		// Truncation loses at most one ulp of the half float, which is 2^-10
		// relative.
		#expect(decoded <= step)
		#expect(decoded > step * (1 - 1.0 / 1024))
	}

	@Test("write emits sixteen bits, low byte first")
	func writesSixteenBits() throws {
		var writer = BitWriter()
		try Float16Coder.write(1, to: &writer)
		#expect(writer.bitsWritten == 16)
		#expect(writer.take() == [0x00, 0x3C])
	}
}
