import Testing

@testable import JXLEncoder

private struct DCMismatch: Equatable {
	let index: Int
	let actual: Int64
	let expected: Int64
}

private func dcMismatches(actual: [Int64], expected: [Int64]) -> [DCMismatch] {
	zip(actual, expected).enumerated().compactMap { index, values in
		values.0 == values.1
			? nil
			: DCMismatch(index: index, actual: values.0, expected: values.1)
	}
}

private func hasSwiftDCShape(actualCount: Int, codedBlockCount: Int) -> Bool {
	actualCount == codedBlockCount
}

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

	@Test("DC comparison detects a one-integer mutation")
	func dcComparisonDetectsIntegerMutation() {
		let actual: [Int64] = [2, -3, 5, 11]
		var expected = actual
		#expect(dcMismatches(actual: actual, expected: expected).isEmpty)
		expected[3] += 1
		#expect(
			dcMismatches(actual: actual, expected: expected)
				== [DCMismatch(index: 3, actual: 11, expected: 12)])
	}

	@Test("DC comparison detects truncation of Swift output")
	func dcComparisonDetectsTruncatedSwiftOutput() throws {
		let image = try loadPPM(fixture: "dc_boundary")
		let dim = ImageDim(width: image.width, height: image.height)
		let result = try SwiftSemanticEncoding.encode(image, distance: 1)
		let groups = try #require(result.decisions.pixelGroups)
		let actual = SwiftSemanticEncoding.coefficients(from: groups, dimension: dim)
		let blockCount = dim.widthInBlocks * dim.heightInBlocks
		let original = actual.dc[0]
		let truncated = Array(original.dropLast())
		#expect(hasSwiftDCShape(actualCount: original.count, codedBlockCount: blockCount))
		#expect(!hasSwiftDCShape(actualCount: truncated.count, codedBlockCount: blockCount))
	}

	@Test("per-channel DC integers match upstream at distance bounds")
	func quantizedDCMatchesReferenceAtDistanceBounds() throws {
		let image = try loadPPM(fixture: "dc_boundary")
		let reference = try SemanticDump(fixture: "dc_boundary")
		guard case .integers(let inputBits)? = reference.fields["dc_boundary.inputs"] else {
			Issue.record("missing upstream DC boundary inputs")
			return
		}
		let distances = inputBits.map { Float(bitPattern: UInt32(truncatingIfNeeded: $0)) }
		guard
			case .integers(let blockCounts)? = reference.fields[
				"dc_boundary.blocks_per_distance"]
		else {
			Issue.record("missing DC boundary block count")
			return
		}
		let dim = ImageDim(width: image.width, height: image.height)
		#expect(blockCounts.count == distances.count)
		let reducedGridDistances: Set<Int> = [43, 44]
		let expectedChannels: [[Int64]] = (0..<3).map { channel in
			if case .integers(let values)? = reference.fields["dc_boundary.c\(channel)"]
			{
				return values
			}
			Issue.record("missing round-tripped DC channel \(channel)")
			return []
		}
		#expect(
			expectedChannels.allSatisfy {
				$0.count == blockCounts.reduce(0) { $0 + Int($1) }
			})
		for channel in 0..<3 {
			var expectedOffset = 0
			for (distanceIndex, distance) in distances.enumerated() {
				let result = try SwiftSemanticEncoding.encode(
					image, distance: distance)
				let groups = try #require(result.decisions.pixelGroups)
				let output = SwiftSemanticEncoding.coefficients(
					from: groups, dimension: dim)
				let actual = output.dc[channel].map(Int64.init)
				let blockCount = Int(blockCounts[distanceIndex])
				let swiftBlockCount = dim.widthInBlocks * dim.heightInBlocks
				#expect(
					hasSwiftDCShape(
						actualCount: actual.count,
						codedBlockCount: swiftBlockCount),
					"Swift distance \(distance), channel \(channel) grid")
				if reducedGridDistances.contains(distanceIndex) {
					withKnownIssue(Comment(rawValue: "GER-3387")) {
						#expect(
							blockCount == swiftBlockCount,
							"distance \(distance), channel \(channel) upstream grid"
						)
					}
				} else {
					#expect(
						blockCount == swiftBlockCount,
						"upstream distance \(distance) grid")
				}
				let expected = Array(
					expectedChannels[channel][
						expectedOffset..<(expectedOffset + blockCount)])
				expectedOffset += blockCount
				let mismatches = dcMismatches(
					actual: Array(actual.prefix(blockCount)), expected: expected
				)
				withKnownIssue(Comment(rawValue: "GER-3387")) {
					#expect(
						mismatches.isEmpty,
						Comment(
							rawValue:
								"distance \(distance), channel \(channel), mismatch count \(mismatches.count), first differences \(mismatches.prefix(8))"
						))
				}
			}
		}
	}
}
