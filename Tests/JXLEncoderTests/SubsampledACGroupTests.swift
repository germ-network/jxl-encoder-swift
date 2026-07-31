import Testing

@testable import JXLEncoder

/// Pins the subsampling rules the AC group walk depends on, checked against
/// `TokenizeCoefficients` in libjxl's enc_entropy_coder.cc.
///
/// The pixel encoder always passes 4:4:4, so nothing here was exercised until
/// the JPEG path arrived, and at 4:4:4 every one of these rules degenerates to
/// an identity — which is exactly why they need pinning separately.
@Suite("Subsampled AC group rules")
struct SubsampledACGroupTests {
	/// 4:2:0 as a JPEG produces it: luma sampled 2x2, chroma 1x1.
	static let yuv420 = ChromaSubsampling.fromJPEG(
		horizontalSampling: [2, 1, 1], verticalSampling: [2, 1, 1])!
	/// 4:2:2 — halved horizontally only.
	static let yuv422 = ChromaSubsampling.fromJPEG(
		horizontalSampling: [2, 1, 1], verticalSampling: [1, 1, 1])!

	@Test("luma is never shifted, chroma is")
	func shifts() {
		#expect(Self.yuv420.horizontalShift(1) == 0)
		#expect(Self.yuv420.verticalShift(1) == 0)
		for channel in [0, 2] {
			#expect(Self.yuv420.horizontalShift(channel) == 1)
			#expect(Self.yuv420.verticalShift(channel) == 1)
			#expect(Self.yuv422.horizontalShift(channel) == 1)
			#expect(Self.yuv422.verticalShift(channel) == 0)
		}
	}

	/// libjxl gates a channel's block on `sbx[c] << HShift(c) == bx`, and the
	/// same vertically. `codesBlock` has to agree exactly: a channel that codes
	/// a block libjxl skips writes a whole extra block into the stream.
	@Test("codesBlock matches libjxl's gate", arguments: [0, 1, 2])
	func gateMatchesReference(channel: Int) {
		for subsampling in [Self.yuv420, Self.yuv422, ChromaSubsampling.none] {
			let hShift = subsampling.horizontalShift(channel)
			let vShift = subsampling.verticalShift(channel)
			for by in 0..<9 {
				for bx in 0..<13 {
					let reference =
						(subsampling.subsampledX(
							channel: channel, blockX: bx)
							<< hShift == bx)
						&& (subsampling.subsampledY(
							channel: channel, blockY: by)
							<< vShift == by)
					#expect(
						subsampling.codesBlock(
							channel: channel, blockX: bx, blockY: by)
							== reference)
				}
			}
		}
	}

	/// The count of blocks a channel codes, which drives the nonzero-neighbour
	/// bookkeeping, rounds *up*: a 13-wide grid at 4:2:0 codes chroma at
	/// bx = 0, 2, 4, 6, 8, 10, 12 — seven blocks.
	@Test("coded blocks round up")
	func codedBlocksRoundUp() {
		let coded = (0..<13).filter {
			Self.yuv420.codesBlock(channel: 0, blockX: $0, blockY: 0)
		}
		#expect(coded == [0, 2, 4, 6, 8, 10, 12])
		#expect(Self.yuv420.blocksAcross(channel: 0, fullWidthInBlocks: 13) == 7)
	}

	/// The DC plane rounds *down*, because the decoder shrinks with a shift. So
	/// on an odd grid a channel codes one more block than its DC plane has room
	/// for, and that block's DC is simply not stored.
	///
	/// These two numbers are easy to conflate and mean different things; the AC
	/// group has to use each in its own place.
	@Test("the DC plane rounds down, and can be narrower than the coded blocks")
	func dcPlaneRoundsDown() {
		#expect(Self.yuv420.dcPlaneSize(channel: 0, blocks: 13, vertical: false) == 6)
		#expect(Self.yuv420.blocksAcross(channel: 0, fullWidthInBlocks: 13) == 7)
		#expect(Self.yuv420.dcPlaneSize(channel: 0, blocks: 9, vertical: true) == 4)

		// Even grids agree, which is why this only shows on odd dimensions.
		#expect(Self.yuv420.dcPlaneSize(channel: 0, blocks: 12, vertical: false) == 6)
		#expect(Self.yuv420.blocksAcross(channel: 0, fullWidthInBlocks: 12) == 6)

		// Luma is unshifted, so both agree for it always.
		#expect(Self.yuv420.dcPlaneSize(channel: 1, blocks: 13, vertical: false) == 13)
		#expect(Self.yuv420.blocksAcross(channel: 1, fullWidthInBlocks: 13) == 13)
	}

	/// At 4:4:4 every rule above collapses to the identity, which is why the
	/// pixel path never exposed any of them.
	@Test("4:4:4 makes every rule an identity")
	func fourFourFourIsIdentity() {
		let none = ChromaSubsampling.none
		for channel in 0..<3 {
			#expect(
				none.dcPlaneSize(channel: channel, blocks: 13, vertical: false)
					== 13)
			#expect(none.blocksAcross(channel: channel, fullWidthInBlocks: 13) == 13)
			for bx in 0..<13 {
				#expect(none.codesBlock(channel: channel, blockX: bx, blockY: 0))
			}
		}
	}
}
