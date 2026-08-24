//
//  JPEGBlockContextMapTests.swift
//  JXLEncoderTests
//
//  Hand-computed cases for the threshold-placement algorithm in isolation,
//  before it is wired into any encoder path — see
//  docs/gap-closure-plan.md's gating plan for this stage.
//

import Testing

@testable import JXLEncoder

@Suite("JPEG block context map")
struct JPEGBlockContextMapTests {
	@Test("threshold count follows the clamp(log2 total - log2 qtSum - 7, 1, 7) formula")
	func numThresholdsFormula() {
		// total = 1024 (ceilLog2 = 10), qtSum = 1 (ceilLog2 = 0): 10-0-7 = 3.
		// Four equal point masses at histogram bins 500/700/900/1100 (a
		// recovered threshold is `bin - 1025`, not the bin itself).
		var counts = [Int](repeating: 0, count: 2048)
		counts[500] = 256
		counts[700] = 256
		counts[900] = 256
		counts[1100] = 256
		let result = JPEGBlockContextMap.computeThresholds(
			counts: counts, total: 1024, qtSum: 1)
		// cut starts at 256; cumulative == cut (not >) never pushes, so the
		// first point mass (256) is absorbed into the first bucket, not a
		// boundary — only the three later crossings place a threshold.
		#expect(result == [-325, -125, 75])
	}

	@Test("a single dominant value still yields the clamped minimum of one threshold")
	func minimumOneThreshold() {
		var counts = [Int](repeating: 0, count: 2048)
		counts[1024] = 256  // every block at DC value 0
		// total = 256 (ceilLog2 = 8), qtSum = 2 (ceilLog2 = 1): 8-1-7 = 0, clamped to 1.
		let result = JPEGBlockContextMap.computeThresholds(
			counts: counts, total: 256, qtSum: 2)
		#expect(result.count == 1)
		#expect(result == [-1])
	}

	@Test("the threshold count never exceeds seven")
	func maximumSevenThresholds() {
		var counts = [Int](repeating: 0, count: 2048)
		for j in 0..<2048 { counts[j] = 1 }
		// total = 2048 (ceilLog2 = 11), qtSum = 1 (ceilLog2 = 0): 11-0-7 = 4, well under
		// the ceiling, so this exercises the walk producing exactly that count.
		let result = JPEGBlockContextMap.computeThresholds(
			counts: counts, total: 2048, qtSum: 1)
		#expect(result.count == 4)

		// Force the unclamped value above 7: total = 2^18, qtSum = 1 -> 18-0-7 = 11.
		var bigCounts = [Int](repeating: 0, count: 2048)
		bigCounts[1024] = 1 << 18
		let clamped = JPEGBlockContextMap.computeThresholds(
			counts: bigCounts, total: 1 << 18, qtSum: 1)
		#expect(clamped.count <= 7)
	}

	@Test("channel-to-slot permutation matches BlockCtxMap::Context: luma=0, channel 0=1, channel 2=2")
	func channelSlotPermutation() {
		#expect(JPEGBlockContextMap.slot(forChannel: 1) == 0)
		#expect(JPEGBlockContextMap.slot(forChannel: 0) == 1)
		#expect(JPEGBlockContextMap.slot(forChannel: 2) == 2)
	}

	@Test("bucket counts strictly-exceeded thresholds, matching compressed_dc.cc's > comparison")
	func bucketLookup() {
		let result = JPEGBlockContextMap.Result(
			thresholds: [-10, 0, 10], contextMap: [], numContexts: 0)
		#expect(result.bucket(dc: -20) == 0)
		#expect(result.bucket(dc: -10) == 0)  // equal, not exceeded
		#expect(result.bucket(dc: -9) == 1)
		#expect(result.bucket(dc: 0) == 1)  // equal, not exceeded
		#expect(result.bucket(dc: 1) == 2)
		#expect(result.bucket(dc: 10) == 2)  // equal, not exceeded
		#expect(result.bucket(dc: 11) == 3)
	}
}
