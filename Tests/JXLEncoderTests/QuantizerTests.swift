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
		let expected = try SemanticDump(fixture: "e4_edge_quantized")
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

	@Test("non-unit quantization parameters still round signed ties to even")
	func roundsTiesWithNonUnitScaleAndMultiplier() {
		let identity = [Float](repeating: 1, count: DCT.blockSize)[...]
		var coefficients = [Float](repeating: 0, count: DCT.blockSize)
		coefficients[1] = 1.2
		coefficients[2] = 2.0
		coefficients[3] = -1.2
		coefficients[4] = -2.0
		let actual = Quantizer.quantizeBlockAC(
			coefficients: coefficients[...], channel: 1,
			inverseMatrix: identity, quant: 2, scale: 0.5,
			matrixMultiplier: 1.25)
		#expect([actual[1], actual[2], actual[3], actual[4]] == [2, 2, -2, -2])
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

		#expect(x.0 == 0.58)
		#expect(y.0 == 0.56)
		#expect(x.1 == 0.62)
		#expect(x.2 == 0.62)
		#expect(x.3 == 0.62)
		#expect(y.1 == 0.62)
		#expect(y.2 == 0.62)
		#expect(y.3 == 0.62)
		#expect(b == x)
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
	@Test(
		"e4 dead zones match upstream for each channel and quadrant",
	)
	func e4DeadZonesMatchReferenceAtThresholdBounds() throws {
		let comparison = SemanticPrimitiveCase.e4Boundary
		#expect(comparison.knownIssues.isEmpty)
		let reference = try SemanticDump(fixture: comparison.fixture)
		let expected = reference.restricted(to: [comparison.category])
		func integers(_ name: String) -> [Int64]? {
			guard
				case .integers(let values)? = expected.fields[
					"\(comparison.category).\(name)"]
			else {
				return nil
			}
			return values
		}
		let channels = try #require(integers("channel"))
		let referenceIndexes = try #require(integers("index"))
		let targets = try #require(integers("target_bits"))
		let inputs = try #require(integers("input_bits"))
		let scaled = try #require(integers("scaled_bits"))
		let outputs = try #require(integers("output"))
		#expect(channels.count == 72)
		#expect(referenceIndexes.count == 72)
		#expect(targets.count == 72)
		#expect(inputs.count == 72)
		#expect(scaled.count == 72)
		#expect(outputs.count == 72)
		let identity = [Float](repeating: 1, count: DCT.blockSize)[...]
		let indexes = [1, 4, 32, 36]
		var boundary = 0
		for channel in 0..<3 {
			let values: [Float] =
				channel == 1
				? [0.56, 0.62, 0.62, 0.62]
				: [0.58, 0.62, 0.62, 0.62]
			for (index, threshold) in zip(indexes, values) {
				let magnitudes = [threshold.nextDown, threshold, threshold.nextUp]
				for sign: Float in [-1, 1] {
					for (offset, magnitude) in magnitudes.enumerated() {
						let referenceValue = Int32(outputs[boundary])
						#expect(channels[boundary] == Int64(channel))
						#expect(referenceIndexes[boundary] == Int64(index))
						#expect(
							Float(bitPattern: UInt32(targets[boundary]))
								.bitPattern == magnitude.bitPattern)
						#expect(scaled[boundary] == targets[boundary])
						let input = Float(
							bitPattern: UInt32(inputs[boundary]))
						let matrix = QuantMatrices.inverseMatrix(
							channel: channel)
						let multiplier: Float = channel == 0 ? 1.25 : 1
						let qac = Self.scale * Float(Self.quant)
						let value =
							(matrix[matrix.startIndex + index]
								* (qac * multiplier)) * input
						#expect(
							abs(value).bitPattern
								== UInt32(scaled[boundary]))
						var coefficients = [Float](
							repeating: 0, count: DCT.blockSize)
						coefficients[index] = sign * magnitude
						let isolated = Quantizer.quantizeBlockAC(
							coefficients: coefficients[...],
							channel: channel,
							inverseMatrix: identity, quant: 1, scale: 1)
						let expected: Int32 =
							offset == 0 ? 0 : (sign < 0 ? -1 : 1)
						#expect(isolated[index] == expected)
						#expect(referenceValue == expected)
						var productionCoefficients = [Float](
							repeating: 0, count: DCT.blockSize)
						productionCoefficients[index] = input
						let production = Quantizer.quantizeBlockAC(
							coefficients: productionCoefficients[...],
							channel: channel,
							inverseMatrix: matrix,
							quant: Self.quant,
							scale: Self.scale,
							matrixMultiplier: multiplier)
						#expect(production[index] == referenceValue)
						boundary += 1
					}
				}
			}
		}
	}

	@Test(
		"actual e4 callers select the translated dead zones",
	)
	func e4CallerQuantizedCoefficientsMatchReference() throws {
		let comparison = SemanticPrimitiveCase.e4CallerPolicy
		#expect(comparison.knownIssues.isEmpty)
		let fixture = try SemanticDump(fixture: comparison.fixture)
		let expectedCaller = fixture.restricted(to: [comparison.category])
		let input = try StageDump(fixture: "e4_caller_witness")
		func integers(_ name: String) -> [Int64]? {
			guard case .integers(let values)? = fixture.fields[name] else { return nil }
			return values
		}
		let channels = try #require(integers("e4_caller.channel"))
		let indexes = try #require(integers("e4_caller.index"))
		let targets = try #require(integers("e4_caller.target_bits"))
		let scaled = try #require(integers("e4_caller.scaled_bits"))
		let quant = try #require(integers("e4_caller.quant"))
		#expect(channels == [1, 1, 1, 1, 0, 0, 0, 2, 2, 2])
		#expect(indexes == [1, 4, 32, 36, 4, 32, 36, 4, 32, 36])
		#expect(targets.count == 10)
		#expect(scaled.count == 10)
		let firstQuant = try #require(quant.first)
		#expect(quant.count == 10)
		#expect(quant.allSatisfy { $0 == firstQuant })
		for probe in 0..<10 {
			let magnitude = Float(bitPattern: UInt32(scaled[probe]))
			let lower = probe == 0 ? Float(0.56) : Float(0.62)
			let upper = probe == 0 ? Float(0.58) : Float(0.635)
			#expect(magnitude > lower && magnitude < upper)
			#expect(
				Float(bitPattern: UInt32(targets[probe]))
					== (probe == 0 ? 0.57 : 0.63))
		}

		let params = try DistanceParams(distance: 1)
		#expect(quant == [Int64](repeating: Int64(params.uniformQuant), count: 10))
		let blockCount = input.height / DCT.blockDim
		var rawDC = [[Float]](
			repeating: [Float](repeating: 0, count: blockCount), count: 3)
		let actual = ACGroupEncoder.computeGroup(
			xyb: PaddedStripe(
				width: input.width, height: input.height, planes: input.planes),
			widthInBlocks: 1, heightInBlocks: blockCount,
			quantField: quant.map(UInt8.init), scale: params.scale,
			xQuantMatrixScale: params.xQuantMatrixScale, rawDC: &rawDC)
		for channel in 0..<3 {
			let expected = try #require(
				integers("\(comparison.category).c\(channel)"))
			#expect(actual[channel].map(Int64.init) == expected, "channel \(channel)")
		}
		#expect(expectedCaller.fields.count == 8)
		for probe in 0..<10 {
			let channel = Int(channels[probe])
			let coefficient = Int(indexes[probe])
			#expect(actual[channel][probe * DCT.blockSize + coefficient] == 1)
		}
	}

}
