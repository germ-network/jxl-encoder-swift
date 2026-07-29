import Testing

@testable import JXLEncoder

@Suite("Geometry")
struct GeometryTests {
	@Test("tiling counts round up")
	func tilingCounts() {
		let dim = ImageDim(width: 267, height: 41)
		#expect(dim.widthInBlocks == 34)  // ceil(267/8)
		#expect(dim.heightInBlocks == 6)  // ceil(41/8)
		#expect(dim.widthInTiles == 17)  // ceil(267/16)
		#expect(dim.heightInTiles == 3)  // ceil(41/16)
		#expect(dim.widthInGroups == 2)  // ceil(267/256)
		#expect(dim.heightInGroups == 1)
		#expect(dim.groupCount == 2)
	}

	@Test("rects clip at the right and bottom edges")
	func rectsClip() {
		let dim = ImageDim(width: 267, height: 41)
		let first = dim.stripeRect(groupX: 0, tileY: 0)
		#expect(first == Rect(x0: 0, y0: 0, width: 256, height: 16))

		// second group column holds only the remaining 11 pixels
		let edge = dim.stripeRect(groupX: 1, tileY: 0)
		#expect(edge.x0 == 256)
		#expect(edge.width == 11)

		// last tile row holds only the remaining 9 rows
		let bottom = dim.stripeRect(groupX: 0, tileY: 2)
		#expect(bottom.y0 == 32)
		#expect(bottom.height == 9)
	}

	@Test("a single-pixel image still yields one stripe")
	func singlePixel() {
		let dim = ImageDim(width: 1, height: 1)
		#expect(dim.groupCount == 1)
		#expect(dim.heightInTiles == 1)
		#expect(
			dim.stripeRect(groupX: 0, tileY: 0)
				== Rect(x0: 0, y0: 0, width: 1, height: 1))
	}
}

/// The pipeline is tiled, and padding is what makes non-multiple-of-8 images
/// work at all: the last row and column of blocks are fed partly from
/// replicated edge pixels. The fixture is 267x41 so it crosses a group boundary
/// (256 + 11) and pads on both axes.
@Suite("Stripe pipeline")
struct StripePipelineTests {
	func interleaved(_ stripe: PaddedStripe) -> [Float] {
		let count = stripe.width * stripe.height
		var out = [Float](repeating: 0, count: count * 3)
		for i in 0..<count {
			for c in 0..<3 { out[i * 3 + c] = stripe.planes[c][i] }
		}
		return out
	}

	@Test("padded stripes match libjxl-tiny bit-for-bit through XYB and DCT")
	func matchesReference() throws {
		let input = try StageDump(fixture: "stripe_linear")
		let expected = try StageDump(fixture: "stripe_dct")

		let dim = ImageDim(width: input.width, height: input.height)
		let source = input.interleaved

		var actual: [[Float]] = [[], [], []]
		for gx in 0..<dim.widthInGroups {
			for ty in 0..<dim.heightInTiles {
				let rect = dim.stripeRect(groupX: gx, tileY: ty)
				let padded = PlaneBuffer.copyAndPad(
					source: source, sourceWidth: input.width, rect: rect)
				let xyb = XYB.toXYB(
					linearRGB: interleaved(padded),
					pixelCount: padded.width * padded.height)
				for (c, plane) in [xyb.x, xyb.y, xyb.b].enumerated() {
					actual[c] += DCT.forwardBlocks(
						plane: plane, width: padded.width,
						height: padded.height)
				}
			}
		}

		#expect(actual[0].count == expected.planes[0].count)
		var worstULP = 0
		for c in 0..<3 {
			for i in 0..<min(actual[c].count, expected.planes[c].count) {
				worstULP = max(
					worstULP, ulpDistance(actual[c][i], expected.planes[c][i]))
			}
		}
		#expect(worstULP == 0)
	}

	@Test("padding repeats the last real column, then the last real row")
	func paddingReplicatesEdges() {
		// 3x2 image, values encode position so replication is visible
		let source: [Float] = [
			1, 1, 1, 2, 2, 2, 3, 3, 3,
			4, 4, 4, 5, 5, 5, 6, 6, 6,
		]
		let padded = PlaneBuffer.copyAndPad(
			source: source, sourceWidth: 3,
			rect: Rect(x0: 0, y0: 0, width: 3, height: 2))

		#expect(padded.width == 8)
		#expect(padded.height == 8)

		let plane = padded.planes[0]
		#expect(Array(plane[0..<8]) == [1, 2, 3, 3, 3, 3, 3, 3])
		#expect(Array(plane[8..<16]) == [4, 5, 6, 6, 6, 6, 6, 6])
		// rows below the image repeat the last padded row, so the bottom-right
		// corner carries the last real pixel
		for y in 2..<8 {
			#expect(Array(plane[y * 8..<(y + 1) * 8]) == [4, 5, 6, 6, 6, 6, 6, 6])
		}
	}
}
