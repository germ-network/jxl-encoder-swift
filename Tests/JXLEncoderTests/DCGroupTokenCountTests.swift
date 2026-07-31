import Testing

@testable import JXLEncoder

/// Counts what a DC group section actually emits.
///
/// The subsampled transcode desynchronises somewhere inside this section,
/// between the DC image and the AC metadata that follows it. A staging
/// `SectionWriter` records every token, so the counts can be compared against
/// what the decoder allocates rather than inferred from the failure.
@Suite("DC group token counts")
struct DCGroupTokenCountTests {
	static func tokenCount(_ data: DCGroupData) -> Int {
		var writer = SectionWriter(mode: .staging(.staticDC))
		DCGroupEncoder.write(data: data, writer: &writer)
		return writer.staged.reduce(0) {
			if case .token = $1 { return $0 + 1 } else { return $0 }
		}
	}

	/// Tokens the DC image contributes: one per sample of each channel's plane.
	static func expectedDC(_ data: DCGroupData) -> Int {
		(0..<3).reduce(0) { $0 + data.planeWidths[$1] * data.planeHeights[$1] }
	}

	/// Tokens the AC metadata contributes. None of these are subsampled: the
	/// colour-correlation maps sit on the 8-block colour-tile grid, and the
	/// strategy, quant field and sharpness are one per full-resolution block.
	static func expectedACMetadata(_ data: DCGroupData) -> Int {
		let blocks = data.widthInBlocks * data.heightInBlocks
		return 2 * data.cmapWidth * data.cmapHeight + 3 * blocks
	}

	/// 4:4:4 is the case that works, so it fixes the accounting.
	@Test("4:4:4 emits one DC token per block per channel")
	func fourFourFour() {
		let data = DCGroupData(widthInBlocks: 13, heightInBlocks: 9)
		#expect(Self.expectedDC(data) == 3 * 13 * 9)
		#expect(
			Self.tokenCount(data) == Self.expectedDC(data)
				+ Self.expectedACMetadata(data))
	}

	/// The subsampled case. The decoder allocates `13 >> 1` by `9 >> 1` for each
	/// chroma plane, so the DC image should be 117 + 24 + 24 = 165 tokens.
	@Test("4:2:0 emits the count the decoder allocates for")
	func fourTwoZero() {
		let subsampling = ChromaSubsampling.fromJPEG(
			horizontalSampling: [2, 1, 1], verticalSampling: [2, 1, 1])!
		let data = DCGroupData(
			widthInBlocks: 13, heightInBlocks: 9, subsampling: subsampling)

		#expect(data.planeWidths == [6, 13, 6])
		#expect(data.planeHeights == [4, 9, 4])
		#expect(Self.expectedDC(data) == 117 + 24 + 24)
		#expect(
			Self.tokenCount(data) == Self.expectedDC(data)
				+ Self.expectedACMetadata(data))
	}

	/// Subsampling must not disturb the AC metadata, which is what follows the DC
	/// image in the same section — if it did, the two would be indistinguishable
	/// as causes of the desync.
	@Test("subsampling changes only the DC image, not the metadata after it")
	func metadataUnaffected() {
		let plain = DCGroupData(widthInBlocks: 13, heightInBlocks: 9)
		let subsampled = DCGroupData(
			widthInBlocks: 13, heightInBlocks: 9,
			subsampling: ChromaSubsampling.fromJPEG(
				horizontalSampling: [2, 1, 1], verticalSampling: [2, 1, 1])!)

		#expect(Self.expectedACMetadata(plain) == Self.expectedACMetadata(subsampled))
		#expect(
			Self.tokenCount(plain) - Self.tokenCount(subsampled)
				== Self.expectedDC(plain) - Self.expectedDC(subsampled))
	}
}
