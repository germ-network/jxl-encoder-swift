import Testing

@testable import JXLEncoder

/// Quantizer invariants with fixed parameters, independently of the adaptive
/// quant field. This suite retains the full edge experiment and tie invariants;
/// `PixelContractTests` keeps a separate bounded primitive check.
@Suite("Quantizer")
struct QuantizerTests {
	/// Matches the constants baked into the `quant` stage of dump_stages.cc.
	static let scale: Float = 0.112_075_805_664_062_5
	static let quant: Int32 = 5

	@Test("matches the pinned upstream primitive on every edge block and channel")
	func matchesReference() throws {
		let input = try StageDump(fixture: "edge_dct")
		let expected = try SemanticDump(fixture: "edge_fixed_quantized")
		#expect(expected.fields["quantized_edge.neon_target"] == .integers([1]))
		guard case .integers(let counts)? = expected.fields["quantized_edge.block_count"]
		else {
			Issue.record("missing edge block count")
			return
		}
		let count = try #require(counts.first)
		#expect(count == Int64(input.width / DCT.blockSize))
		let multipliers: [Float] = [1.25, 1, 1]
		for channel in 0..<3 {
			guard
				case .integers(let field)? = expected.fields[
					"quantized_edge.c\(channel)"]
			else {
				Issue.record("missing channel \(channel) reference")
				continue
			}
			let actual = Quantizer.quantizePlane(
				coefficients: input.planes[channel], channel: channel,
				quant: Self.quant, scale: Self.scale,
				matrixMultiplier: multipliers[channel])
			#expect(actual.map(Int64.init) == field, "channel \(channel)")
		}
	}

	/// Real coefficients never land exactly on a half, so the corpus above
	/// cannot distinguish the two rounding modes — swapping them leaves it
	/// green. Highway's `Round` documents ties-to-even, so pin it directly.
	@Test("ties round to even, not away from zero")
	func roundsHalfToEven() {
		// identity matrix and unit scale make the quantized value equal the input
		let identity = [Float](repeating: 1, count: DCT.blockSize)[...]
		let ties: [Float] = [0.5, 1.5, 2.5, 3.5, -0.5, -1.5, -2.5, -3.5]
		let expected: [Int32] = [0, 2, 2, 4, 0, -2, -2, -4]

		var coefficients = [Float](repeating: 0, count: DCT.blockSize)
		for (i, value) in ties.enumerated() { coefficients[i] = value }

		let out = Quantizer.quantizeBlockAC(
			coefficients: coefficients[...],
			channel: 1,
			inverseMatrix: identity,
			quant: 1,
			scale: 1
		)
		for i in 0..<ties.count {
			#expect(
				out[i] == expected[i],
				"tie \(ties[i]) should quantize to \(expected[i])")
		}
	}

	@Test("DC is always dropped because its inverse weight is zero")
	func dcIsZeroed() {
		for channel in 0..<3 {
			#expect(QuantMatrices.inverseMatrix(channel: channel).first == 0)
		}
		// a large DC coefficient still quantizes to nothing
		var coefficients = [Float](repeating: 0, count: DCT.blockSize)
		coefficients[0] = 1000
		let out = Quantizer.quantizePlane(
			coefficients: coefficients, channel: 1, quant: Self.quant, scale: Self.scale
		)
		#expect(out[0] == 0)
	}

	@Test("coefficients below the quadrant threshold are dropped")
	func thresholdDropsSmallValues() {
		let identity = [Float](repeating: 1, count: DCT.blockSize)[...]
		let t = Quantizer.thresholds(channel: 1)

		var coefficients = [Float](repeating: 0, count: DCT.blockSize)
		coefficients[1] = t.0 - 0.01  // just under the low-frequency threshold
		coefficients[2] = t.0 + 0.01

		let out = Quantizer.quantizeBlockAC(
			coefficients: coefficients[...], channel: 1,
			inverseMatrix: identity, quant: 1, scale: 1)
		#expect(out[1] == 0)
		#expect(out[2] == 1)
	}

	@Test("channel thresholds differ as the reference specifies")
	func channelThresholds() {
		let x = Quantizer.thresholds(channel: 0)
		let y = Quantizer.thresholds(channel: 1)
		let b = Quantizer.thresholds(channel: 2)

		#expect(x.0 == y.0)  // first quadrant is shared
		#expect(x.1 == y.1 + 0.08)
		#expect(b.1 == 0.75)
		#expect(b.2 == 0.75)
		#expect(b.3 == 0.75)
	}

	@Test("inverse weights are the reciprocal of the forward weights")
	func inverseIsReciprocal() {
		for channel in 0..<3 {
			let forward = Array(QuantMatrices.matrix(channel: channel))
			let inverse = Array(QuantMatrices.inverseMatrix(channel: channel))
			// index 0 is deliberately zeroed
			for i in 1..<DCT.blockSize {
				#expect(abs(forward[i] * inverse[i] - 1) < 1e-5)
			}
		}
	}
}
