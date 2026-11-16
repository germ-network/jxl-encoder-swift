import Testing

@testable import JXLEncoder

@Suite("Coefficient ordering")
struct CoeffOrderContractTests {
	@Test
	func sampledStatisticsFollowGroupRasterAndSourceCursor() {
		var sampler = CoeffOrder.Sampler()
		let selected = (0..<10).map { _ in sampler.next() }
		#expect(
			selected == [
				true, false, false, true, true, false, true, true, true, false,
			])

		var coefficients = [[Int32]](
			repeating: [Int32](repeating: 1, count: 10 * 64), count: 3)
		for block in 0..<3 { coefficients[0][block * 64 + 1] = 0 }
		var counts = [CoeffOrder.ZeroCounts](repeating: CoeffOrder.ZeroCounts(), count: 3)
		var accumulatorSampler = CoeffOrder.Sampler()
		CoeffOrder.accumulateGroup(
			coefficients, widthInBlocks: 10, heightInBlocks: 1,
			sampler: &accumulatorSampler, counts: &counts)
		#expect(counts[0].counts[1] == 3)
		#expect(counts[1].counts[1] == 0)

		func group(x: Int, width: Int, height: Int, zeroPosition: Int)
			-> Encoder.ACGroupCompute
		{
			var plane = [Int32](repeating: 1, count: width * height * DCT.blockSize)
			for block in 0..<(width * height) {
				plane[block * DCT.blockSize + zeroPosition] = 0
			}
			return Encoder.ACGroupCompute(
				groupX: x, groupY: 0, widthInBlocks: width, heightInBlocks: height,
				coefficients: [plane, plane, plane], rawDC: [], quantField: [])
		}
		let first = group(x: 0, width: 5, height: 5, zeroPosition: 1)
		let second = group(x: 1, width: 5, height: 1, zeroPosition: 8)
		let dim = ImageDim(width: 80, height: 40)
		let raster = Encoder.computeCoeffOrder([first, second], dim: dim)
		let shuffled = Encoder.computeCoeffOrder([second, first], dim: dim)
		#expect(raster.orders == shuffled.orders)
		#expect(raster.isCustom)
	}

	@Test(arguments: ["small_444", "small_422", "hopper_420_odd", "hopper_gray_odd"])
	func jpegSamplingUsesSourceCoefficientStorage(name: String) throws {
		let transcode = try JPEGTranscode(
			JPEGParser.parse(try JPEGParserTests.fixture(name)))
		let width = 8
		let height = 4
		let coefficients = ACGroupEncoder.jpegCoefficientsForOrdering(
			transcode: transcode, blockX0: 0, blockY0: 0,
			widthInBlocks: width, heightInBlocks: height)
		for channel in 0..<3 {
			#expect(coefficients[channel].count == width * height * DCT.blockSize)
			var compact = [Int32]()
			for y in 0..<height {
				for x in 0..<width
				where transcode.subsampling.codesBlock(
					channel: channel, blockX: x, blockY: y)
				{
					if transcode.isGrayscale && channel != 1 { continue }
					let sx = transcode.subsampling.subsampledX(
						channel: channel, blockX: x)
					let sy = transcode.subsampling.subsampledY(
						channel: channel, blockY: y)
					let component = transcode.component(channel)
					if sx < component.blocksPerLine
						&& sy < component.blocksPerColumn
					{
						compact += transcode.block(
							channel: channel, x: sx, y: sy)
					} else {
						compact += repeatElement(0, count: DCT.blockSize)
					}
				}
			}
			#expect(Array(coefficients[channel].prefix(compact.count)) == compact)
			#expect(
				coefficients[channel].dropFirst(compact.count).allSatisfy {
					$0 == 0
				})
		}
	}

	@Test
	func quantizedCountsUseFloatAndRankTies() throws {
		let fixture = try EntropyReferenceFixture.load("coefficient_sort_boundary")
		let counts = try fixture.integers(fixture.input, "input.coefficient_order.counts")
		let expected = try fixture.integers(
			fixture.expected, "entropy.coefficient_order.reference_order")
		#expect(CoeffOrder.computeOrder(counts: counts).order.map(Int64.init) == expected)
		#expect(
			CoeffOrder.computeOrder(counts: [Int64](repeating: 7, count: 64)).order
				== CoeffOrder.natural)
	}

	@Test
	func usedOrdersAndPermutationTokensMatchReference() {
		var counts = (0..<3).map { _ in CoeffOrder.ZeroCounts() }
		counts[0].counts[CoeffOrder.natural[1]] = 100
		counts[0].counts[CoeffOrder.natural[2]] = 0
		for rank in 3..<DCT.blockSize {
			counts[0].counts[CoeffOrder.natural[rank]] = 1_000
		}
		#expect(
			CoeffOrder.compute(counts: counts, widthInBlocks: 4, heightInBlocks: 4)
				.isCustom == false)
		let result = CoeffOrder.compute(counts: counts, widthInBlocks: 5, heightInBlocks: 1)
		#expect(result.isCustom)
		#expect(result.orders[0][0] == CoeffOrder.natural[0])
		#expect(result.orders[0][1] == CoeffOrder.natural[2])
		#expect(result.orders[0][2] == CoeffOrder.natural[1])
		#expect(result.orders[1] == CoeffOrder.natural)
		#expect(
			CoeffOrder.tokens(forChannelOrder: CoeffOrder.natural) == [
				Token(context: 7, value: 0)
			])
		#expect(
			CoeffOrder.tokens(forChannelOrder: result.orders[0]) == [
				Token(context: 7, value: 1), Token(context: 0, value: 1),
			])
	}

	@Test(.disabled("Pending best histogram refinement"))
	func permutationClusteringPreservesSourceMergeAndTieRules() {}

	@Test(.disabled("Pending context-aware RLE implementation"))
	func permutationRunsPreserveContextsAndThresholds() {}

	@Test(.disabled("Pending adaptive hybrid selection"))
	func permutationHybridSelectionPreservesCandidateTiesAndLengths() {}

	@Test(.disabled("Pending default entropy preparation"))
	func permutationEntropyUsesDefaultSourcePolicy() {}
}
