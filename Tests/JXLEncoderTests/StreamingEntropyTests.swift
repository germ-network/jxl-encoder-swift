import Foundation
import Testing

@testable import JXLEncoder

#if canImport(ImageIO)
	import ImageIO
#endif

/// Frames above eight groups are coded the way libjxl streams them: histograms,
/// coefficient order, block model and modular trees are built DC group by DC
/// group rather than over the whole frame. Frames at or below eight groups keep
/// the one-shot coding, which the existing byte-equality tests pin.
@Suite("Streaming entropy")
struct StreamingEntropyTests {
	static func groupData(widthInBlocks: Int, heightInBlocks: Int) -> DCGroupData {
		var data = DCGroupData(
			widthInBlocks: widthInBlocks, heightInBlocks: heightInBlocks)
		data.extraDCPrecision = 1
		for channel in data.quantDC.indices {
			for index in data.quantDC[channel].indices {
				data.quantDC[channel][index] =
					Int32((index * 7 + channel * 3) % 23) - 11
			}
		}
		for index in data.rawQuantField.indices {
			data.rawQuantField[index] = UInt8(1 + index % 5)
		}
		return data
	}

	static func gradient(width: Int, height: Int) throws -> ImageBuffer {
		var samples = [UInt8](repeating: 0, count: width * height * 3)
		for y in 0..<height {
			for x in 0..<width {
				let i = (y * width + x) * 3
				samples[i] = UInt8((x * 255) / width)
				samples[i + 1] = UInt8((y * 255) / height)
				samples[i + 2] = UInt8(((x + y) * 255) / (width + height))
			}
		}
		return try ImageBuffer(width: width, height: height, samples: samples)
	}

	/// Decodes with ImageIO where it is available. Elsewhere the semantic
	/// cross-check against the reference decoder covers this.
	static func expectDecodes(_ bytes: [UInt8], width: Int, height: Int) throws {
		#if canImport(ImageIO)
			let source = try #require(
				CGImageSourceCreateWithData(Data(bytes) as CFData, nil))
			let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
			#expect(image.width == width)
			#expect(image.height == height)
			let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
			let context = try #require(
				CGContext(
					data: nil, width: width, height: height,
					bitsPerComponent: 8,
					bytesPerRow: width * 4, space: colorSpace,
					bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
			context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
			let raw = try #require(context.data).bindMemory(
				to: UInt8.self, capacity: width * height * 4)
			var total = 0
			for y in 0..<height {
				for x in 0..<width {
					let expected = [
						(x * 255) / width, (y * 255) / height,
						((x + y) * 255) / (width + height),
					]
					for c in 0..<3 {
						total += abs(
							expected[c]
								- Int(raw[(y * width + x) * 4 + c]))
					}
				}
			}
			#expect(Double(total) / Double(width * height * 3) < 4.0)
		#endif
	}

	/// Groups whose content differs between the first eight (DC group 0) and
	/// the last, so a frame-wide statistic differs from DC group 0's.
	static func syntheticComputes(dim: ImageDim) -> [Encoder.ACGroupCompute] {
		(0..<dim.groupCount).map { index in
			let groupX = index % dim.widthInGroups
			let groupY = index / dim.widthInGroups
			let blocks = 32 * 32
			let inLaterDCGroup = groupX >= 8
			let coefficients = (0..<3).map { channel in
				(0..<blocks * 64).map { offset -> Int32 in
					let position = offset % 64
					let block = offset / 64
					if inLaterDCGroup {
						return position >= 40 && (block + channel) % 3 != 0
							? 1 : 0
					}
					return position < 12 && (block + position) % 2 == 0 ? 1 : 0
				}
			}
			return Encoder.ACGroupCompute(
				groupX: groupX, groupY: groupY, widthInBlocks: 32,
				heightInBlocks: 32,
				coefficients: coefficients,
				rawDC: (0..<3).map { _ in [Float](repeating: 0, count: blocks) },
				quantField: (0..<blocks).map {
					inLaterDCGroup ? UInt8(1 + $0 % 40) : UInt8(1 + $0 % 3)
				})
		}
	}

	/// One staged AC section per histogram set, tokens placed in the set's
	/// slice of the context space.
	static func stagedSets(
		setCount: Int, contextsPerSet: Int, _ values: (Int, Int) -> [UInt32]
	) -> [SectionWriter] {
		(0..<setCount).map { set in
			var section = SectionWriter(
				mode: .staging(.staticAC),
				contextOffset: UInt32(set * contextsPerSet))
			for context in 0..<contextsPerSet {
				for value in values(set, context) {
					section.write(
						token: Token(context: UInt32(context), value: value)
					)
				}
			}
			return section
		}
	}

	static func histogram(_ counts: [Int: UInt32]) -> Histogram {
		var histogram = Histogram()
		for (symbol, count) in counts {
			for _ in 0..<count { histogram.add(UInt32(symbol)) }
		}
		return histogram
	}

	// MARK: One-context codes

	@Test(
		"a code with one context transmits no context map")
	func oneContextCodeWritesNoContextMap() throws {
		let tokens = (0..<40).map { Token(context: 0, value: UInt32($0 % 5)) }
		let one = SectionOptimizer.modularCode(
			tokenStreams: [tokens], contextCount: 1, extraDCPrecision: 0)
		#expect(one.transmittedContextCount == 1)
		var writer = BitWriter()
		EntropyCodeWriter.writeContextMap(one, writer: &writer)
		#expect(writer.bitsWritten == 0)

		let two = SectionOptimizer.modularCode(
			tokenStreams: [tokens + [Token(context: 1, value: 3)]],
			contextCount: 2, extraDCPrecision: 0)
		var twoWriter = BitWriter()
		EntropyCodeWriter.writeContextMap(two, writer: &twoWriter)
		#expect(twoWriter.bitsWritten > 0)
	}

	@Test(
		"a single-leaf modular stream decodes in the native decoder")
	func oneContextCodeRoundTripsThroughNativeDecoder() throws {
		// 2057x257's second DC group is two blocks wide: its local DC and
		// metadata trees are single leaves, so both payload codes have one
		// context and must carry no context map.
		let image = try Self.gradient(width: 2057, height: 257)
		let local = try DCGroupEncoder.localStreams(
			data: Self.groupData(widthInBlocks: 2, heightInBlocks: 33))
		#expect(local.dc.code.contextCount == 1)
		#expect(local.metadata.code.contextCount == 1)
		try Self.expectDecodes(
			Encoder.encode(image, distance: 1), width: 2057, height: 257)
	}

	// MARK: Clustering against earlier DC groups

	@Test(
		"the first new cluster is always promoted, from the context farthest by KL")
	func fastClusterStartsFromFarthestByKLDivergence() throws {
		let previous = [Self.histogram([0: 500, 1: 500])]
		let input = [
			Self.histogram([0: 90, 1: 90]),
			Self.histogram([10: 20, 11: 20]),
			Self.histogram([0: 40, 1: 40]),
		]
		let far = HistogramCluster.fastCluster(
			input, maxHistograms: 1, previous: previous)
		#expect(far.symbols == [0, 1, 0])
		#expect(far.clusters.count == 1)

		// Every context already matches the earlier histogram, so no
		// divergence is positive and the largest context starts the cluster.
		let same = [
			Self.histogram([0: 30, 1: 30]), Self.histogram([0: 90, 1: 90]),
			Self.histogram([0: 40, 1: 40]),
		]
		let fallback = HistogramCluster.fastCluster(
			same, maxHistograms: 1, previous: previous)
		#expect(fallback.symbols[1] == 1)
	}

	@Test(
		"with no budget left every context goes to an earlier histogram")
	func exhaustedBudgetAssignsEveryContextToPrevious() throws {
		let previous = [
			Self.histogram([0: 500, 1: 500]), Self.histogram([10: 500, 11: 500]),
		]
		let input = [
			Self.histogram([0: 9, 1: 11]), Histogram(),
			Self.histogram([10: 7, 11: 5]),
		]
		let result = HistogramCluster.fastCluster(
			input, maxHistograms: 0, previous: previous)
		#expect(result.clusters.isEmpty)
		#expect(result.symbols == [0, 0, 1])
	}

	@Test(
		"contexts close to an earlier histogram reuse it by KL divergence")
	func fastClusterAssignsToPreviousByKLDivergence() throws {
		let previous = [
			Self.histogram([0: 500, 1: 500]), Self.histogram([10: 500, 11: 500]),
		]
		let input = [
			Self.histogram([10: 30, 11: 25]),
			Self.histogram([0: 20, 1: 30]),
			Self.histogram([10: 5, 11: 2]),
			Self.histogram([30: 100]),
		]
		let result = HistogramCluster.fastCluster(
			input, maxHistograms: 1, previous: previous)
		#expect(result.symbols == [1, 0, 1, 2])
		// A tiny earlier histogram is cheap to merge into by `distance` even
		// when it codes the context worse; KL picks the better code.
		let closer = HistogramCluster.fastCluster(
			[Self.histogram([0: 10, 1: 10])], maxHistograms: 0,
			previous: [
				Self.histogram([0: 700, 1: 300]), Self.histogram([0: 1, 1: 3]),
			])
		#expect(closer.symbols == [0])
		let missing = HistogramCluster.klDivergence(
			Self.histogram([0: 4, 5: 4]), coding: previous[0])
		#expect(missing == .infinity)
		#expect(
			HistogramCluster.klDivergence(
				Self.histogram([0: 4, 1: 4]), coding: previous[0]) < 0.01)
		#expect(
			HistogramCluster.klDivergence(Histogram(), coding: previous[0]) == 0)
		#expect(result.clusters.count == 1)
	}

	@Test(
		"new clusters are numbered after previous ones and only they absorb counts")
	func fastClusterPromotesOnlyBeyondPrevious() throws {
		let previous = [Self.histogram([0: 500, 1: 500])]
		let input = [
			Self.histogram([20: 1000]), Self.histogram([40: 1000, 41: 1000]),
			Self.histogram([40: 10, 41: 10]), Self.histogram([0: 4, 1: 6]),
		]
		let result = HistogramCluster.fastCluster(
			input, maxHistograms: 2, previous: previous)
		#expect(result.clusters.count == 2)
		#expect(Set(result.symbols[0...1]) == [1, 2])
		#expect(result.symbols[2] == result.symbols[1])
		#expect(result.symbols[3] == 0)
		let absorbed = result.clusters[Int(result.symbols[1]) - 1]
		#expect(absorbed.totalCount == 2020)
		let untouched = result.clusters[Int(result.symbols[0]) - 1]
		#expect(untouched.totalCount == 1000)
	}

	@Test("promotion stops once contexts are close to a new cluster")
	func fastClusterStopsBelowDistinctDistanceAfterPrevious() throws {
		let result = HistogramCluster.fastCluster(
			[Self.histogram([10: 20, 11: 20]), Self.histogram([10: 21, 11: 19])],
			maxHistograms: 2, previous: [Self.histogram([0: 500, 1: 500])])
		#expect(result.clusters.count == 1)
		#expect(result.symbols == [1, 1])
	}

	@Test(
		"encoded histograms read back as ANS frequencies or 2^(15-depth)")
	func previousHistogramFromEncodedCodes() throws {
		var source = Self.histogram([0: 700, 1: 200, 2: 100])
		source.computeBitCost()
		let encoded = ANSEncodingHistogram.computeBest(
			counts: source.counts, strategy: .fast)
		let fromANS = Histogram(encodedANS: encoded)
		#expect(fromANS.counts.map(Int.init) == encoded.normalizedCounts)
		#expect(fromANS.totalCount == encoded.normalizedCounts.reduce(0, +))

		let prefix = PrefixCode(depths: [1, 2, 0, 2], bits: [0, 1, 0, 3])
		let fromPrefix = Histogram(encodedPrefix: prefix)
		#expect(fromPrefix.counts == [16384, 8192, 0, 8192])
		#expect(fromPrefix.totalCount == 32768)
		let lone = Histogram(
			encodedPrefix: PrefixCode(depths: [0, 1, 0], bits: [0, 0, 0]))
		#expect(lone.totalCount == 0)
	}

	// MARK: Local DC modular streams

	@Test(
		"each DC group's local trees are sized by that group's own pixels")
	func localTreesUseEachDCGroupsOwnPixelCount() throws {
		let large = DCGroupData(widthInBlocks: 32, heightInBlocks: 32)
		let small = DCGroupData(widthInBlocks: 9, heightInBlocks: 3)
		// 18 + 1200 metadata pixels is above libjxl's 1024 cut; 18 + 800 is not.
		let boundary = ContextTree.prepareLocal(
			group: DCGroupData(widthInBlocks: 20, heightInBlocks: 20))
		#expect(boundary.metadata.contextCount > 1)
		let largeTrees = ContextTree.prepareLocal(group: large)
		let smallTrees = ContextTree.prepareLocal(group: small)
		// A small group's DC image is too short for a gap-8 split chain, and
		// its control fields too short for the metadata tree.
		#expect(smallTrees.dc.contextCount == 1)
		#expect(smallTrees.metadata.contextCount == 1)
		#expect(largeTrees.dc.contextCount > 1)
		#expect(largeTrees.metadata.contextCount > 1)
		#expect(largeTrees.dc.dcGroupCount == 1)
	}

	@Test(
		"a streaming DC global section carries no modular tree")
	func streamingDCGlobalWritesNoTree() throws {
		let params = try DistanceParams(distance: 1)
		let map = JPEGBlockContextMap.Result.pixelDefault
		var streaming = BitWriter()
		try FrameAssembly.writeStreamingDCGlobal(
			params: params, blockContextMap: map, writer: &streaming)
		var global = BitWriter()
		try FrameAssembly.writeDCGlobal(
			params: params, dcGroupCount: 2, code: .staticDC,
			blockContextMap: map, writer: &global)
		let sharedBits = streaming.bitsWritten - 1
		var padded = streaming
		padded.zeroPadToByte()
		func bit(_ writer: BitWriter, _ index: Int) -> UInt8 {
			(writer.bytes[index / 8] >> UInt8(index % 8)) & 1
		}
		var copy = global
		copy.zeroPadToByte()
		#expect(global.bitsWritten > streaming.bitsWritten + 64)
		for index in 0..<sharedBits {
			#expect(bit(padded, index) == bit(copy, index), "bit \(index)")
		}
		#expect(bit(padded, sharedBits) == 0)
	}

	@Test(
		"each local stream writes GroupHeader without the global tree and its own no-lz77 codes"
	)
	func localStreamsWriteOwnHeaderAndCodes() throws {
		let data = Self.groupData(widthInBlocks: 32, heightInBlocks: 32)
		let local = try DCGroupEncoder.localStreams(data: data)
		#expect(local.dc.treeCode.contextCount == ContextTree.treeContextCount)
		#expect(local.dc.code.contextCount == local.dc.tree.contextCount)
		#expect(local.metadata.code.contextCount == local.metadata.tree.contextCount)
		var writer = BitWriter()
		try DCGroupEncoder.write(data: data, local: local, writer: &writer)
		writer.zeroPadToByte()
		let bytes = writer.bytes
		#expect(bytes[0] & 0b11 == 1)  // extra_dc_precision
		#expect((bytes[0] >> 2) & 0b1111 == 2)  // use_global_tree = 0
		#expect((bytes[0] >> 6) & 1 == 0)  // tree histograms: no lz77

		var expected = BitWriter()
		expected.write(2, 1)
		for (position, stream) in [local.dc, local.metadata].enumerated() {
			expected.write(4, 2)
			expected.write(1, 0)
			EntropyCodeWriter.write(stream.treeCode, writer: &expected)
			EntropyCodeWriter.writeTokens(
				stream.tree.tokens, code: stream.treeCode, writer: &expected)
			expected.write(1, 0)
			EntropyCodeWriter.write(stream.code, writer: &expected)
			EntropyCodeWriter.writeTokens(
				stream.tokens, code: stream.code, writer: &expected)
			if position == 0 {
				let blocks = data.widthInBlocks * data.heightInBlocks
				expected.write(
					Int.bitWidth - (blocks - 1).leadingZeroBitCount,
					UInt64(blocks - 1))
			}
		}
		expected.zeroPadToByte()
		#expect(bytes == expected.bytes)
	}

	@Test(
		"local stream codes keep the default uint config and log_alpha 8")
	func streamingModularCodeUsesDefaultUintAndLogAlpha8() throws {
		var tokens: [Token] = []
		for i in 0..<400 {
			tokens.append(Token(context: 0, value: UInt32(300 + (i * 37) % 700)))
			tokens.append(Token(context: 1, value: UInt32(i % 7)))
		}
		let searched = SectionOptimizer.modularCode(
			tokenStreams: [tokens], contextCount: 2, extraDCPrecision: 1)
		let streaming = SectionOptimizer.modularCode(
			tokenStreams: [tokens], contextCount: 2, extraDCPrecision: 1,
			streaming: true)
		let defaultConfiguration = HybridUintConfiguration(
			splitExponent: 4, msbInToken: 2, lsbInToken: 0)
		#expect(
			(searched.uintConfigurations ?? []).contains { $0 != defaultConfiguration })
		#expect(
			(streaming.uintConfigurations ?? []).allSatisfy {
				$0 == defaultConfiguration
			})
		#expect(streaming.ansHistograms != nil)
		#expect(streaming.logAlphabetSize == 8)
	}

	@Test(
		"streaming output above eight groups decodes independently")
	func streamingOutputAboveEightGroupsDecodes() throws {
		for (width, height) in [(2304, 256), (2057, 257)] {
			let image = try Self.gradient(width: width, height: height)
			try Self.expectDecodes(
				Encoder.encode(image, distance: 1), width: width, height: height)
		}
	}

	// MARK: DC group 0 heuristics

	@Test(
		"the coefficient order comes from DC group 0 alone")
	func streamingCoeffOrderUsesDCGroupZeroOnly() throws {
		let dim = ImageDim(width: 2304, height: 256)
		let params = try DistanceParams(distance: 1)
		let computes = Self.syntheticComputes(dim: dim)
		let plan = FramePlan(dim: dim, upsampling: 1)
		let dcZero = computes.filter {
			plan.histogramIndex(groupX: $0.groupX, groupY: $0.groupY) == 0
		}
		#expect(dcZero.count == 8)
		let expected = Encoder.computeCoeffOrder(
			dcZero, dim: ImageDim(width: 2048, height: 256))
		let allGroups = Encoder.computeCoeffOrder(computes, dim: dim)
		#expect(allGroups.orders != expected.orders)

		let analysis = Encoder.analyzePixelFrame(
			computes: computes, dim: dim, params: params, optimizeCodes: true)
		#expect(analysis.coeffOrder.orders == expected.orders)
		#expect(analysis.coeffOrder.isCustom == expected.isCustom)
	}

	@Test(
		"the block context map comes from DC group 0 alone")
	func streamingBlockContextMapUsesDCGroupZeroOnly() throws {
		let dim = ImageDim(width: 2304, height: 256)
		let params = try DistanceParams(distance: 1)
		let computes = Self.syntheticComputes(dim: dim)
		let plan = FramePlan(dim: dim, upsampling: 1)
		let dcZero = computes.filter {
			plan.histogramIndex(groupX: $0.groupX, groupY: $0.groupY) == 0
		}
		let expected = Encoder.computeBlockContextMap(dcZero, params: params)
		let allGroups = Encoder.computeBlockContextMap(computes, params: params)
		#expect(allGroups.contextMap != expected.contextMap)

		let analysis = Encoder.analyzePixelFrame(
			computes: computes, dim: dim, params: params, optimizeCodes: true)
		#expect(analysis.blockContextMap?.contextMap == expected.contextMap)
		#expect(analysis.blockContextMap?.numContexts == expected.numContexts)
	}

	// MARK: Per-DC-group AC histograms

	@Test(
		"each set adds at most the budget left by earlier sets")
	func streamingBudgetLimitsNewClustersPerSet() throws {
		#expect(SectionOptimizer.streamingClusterBudget(previousHistograms: 1) == 31)
		#expect(SectionOptimizer.streamingClusterBudget(previousHistograms: 32) == 24)
		#expect(SectionOptimizer.streamingClusterBudget(previousHistograms: 108) == 5)
		#expect(SectionOptimizer.streamingClusterBudget(previousHistograms: 109) == 4)
		#expect(SectionOptimizer.streamingClusterBudget(previousHistograms: 126) == 2)
		#expect(SectionOptimizer.streamingClusterBudget(previousHistograms: 128) == 0)

		// Every context of every set differs, so each set uses all its budget.
		var sections = Self.stagedSets(setCount: 3, contextsPerSet: 200) { set, context in
			(0..<40).map {
				UInt32(
					$0 % 2 == 0
						? (context + set) % 50 : (context * 7 + set) % 50)
			}
		}
		let code = SectionOptimizer.optimizeStreaming(
			sections: &sections, range: 0..<3, histogramSetCount: 3,
			contextsPerSet: 200)
		let count = code.ansHistograms?.count ?? code.prefixCodeCount
		var budget = 1
		for _ in 0..<3 {
			budget += SectionOptimizer.streamingClusterBudget(
				previousHistograms: budget)
		}
		#expect(count <= budget)
		#expect(count > 31)
	}

	@Test(
		"the first set's prefix-or-ANS choice holds for every set")
	func firstSetDecidesPrefixForAllSets() throws {
		let busy: (Int, Int) -> [UInt32] = { _, context in
			(0..<30).map { UInt32(($0 * (context + 2)) % 17) }
		}
		let quiet: (Int, Int) -> [UInt32] = { _, context in [UInt32(context % 3)] }
		var shortFirst = Self.stagedSets(setCount: 2, contextsPerSet: 10) { set, context in
			set == 0 ? quiet(set, context) : busy(set, context)
		}
		let prefix = SectionOptimizer.optimizeStreaming(
			sections: &shortFirst, range: 0..<2, histogramSetCount: 2,
			contextsPerSet: 10)
		#expect(prefix.ansHistograms == nil)

		var longFirst = Self.stagedSets(setCount: 2, contextsPerSet: 10) { set, context in
			set == 0 ? busy(set, context) : quiet(set, context)
		}
		let ans = SectionOptimizer.optimizeStreaming(
			sections: &longFirst, range: 0..<2, histogramSetCount: 2,
			contextsPerSet: 10)
		#expect(ans.ansHistograms != nil)
	}

	@Test(
		"empty first-set contexts map to the fixed flat histogram, which keeps its first-use index"
	)
	func emptyContextsUseFixedHistogramAtFirstUse() throws {
		func map(emptyContext: Int) -> [UInt8] {
			var sections = Self.stagedSets(setCount: 1, contextsPerSet: 4) {
				_, context in
				context == emptyContext
					? [] : (0..<60).map { UInt32(($0 * (context + 3)) % 23) }
			}
			return SectionOptimizer.optimizeStreaming(
				sections: &sections, range: 0..<1, histogramSetCount: 1,
				contextsPerSet: 4
			).contextMap
		}
		// The fixed histogram is histogram 0 before renumbering. After it, a
		// histogram keeps the index of its first use.
		let leading = map(emptyContext: 0)
		#expect(leading[0] == 0)
		#expect(
			Set(leading[1...]).count == leading[1...].count || leading[1...].min()! >= 1
		)
		#expect(leading[1...].allSatisfy { $0 >= 1 })
		let trailing = map(emptyContext: 3)
		#expect(trailing[0] == 0)
		#expect(trailing[3] == (trailing[0..<3].max() ?? 0) + 1)
	}

	@Test(
		"under prefix coding the fixed histogram is an 8-bit code read back as 2^7 per symbol"
	)
	func fixedHistogramPrefixFormIsDepthEight() throws {
		var sections = Self.stagedSets(setCount: 1, contextsPerSet: 3) { _, context in
			context == 1 ? [] : [UInt32(context), 3]
		}
		let code = SectionOptimizer.optimizeStreaming(
			sections: &sections, range: 0..<1, histogramSetCount: 1, contextsPerSet: 3)
		#expect(code.ansHistograms == nil)
		let fixed = code.prefixCodes[Int(code.contextMap[1])]
		#expect(fixed.depths.count == 256)
		#expect(fixed.depths.allSatisfy { $0 == 8 })
		#expect(Histogram(encodedPrefix: fixed).counts.allSatisfy { $0 == 128 })
	}

	@Test(
		"unused histograms are dropped and the rest renumbered by first use")
	func removeUnusedHistogramsRenumbersByFirstUse() throws {
		var sections = Self.stagedSets(setCount: 1, contextsPerSet: 3) { _, context in
			(0..<60).map { UInt32(($0 * (context * 5 + 3)) % 29) }
		}
		let code = SectionOptimizer.optimizeStreaming(
			sections: &sections, range: 0..<1, histogramSetCount: 1, contextsPerSet: 3)
		// Every context is used, so the fixed histogram is unreferenced and
		// dropped; the rest number by first use.
		let count = code.ansHistograms?.count ?? code.prefixCodeCount
		#expect(Set(code.contextMap).count == count)
		#expect(
			code.contextMap == [0, 1, 2].prefix(count).map { $0 }
				+ [0, 0, 0].prefix(3 - count))
		#expect(count <= 3)
	}

	@Test(
		"later sets reuse earlier histograms without changing them")
	func laterSetsReuseEarlierHistogramsUnchanged() throws {
		let contexts: (Int, Int) -> [UInt32] = { _, context in
			(0..<40).map { UInt32(($0 * (context % 5 + 1)) % 19) }
		}
		var one = Self.stagedSets(setCount: 1, contextsPerSet: 12, contexts)
		let single = SectionOptimizer.optimizeStreaming(
			sections: &one, range: 0..<1, histogramSetCount: 1, contextsPerSet: 12)
		var two = Self.stagedSets(setCount: 2, contextsPerSet: 12, contexts)
		let double = SectionOptimizer.optimizeStreaming(
			sections: &two, range: 0..<2, histogramSetCount: 2, contextsPerSet: 12)
		let singleCount = single.ansHistograms?.count ?? single.prefixCodeCount
		let doubleCount = double.ansHistograms?.count ?? double.prefixCodeCount
		// The second set repeats the first. Clustering always promotes one new
		// histogram, and every context of the set then lands in it.
		#expect(doubleCount == singleCount + 1)
		#expect(Set(double.contextMap[12...]).count == 1)
		#expect(double.contextMap[..<12] == single.contextMap[...])
		if let first = single.ansHistograms, let both = double.ansHistograms {
			#expect(
				both.prefix(first.count).map(\.normalizedCounts)
					== first.map(\.normalizedCounts))
		}
	}
}
