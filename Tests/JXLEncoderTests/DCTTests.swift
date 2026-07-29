import Testing

@testable import JXLEncoder

/// Differential tests against libjxl-tiny's `ComputeScaledDCT<8, 8>`, fed the
/// XYB stage output so the two stages compose exactly as they do in the encoder.
@Suite("DCT")
struct DCTTests {
	@Test("matches libjxl-tiny bit-for-bit on the edge-case fixture")
	func matchesReference() throws {
		let xyb = try StageDump(fixture: "edge_xyb")
		let expected = try StageDump(fixture: "edge_dct")

		var worstULP = 0
		for channel in 0..<3 {
			let actual = DCT.forwardBlocks(
				plane: xyb.planes[channel], width: xyb.width, height: xyb.height)
			for i in 0..<actual.count {
				worstULP = max(
					worstULP,
					ulpDistance(actual[i], expected.planes[channel][i]))
			}
		}
		#expect(worstULP == 0)
	}

	/// A flat block has all its energy in DC. The reference folds 1/N into each
	/// of the two passes, so DC ends up at the block mean rather than 64x it —
	/// this pins that scaling, which is easy to drop silently.
	@Test("flat block puts all energy in DC at the mean value")
	func flatBlockIsDCOnly() {
		let level: Float = 0.75
		let plane = [Float](repeating: level, count: 64)
		let coeffs = DCT.forwardBlocks(plane: plane, width: 8, height: 8)

		#expect(coeffs[0] == level)
		for i in 1..<64 {
			#expect(abs(coeffs[i]) < 1e-6)
		}
	}

	@Test("block-raster output order places each block in 64 consecutive slots")
	func blockOrdering() {
		var plane = [Float](repeating: 0, count: 16 * 16)
		// mark only the block at (1, 1)
		for y in 8..<16 {
			for x in 8..<16 { plane[y * 16 + x] = 1 }
		}
		let coeffs = DCT.forwardBlocks(plane: plane, width: 16, height: 16)

		#expect(coeffs[3 * 64] == 1)  // block index 3 = (bx 1, by 1)
		#expect(coeffs[0] == 0)
		#expect(coeffs[64] == 0)
		#expect(coeffs[2 * 64] == 0)
	}

	/// The transform is its own inverse-transpose pair, so a block that is
	/// symmetric about the diagonal must produce symmetric coefficients. Catches
	/// a transposed or mis-strided pass that a flat block would not.
	@Test("symmetric input yields symmetric coefficients")
	func symmetry() {
		var plane = [Float](repeating: 0, count: 64)
		for y in 0..<8 {
			for x in 0..<8 { plane[y * 8 + x] = Float(x * y) / 49 }
		}
		let coeffs = DCT.forwardBlocks(plane: plane, width: 8, height: 8)
		for y in 0..<8 {
			for x in 0..<8 {
				#expect(abs(coeffs[y * 8 + x] - coeffs[x * 8 + y]) < 1e-6)
			}
		}
	}
}
