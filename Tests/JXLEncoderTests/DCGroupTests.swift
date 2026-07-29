import Testing

@testable import JXLEncoder

/// Byte-exact comparison against the reference's own `WriteDCGroup`, fed the
/// same synthetic DC image and quant field that `Reference/tools/dump_stages.cc`
/// builds, so the modular path is verified independently of the DCT stages.
@Suite("DC group")
struct DCGroupTests {
	/// Mirrors the synthetic data in the `dcgroup` dump stage.
	static func makeData(widthInBlocks: Int, heightInBlocks: Int) -> DCGroupData {
		var data = DCGroupData(
			widthInBlocks: widthInBlocks, heightInBlocks: heightInBlocks)
		for c in 0..<3 {
			for y in 0..<heightInBlocks {
				for x in 0..<widthInBlocks {
					let v = Int((x * 7 + y * 13 + c * 29) % 61) - 30
					data.quantDC[c][y * widthInBlocks + x] = Int16(
						v * (c == 1 ? 5 : 1))
				}
			}
		}
		for y in 0..<heightInBlocks {
			for x in 0..<widthInBlocks {
				data.rawQuantField[y * widthInBlocks + x] = UInt8(
					1 + (x * 3 + y * 5) % 17)
			}
		}
		return data
	}

	@Test("bitstream matches libjxl-tiny byte for byte")
	func matchesReference() throws {
		let reference = try StageDump(fixture: "edge_dcgroup")
		let expectedBits = Int(reference.planes[0][0])
		let expectedBytes = reference.planes[0].dropFirst().map { UInt8($0) }

		// the fixture image is 32x32
		let data = Self.makeData(widthInBlocks: 4, heightInBlocks: 4)

		var writer = BitWriter()
		DCGroupEncoder.write(data: data, code: .staticDC, writer: &writer)

		#expect(writer.bitsWritten == expectedBits)
		writer.zeroPadToByte()
		let actual = writer.take()
		#expect(actual.count == expectedBytes.count)
		let firstDifference = zip(actual, expectedBytes).enumerated()
			.first { $0.element.0 != $0.element.1 }?.offset
		#expect(firstDifference == nil, "first differing byte at \(firstDifference ?? -1)")
	}

	@Test("clamped gradient stays between its neighbours")
	func gradientClamps() {
		// straightforward interpolation when top-left sits between
		#expect(DCPredictor.clampedGradient(top: 10, left: 20, topLeft: 15) == 15)
		// clamped up when top-left is below both
		#expect(DCPredictor.clampedGradient(top: 10, left: 20, topLeft: 0) == 20)
		// clamped down when top-left is above both
		#expect(DCPredictor.clampedGradient(top: 10, left: 20, topLeft: 100) == 10)
	}

	@Test("gradient context table covers the full property range")
	func contextTableSize() {
		#expect(DCPredictor.gradientContextLut.count == DCPredictor.gradRangeMax + 1)
		for entry in DCPredictor.gradientContextLut {
			#expect(Int(entry) < DCPredictor.numDCContexts)
		}
	}
}
