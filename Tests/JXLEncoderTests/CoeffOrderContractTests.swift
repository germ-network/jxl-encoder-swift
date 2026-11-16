import Testing

@testable import JXLEncoder

@Suite("Coefficient ordering")
struct CoeffOrderContractTests {
	private func histograms(from fixture: EntropyReferenceFixture) throws -> [Histogram] {
		let lengths = try fixture.integers(fixture.input, "input.clusters.lengths").map(
			Int.init)
		let counts = try fixture.integers(fixture.input, "input.clusters.counts").map(
			UInt32.init)
		var offset = 0
		return lengths.map { length in
			var histogram = Histogram()
			for symbol in 0..<length {
				for _ in 0..<counts[offset + symbol] {
					histogram.add(UInt32(symbol))
				}
			}
			offset += length
			return histogram
		}
	}

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

		func group(x: Int, width: Int, zeros: [(position: Int, blocks: Int)])
			-> Encoder.ACGroupCompute
		{
			var plane = [Int32](repeating: 1, count: width * DCT.blockSize)
			for (position, blocks) in zeros {
				for block in 0..<blocks {
					plane[block * DCT.blockSize + position] = 0
				}
			}
			return Encoder.ACGroupCompute(
				groupX: x, groupY: 0, widthInBlocks: width, heightInBlocks: 1,
				coefficients: [
					plane, [Int32](repeating: 1, count: width * DCT.blockSize),
					[Int32](repeating: 1, count: width * DCT.blockSize),
				], rawDC: [], quantField: [])
		}
		let first = group(
			x: 0, width: 32,
			zeros: [
				(position: CoeffOrder.natural[1], blocks: 8),
				(position: CoeffOrder.natural[2], blocks: 1),
			])
		let second = group(
			x: 1, width: 12,
			zeros: [(position: CoeffOrder.natural[2], blocks: 7)])
		let dim = ImageDim(width: 352, height: 8)
		let raster = Encoder.computeCoeffOrder([first, second], dim: dim)
		let shuffled = Encoder.computeCoeffOrder([second, first], dim: dim)
		var sampledCounts = [CoeffOrder.ZeroCounts](
			repeating: CoeffOrder.ZeroCounts(), count: 3)
		var continuousSampler = CoeffOrder.Sampler()
		CoeffOrder.accumulateGroup(
			first.coefficients, widthInBlocks: 32, heightInBlocks: 1,
			sampler: &continuousSampler, counts: &sampledCounts)
		CoeffOrder.accumulateGroup(
			second.coefficients, widthInBlocks: 12, heightInBlocks: 1,
			sampler: &continuousSampler, counts: &sampledCounts)
		#expect(sampledCounts[0].counts[CoeffOrder.natural[1]] == 8)
		#expect(sampledCounts[0].counts[CoeffOrder.natural[2]] == 5)
		let expected = CoeffOrder.compute(
			counts: sampledCounts, widthInBlocks: 44, heightInBlocks: 1)
		#expect(raster.orders == expected.orders)
		#expect(shuffled.orders == expected.orders)
		var resetCounts = [CoeffOrder.ZeroCounts](
			repeating: CoeffOrder.ZeroCounts(), count: 3)
		for compute in [first, second] {
			var sampler = CoeffOrder.Sampler()
			CoeffOrder.accumulateGroup(
				compute.coefficients, widthInBlocks: compute.widthInBlocks,
				heightInBlocks: compute.heightInBlocks, sampler: &sampler,
				counts: &resetCounts)
		}
		let reset = CoeffOrder.compute(
			counts: resetCounts, widthInBlocks: 44, heightInBlocks: 1)
		#expect(resetCounts[0].counts[CoeffOrder.natural[1]] == 8)
		#expect(resetCounts[0].counts[CoeffOrder.natural[2]] == 8)
		#expect(reset.orders != expected.orders)
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

	@Test
	func usedOrdersSelectorMatchesSourceBranches() throws {
		var defaultWriter = BitWriter()
		try FrameAssembly.writeACGlobal(
			groupCount: 1, code: .staticAC, coeffOrder: .identity,
			writer: &defaultWriter)
		#expect(defaultWriter.bytes[0] & 0x0F == 0x05)
		#expect(defaultWriter.bitsWritten == 4519)

		var customOrder = CoeffOrder.natural
		customOrder[1...].reverse()
		let custom = CoeffOrder.Result(
			orders: [customOrder, customOrder, customOrder], isCustom: true)
		var customWriter = BitWriter()
		try FrameAssembly.writeACGlobal(
			groupCount: 1, code: .staticAC, coeffOrder: custom,
			writer: &customWriter)
		#expect(Array(customWriter.bytes.prefix(2)) == [0x0F, 0x00])
	}

	@Test
	func permutationClusteringPreservesSourceMergeAndTieRules() throws {
		for name in [
			"clusters_best_pair_merge", "clusters_best_merge",
			"clusters_best_survive", "clusters_best_identical",
		] {
			let fixture = try EntropyReferenceFixture.load(name)
			let result = HistogramCluster.clusterBest(try histograms(from: fixture))
			let expectedCount = try fixture.integers(
				fixture.expected, "entropy.clusters.count")[0]
			let expectedMap = try fixture.integers(
				fixture.expected, "entropy.clusters.map"
			).map(UInt8.init)
			let expectedCounts = try fixture.integers(
				fixture.expected, "entropy.clusters.histogram_counts"
			).map(UInt32.init)
			#expect(
				result.clusters.count == Int(expectedCount), Comment(rawValue: name)
			)
			#expect(result.contextMap == expectedMap, Comment(rawValue: name))
			if name == "clusters_best_pair_merge" {
				let actualCounts = result.clusters.flatMap { histogram in
					let alphabetSize =
						histogram.counts.lastIndex(where: { $0 != 0 }).map {
							$0 + 1
						}
						?? 0
					return histogram.counts.prefix(alphabetSize)
				}
				#expect(actualCounts == expectedCounts)
			}
		}
	}

	@Test
	func permutationRunsPreserveContextsAndThresholds() {
		let values = (0..<128).map { UInt32($0 % 64) } + [UInt32](repeating: 63, count: 40)
		let tokens = values.enumerated().map {
			Token(
				context: UInt32($0.offset % CoeffOrder.permutationContexts),
				value: $0.element)
		}
		let result = ContextMapEntropy.runLengthEncode(
			tokens, contextCount: CoeffOrder.permutationContexts)
		#expect(result.enabled)
		let lengths = result.tokens.filter(\.isLength)
		#expect(lengths.count == 1)
		guard let length = lengths.first else { return }
		#expect(length.token.context == tokens[128].context)
		#expect(length.token.value == 37)
		#expect(result.tokens[129].token.context == 8)
		#expect(result.tokens[129].token.value == 0)
		let short = ContextMapEntropy.runLengthEncode(
			[
				Token(context: 0, value: 4), Token(context: 1, value: 4),
				Token(context: 2, value: 4),
			],
			contextCount: CoeffOrder.permutationContexts)
		#expect(!short.enabled)
	}

	@Test
	func permutationHybridSelectionPreservesCandidateTiesAndLengths() {
		let tiedTokens = (0..<128).map {
			Token(context: 0, value: UInt32($0 % 3))
		}
		#expect(
			CoeffOrder.preparePermutation(tiedTokens).code.uintConfigurations?.first
				== HybridUintConfiguration(
					splitExponent: 3, msbInToken: 2, lsbInToken: 0))
		let tieTokens = (0..<128).map {
			Token(context: UInt32($0 % 8), value: UInt32($0 % 16))
		}
		let tieResult = CoeffOrder.preparePermutation(tieTokens)
		#expect(tieResult.runLength.enabled == false)
		#expect(
			tieResult.code.uintConfigurations?.first
				== HybridUintConfiguration(
					splitExponent: 3, msbInToken: 2, lsbInToken: 1))
		let wideTokens = (0..<128).map {
			Token(context: UInt32($0 % 8), value: UInt32(($0 * 17) % 64))
		}
		let wideResult = CoeffOrder.preparePermutation(wideTokens)
		#expect(
			wideResult.code.uintConfigurations?.first
				!= HybridUintConfiguration(
					splitExponent: 4, msbInToken: 2, lsbInToken: 0))
	}

	@Test
	func permutationEntropyUsesDefaultSourcePolicy() {
		var reversed = CoeffOrder.natural
		reversed[1...].reverse()
		let one = CoeffOrder.tokens(forChannelOrder: reversed)
		let oneResult = CoeffOrder.preparePermutation(one)
		#expect(one.count < 100)
		#expect(oneResult.code.ansHistograms == nil)
		#expect(!oneResult.runLength.enabled)
		let twoResult = CoeffOrder.preparePermutation(one + one)
		#expect((one + one).count >= 100)
		#expect(twoResult.code.ansHistograms != nil)
		let runTokens =
			(0..<128).map { Token(context: UInt32($0 % 8), value: UInt32($0 % 64)) }
			+ [Token](repeating: Token(context: 0, value: 63), count: 40)
		let runResult = CoeffOrder.preparePermutation(runTokens)
		#expect(runResult.runLength.enabled)
		#expect(runResult.code.logAlphabetSize == 8)
		#expect(runResult.code.ansHistograms != nil)
		let lengthContext = Int(
			runResult.code.contextMap[
				Int(
					runResult.runLength.tokens.first(where: \.isLength)!.token
						.context)])
		#expect(runResult.code.ansInfoTables?[lengthContext][230].freq != 0)
	}

	@Test
	func permutationConfiguredTokensSerialize() {
		let prefixTokens = CoeffOrder.tokens(
			forChannelOrder: {
				var order = CoeffOrder.natural
				order[1...].reverse()
				return order
			}())
		let prefix = CoeffOrder.preparePermutation(prefixTokens)
		var prefixWriter = BitWriter()
		EntropyCodeWriter.write(prefix.code, writer: &prefixWriter)
		EntropyCodeWriter.writeTokens(
			prefix.runLength.tokens, code: prefix.code,
			lengthConfiguration: HybridUintConfiguration(
				splitExponent: 0, msbInToken: 0, lsbInToken: 0),
			lengthSymbolOffset: 224, writer: &prefixWriter)
		#expect(prefixWriter.bitsWritten == 434)
		#expect(
			prefixWriter.bytes == [
				89, 122, 249, 113, 120, 235, 20, 130, 240, 255, 222, 231, 190, 206,
				99, 223, 214, 101, 158, 198, 161, 239, 218, 166, 174, 202, 34, 207,
				210, 36, 142, 194, 192, 247, 92, 199, 182, 76, 67, 215, 84, 69, 150,
				68, 129, 231, 88, 134, 166, 72, 2, 199, 80, 4, 0,
			])
		#expect(!prefix.runLength.enabled)
		var ordinaryPrefixWriter = BitWriter()
		EntropyCodeWriter.write(prefix.code, writer: &ordinaryPrefixWriter)
		EntropyCodeWriter.writeTokens(
			prefixTokens, code: prefix.code, writer: &ordinaryPrefixWriter)
		#expect(ordinaryPrefixWriter.bytes == prefixWriter.bytes)

		let runTokens =
			(0..<128).map { Token(context: UInt32($0 % 8), value: UInt32($0 % 64)) }
			+ [Token](repeating: Token(context: 0, value: 63), count: 40)
		let ans = CoeffOrder.preparePermutation(runTokens)
		var ansWriter = BitWriter()
		EntropyCodeWriter.write(ans.code, writer: &ansWriter)
		EntropyCodeWriter.writeTokens(
			ans.runLength.tokens, code: ans.code,
			lengthConfiguration: HybridUintConfiguration(
				splitExponent: 0, msbInToken: 0, lsbInToken: 0),
			lengthSymbolOffset: 224, writer: &ansWriter)
		#expect(ansWriter.bitsWritten == 901)
		#expect(
			ansWriter.bytes == [
				113, 105, 60, 25, 10, 110, 102, 12, 126, 136, 9, 144, 9, 0, 69, 20,
				233, 52, 33, 85, 197, 117, 65, 166, 185, 182, 88, 215, 200, 87, 66,
				88, 218, 56, 194, 97, 170, 121, 18, 162, 72, 194, 67, 155, 159, 2,
				96, 28, 203, 188, 31, 99, 75, 131, 99, 163, 192, 206, 80, 255, 217,
				255, 69, 20, 233, 52, 33, 85, 197, 117, 65, 166, 185, 182, 88, 215,
				200, 87, 66, 88, 218, 56, 194, 97, 170, 121, 18, 162, 72, 194, 67,
				155, 159, 2, 96, 28, 203, 188, 31, 99, 75, 131, 99, 163, 156, 195,
				92, 255, 208, 255, 0, 0, 5,
			])
		var ordinaryANSWriter = BitWriter()
		EntropyCodeWriter.write(ans.code, writer: &ordinaryANSWriter)
		EntropyCodeWriter.writeTokens(
			runTokens, code: ans.code, writer: &ordinaryANSWriter)
		var configuredANSWriter = BitWriter()
		EntropyCodeWriter.write(ans.code, writer: &configuredANSWriter)
		EntropyCodeWriter.writeTokens(
			runTokens.map {
				ContextMapEntropy.EncodedToken(token: $0, isLength: false)
			}, code: ans.code,
			lengthConfiguration: HybridUintConfiguration(
				splitExponent: 0, msbInToken: 0, lsbInToken: 0),
			lengthSymbolOffset: 224, writer: &configuredANSWriter)
		#expect(ordinaryANSWriter.bytes == configuredANSWriter.bytes)
	}
}
