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
	@Test(
		"Threshold inputs use the first JXL channel table")
	func thresholdInputsUseFirstJXLChannelTable() throws {
		let transcode = try distinctTableTranscode(grayscale: false)
		let result = JPEGBlockContextMap.compute(transcode)
		#expect(Array(transcode.quantTable(channel: 0)[1...5]) == [1, 1, 1, 1, 1])
		let expected = JPEGBlockContextMap.computeThresholds(
			counts: histogram(), total: 4096,
			qtSum: transcode.quantTable(channel: 0)[1...5].reduce(0) { $0 + Int($1) })
		#expect(expected.count == 2)
		#expect(result.thresholds == expected)
		#expect(result.numContexts == 7)
		#expect(result.bucket(dc: Int32(expected[0])) == 0)
		#expect(result.bucket(dc: Int32(expected[0] + 1)) == 1)
		#expect(result.category(channel: 1, dcBucket: 1) == 1)
		#expect(result.category(channel: 0, dcBucket: 1) == 3)

		let changedIrrelevantTables = JPEGBlockContextMap.compute(
			try distinctTableTranscode(grayscale: false, changeLumaAndCr: true))
		#expect(changedIrrelevantTables.thresholds == result.thresholds)
		#expect(changedIrrelevantTables.contextMap == result.contextMap)
	}

	@Test(
		"Grayscale threshold inputs retain the sole component table")
	func grayscaleThresholdInputsUseSoleComponentTable() throws {
		let transcode = try distinctTableTranscode(grayscale: true)
		let result = JPEGBlockContextMap.compute(transcode)
		let expected = JPEGBlockContextMap.computeThresholds(
			counts: histogram(), total: 4096,
			qtSum: transcode.quantTable(channel: 0)[1...5].reduce(0) { $0 + Int($1) })
		#expect(result.thresholds == expected)
		#expect(result.numContexts == 4)
		#expect(result.category(channel: 0, dcBucket: 1) == 3)
	}

	private func histogram() -> [Int] {
		var counts = [Int](repeating: 0, count: 2048)
		for i in 0..<4096 { counts[200 + i / 4] += 1 }
		return counts
	}

	private func distinctTableTranscode(grayscale: Bool, changeLumaAndCr: Bool = false)
		throws -> JPEGTranscode
	{
		var first = [UInt16](repeating: 80, count: 64)
		for natural in [8, 16, 24, 32, 40] { first[natural] = 1 }
		var luma = [UInt16](repeating: 20, count: 64)
		for i in 1...5 { luma[i] = changeLumaAndCr ? 1 : 120 }
		var cr = [UInt16](repeating: 50, count: 64)
		for i in 1...5 { cr[i] = changeLumaAndCr ? 1 : 200 }
		let blocks = 4096
		func component(_ id: UInt8, _ table: Int) -> JPEGComponent {
			var coefficients = [Int32](repeating: 0, count: blocks * 64)
			for i in 0..<blocks { coefficients[i * 64] = Int32(i / 4 - 824) }
			return JPEGComponent(
				identifier: id, horizontalSampling: 1, verticalSampling: 1,
				quantTableIndex: table, blocksPerLine: blocks, blocksPerColumn: 1,
				coefficients: coefficients)
		}
		let components =
			grayscale
			? [component(1, 0)] : [component(1, 1), component(2, 0), component(3, 2)]
		return try JPEGTranscode(
			JPEGImage(
				width: blocks * 8, height: 8, components: components,
				quantTables: [first, luma, cr], restartInterval: 0))
	}

	@Test(
		"DC histogram uses the reference unsigned buckets",
		arguments: [
			(-1_048_576, 2047), (-32_768, 2047), (-1025, 2047), (-1024, 0),
			(-1023, 1), (1022, 2046), (1023, 2047), (1024, 2047),
			(32_767, 2047), (1_048_576, 2047),
		]
	)
	func dcHistogramUsesUnsignedBuckets(dc: Int, expectedBucket: Int) throws {
		let component = JPEGComponent(
			identifier: 1, horizontalSampling: 1, verticalSampling: 1,
			quantTableIndex: 0, blocksPerLine: 1, blocksPerColumn: 1,
			coefficients: [Int32(dc)] + [Int32](repeating: 0, count: 63))
		let image = JPEGImage(
			width: 8, height: 8, components: [component],
			quantTables: [[UInt16](repeating: 1, count: 64)], restartInterval: 0)
		let result = JPEGBlockContextMap.compute(try JPEGTranscode(image))
		#expect(result.thresholds == [expectedBucket - 1025])
	}

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

	@Test(
		"channel-to-slot permutation matches BlockCtxMap::Context: luma=0, channel 0=1, channel 2=2"
	)
	func channelSlotPermutation() {
		#expect(JPEGBlockContextMap.slot(forChannel: 1) == 0)
		#expect(JPEGBlockContextMap.slot(forChannel: 0) == 1)
		#expect(JPEGBlockContextMap.slot(forChannel: 2) == 2)
	}

	@Test(
		"bucket counts strictly-exceeded thresholds, matching compressed_dc.cc's > comparison"
	)
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
