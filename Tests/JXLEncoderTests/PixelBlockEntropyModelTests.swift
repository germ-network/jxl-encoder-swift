import Foundation
import Testing

@testable import JXLEncoder

@Suite("Pixel block entropy model")
struct PixelBlockEntropyModelTests {
	@Test(
		"Below the truncated model-size gate, all 39 default entries and 15 categories survive."
	)
	func smallImagesRetainFullReferenceDefaultMap() throws {
		let params = try DistanceParams(distance: 1)
		let result = PixelBlockEntropyModel.compute(
			quantCounts: counts(total: 1023, quant: 1), params: params)
		#expect(result.thresholds.isEmpty)
		#expect(result.qfThresholds.isEmpty)
		#expect(
			result.contextMap == [
				0, 1, 2, 2, 3, 3, 4, 5, 6, 6, 6, 6, 6,
				7, 8, 9, 9, 10, 11, 12, 13, 14, 14, 14, 14, 14,
				7, 8, 9, 9, 10, 11, 12, 13, 14, 14, 14, 14, 14,
			])
		#expect(result.contextMap.count == 39)
		#expect(result.numContexts == 15)
	}

	private func counts(total: Int, quant: Int) -> [Int] {
		var result = [Int](repeating: 0, count: 256)
		result[quant - 1] = total
		return result
	}

	@Test(
		"Model and quant-split decisions match below, at and above truncated Float distance gates."
	)
	func modelSizeAndDistanceBoundariesMatchReference() throws {
		let below = try DistanceParams(distance: Float(1).nextDown)
		let at = try DistanceParams(distance: 1)
		let above = try DistanceParams(distance: Float(1).nextUp)
		#expect(
			PixelBlockEntropyModel.compute(
				quantCounts: counts(total: 1023, quant: 1), params: at
			).numContexts == 15)
		#expect(
			PixelBlockEntropyModel.compute(
				quantCounts: counts(total: 1023, quant: 1), params: below
			).numContexts == 3)
		#expect(
			PixelBlockEntropyModel.compute(
				quantCounts: counts(total: 1023, quant: 1), params: above
			).numContexts == 15)
		let splitCounts = counts(total: 8191, quant: 10)
		#expect(
			PixelBlockEntropyModel.compute(quantCounts: splitCounts, params: at)
				.qfThresholds.isEmpty)
		#expect(
			!PixelBlockEntropyModel.compute(quantCounts: splitCounts, params: below)
				.qfThresholds.isEmpty)
	}

	@Test(
		"Uniform and mixed quant histograms preserve strict cuts and following-index recovery, including raw quant 1, 2, 255 and 256."
	)
	func quantThresholdRecoveryMatchesReference() throws {
		let params = try DistanceParams(distance: 1)
		for (quant, expected) in [(1, 1), (2, 1), (255, 254), (256, 255)] {
			#expect(
				PixelBlockEntropyModel.compute(
					quantCounts: counts(total: 8192, quant: quant),
					params: params
				).qfThresholds == [UInt32(expected)])
		}
		var mixed = [Int](repeating: 0, count: 256)
		mixed[3] = 4096
		mixed[10] = 4096
		#expect(
			PixelBlockEntropyModel.compute(quantCounts: mixed, params: params)
				.qfThresholds == [10])
	}

	@Test(
		"Native sorting preserves complete maps for reachable 13- and 26-entry models."
	)
	func nativeSortPreservesSourceModelInvariants() throws {
		let params = try DistanceParams(distance: 1)
		for proof in [
			PixelBlockEntropyModelProofCase.small13,
			PixelBlockEntropyModelProofCase.unequalPositive26,
			PixelBlockEntropyModelProofCase.tieObservation,
		] {
			let model = PixelBlockEntropyModel.compute(
				quantCounts: proof.quantCounts, params: params)
			#expect(model.thresholds.isEmpty)
			#expect(model.qfThresholds == proof.qfThresholds)
			#expect(model.numContexts == proof.numContexts)
			#expect(model.contextMap == proof.contextMap)
			#expect(
				model.contextMap.count
					== 3 * JPEGBlockContextMap.numOrders
					* (proof.qfThresholds.count + 1))
			#expect(
				Set(model.contextMap)
					== Set((0..<model.numContexts).map(UInt8.init)))
		}

		let proof = PixelBlockEntropyModelProofCase.tieObservation
		let source = try sourceModelFields(proof: .categoryLookup)
		#expect(source.total == proof.quantCounts.reduce(0, +))
		#expect(source.qfThresholds == proof.qfThresholds)
		#expect(source.numContexts == proof.numContexts)
		let differences = source.contextMap.enumerated().compactMap { index, value in
			let native = proof.contextMap[index]
			return value == native
				? nil
				: PixelBlockMapDifference(
					index: index, source: value, native: native)
		}
		#expect(differences == proof.sourceMapDifferences)
	}

	private func sourceModelFields(proof: PixelBlockContextProofCase) throws
		-> SourcePixelBlockModelFields
	{
		let url = try #require(
			Bundle.module.url(
				forResource: proof.fixture, withExtension: "sem",
				subdirectory: "Fixtures/semantic"))
		let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
		return SourcePixelBlockModelFields(
			total: parseInts(lines[0])!.first!,
			qfThresholds: parseInts(lines[1])!.map(UInt32.init),
			numContexts: parseInts(lines[2])!.first!,
			contextMap: parseInts(lines[3])!.map(UInt8.init),
			consumerRawQuant: parseInts(lines[4])!,
			consumerCategories: parseInts(lines[5])!)
	}

	private func parseInts(_ line: Substring) -> [Int]? {
		let values = line.split(separator: " ").dropFirst()
		let parsed = values.compactMap { Int($0) }
		return parsed.count == values.count ? parsed : nil
	}

	@Test(
		"Each channel uses the reference slot permutation and raw quant greater-than threshold lookup."
	)
	func categoryLookupUsesStrictRawQuantBoundaries() throws {
		var map = [UInt8](repeating: 0, count: 3 * 13 * 2)
		for channel in 0..<3 {
			let base = JPEGBlockContextMap.slot(forChannel: channel) * 26
			map[base] = UInt8(channel)
			map[base + 1] = UInt8(channel + 3)
		}
		let result = JPEGBlockContextMap.Result(
			thresholds: [], qfThresholds: [10], contextMap: map, numContexts: 6)
		#expect(result.thresholds.isEmpty)
		for channel in 0..<3 {
			#expect(
				result.category(channel: channel, dcBucket: 0, rawQuant: 10)
					== channel)
			#expect(
				result.category(channel: channel, dcBucket: 0, rawQuant: 11)
					== channel + 3)
		}
		let proof = try sourceModelFields(proof: .categoryLookup)
		let sourceModel = JPEGBlockContextMap.Result(
			thresholds: [], qfThresholds: proof.qfThresholds,
			contextMap: proof.contextMap, numContexts: proof.numContexts)
		let rawQuant = proof.consumerRawQuant
		let categories = proof.consumerCategories
		for channel in 0..<3 {
			#expect(
				sourceModel.category(
					channel: channel, dcBucket: 0, rawQuant: UInt32(rawQuant[0])
				)
					== categories[channel * 2])
			#expect(
				sourceModel.category(
					channel: channel, dcBucket: 0, rawQuant: UInt32(rawQuant[1])
				)
					== categories[channel * 2 + 1])
		}
	}

	@Test(
		"The model's DC, qf, map and category fields reach the serialized header."
	)
	func quantThresholdWireFieldsMatchReference() throws {
		var histogram = [Int](repeating: 0, count: 256)
		for quant in 0..<250 { histogram[quant] = 200 }
		let result = PixelBlockEntropyModel.compute(
			quantCounts: histogram, params: try DistanceParams(distance: 1))
		let url = try #require(
			Bundle.module.url(
				forResource: "e4_pixel_block_model_ties", withExtension: "sem",
				subdirectory: "Fixtures/semantic"))
		let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
		var writer = BitWriter()
		JPEGBlockContextMap.write(result, writer: &writer)
		var reader = TestBitReader(bytes: writer.bytes)
		#expect(reader.read(1) == 0)
		for _ in 0..<3 { #expect(reader.read(4) == 0) }
		#expect(reader.read(4) == 1)
		#expect(reader.read(2) == 3)
		#expect(reader.read(8) == 80)
		#expect(result.qfThresholds == parseInts(lines[1])?.map(UInt32.init))
		let expectedMap = result.contextMap.map(Int.init)
		#expect(
			expectedMap.count
				== 3 * JPEGBlockContextMap.numOrders
				* (result.qfThresholds.count + 1))
		#expect(result.numContexts == parseInts(lines[2])?.first)
		#expect(Set(expectedMap) == Set(0..<result.numContexts))
		let mapMode = reader.read(3)
		let decodedMap: [Int]
		if mapMode == 1 {
			decodedMap = [Int](repeating: 0, count: expectedMap.count)
		} else {
			#expect(mapMode == 0)
			#expect(reader.read(1) == 1)
			let mapCode = HistogramCluster.optimizePrefixCodes(
				tokens: expectedMap.map { Token(context: 0, value: UInt32($0)) },
				contextMap: [0], prefixCodeCount: 1)
			var mapHeader = BitWriter()
			PrefixCodeWriter.writePrefixCodes(mapCode.prefixCodes, writer: &mapHeader)
			var headerReader = TestBitReader(bytes: mapHeader.bytes)
			for _ in 0..<mapHeader.bitsWritten {
				#expect(reader.read(1) == headerReader.read(1))
			}
			decodedMap = reader.readPrefixSymbols(
				count: expectedMap.count, code: mapCode.prefixCodes[0])
		}
		#expect(decodedMap == expectedMap)
		#expect((decodedMap.max() ?? -1) + 1 == result.numContexts)
		expectQuantThresholdSelectorsRoundTrip()
	}

	private func expectQuantThresholdSelectorsRoundTrip() {
		let thresholds: [UInt32] = [1, 2, 5, 12, 13, 44, 45]
		let result = JPEGBlockContextMap.Result(
			thresholds: [], qfThresholds: thresholds,
			contextMap: [0], numContexts: 1)
		var writer = BitWriter()
		JPEGBlockContextMap.write(result, writer: &writer)
		var reader = TestBitReader(bytes: writer.bytes)
		#expect(reader.read(1) == 0)
		for _ in 0..<3 { #expect(reader.read(4) == 0) }
		#expect(reader.read(4) == UInt64(thresholds.count))
		for threshold in thresholds {
			let value = threshold - 1
			let (selector, width, offset): (UInt64, Int, UInt32) =
				switch value {
				case 0..<4: (0, 2, 0)
				case 4..<12: (1, 3, 4)
				case 12..<44: (2, 5, 12)
				default: (3, 8, 44)
				}
			#expect(reader.read(2) == selector)
			#expect(reader.read(width) == UInt64(value - offset))
		}
	}

	@Test(
		"AC nonzero and coefficient tokens use the model category and full category count for every group block."
	)
	func adaptiveTokensUseActualCategoryCount() throws {
		var map = [UInt8](repeating: 0, count: 3 * 13 * 2)
		for channel in 0..<3 {
			let base = JPEGBlockContextMap.slot(forChannel: channel) * 26
			map[base] = UInt8(channel * 2)
			map[base + 1] = UInt8(channel * 2 + 1)
		}
		let model = JPEGBlockContextMap.Result(
			thresholds: [], qfThresholds: [10], contextMap: map, numContexts: 6)
		let coefficients = (0..<3).map { _ -> [Int32] in
			var channel = [Int32](repeating: 0, count: 2 * DCT.blockSize)
			channel[1] = 5
			channel[DCT.blockSize + 1] = 5
			return channel
		}
		let entropy = EntropyCode(
			contextMap: [UInt8](
				repeating: 0,
				count: 6 * (ACContext.nonZeroBuckets + ACContext.zeroDensityCount)),
			prefixCodes: [])
		var writer = SectionWriter(mode: .staging(entropy))
		ACGroupEncoder.tokenizeGroup(
			coefficients: coefficients, widthInBlocks: 2, heightInBlocks: 1,
			subsampling: .none,
			order: Array(repeating: ACTokenizer.coeffOrder, count: 3),
			blockContextMap: model, rawQuantField: [10, 11], writer: &writer)
		let tokens = writer.staged.compactMap { record -> (UInt32, UInt32)? in
			if case .token(let context, let value) = record { return (context, value) }
			return nil
		}
		#expect(tokens.count == 12)
		for block in 0..<2 {
			for channel in ACTokenizer.channelOrder {
				let category = channel * 2 + block
				let predicted = block == 0 ? 32 : 1
				let base =
					(block * 3 + ACTokenizer.channelOrder.firstIndex(
						of: channel)!) * 2
				#expect(
					tokens[base].0
						== UInt32(
							ACContext.nonZeroContext(
								nonZeros: predicted,
								blockContext: category,
								numCategories: 6)))
				#expect(tokens[base].1 == 1)
				let density = ACContext.zeroDensityContext(
					nonzerosLeft: 1, k: 1, coveredBlocks: 1,
					log2CoveredBlocks: 0, previous: 1)
				let context =
					ACContext.zeroDensityContextsOffset(
						blockContext: category, numCategories: 6) + density
				#expect(tokens[base + 1].0 == UInt32(context))
				#expect(tokens[base + 1].1 == packSigned(5))
			}
		}
	}

	@Test(
		"Production computed models match bounded upstream decisions for large photos and non-default models without claiming full coefficient recovery."
	)
	func productionModelMatchesLargePhotoObservations() throws {
		let input = try loadPPM(fixture: "flower_1024")
		let encoded = try SwiftSemanticEncoding.encode(input, distance: 1)
		let decisions = encoded.decisions
		let model = try #require(decisions.blockContextMap)
		let fixtureURL = try #require(
			Bundle.module.url(
				forResource: "e4_pixel_block_model_flower_1024",
				withExtension: "sem",
				subdirectory: "Fixtures/semantic"))
		let fields = try String(contentsOf: fixtureURL, encoding: .utf8).split(
			separator: "\n")
		let proof = PixelBlockEntropyModelProofCase.flower1024
		#expect(model.thresholds.isEmpty)
		#expect(model.qfThresholds == proof.qfThresholds)
		#expect(model.numContexts == proof.numContexts)
		#expect(model.contextMap == proof.contextMap)
		#expect(parseInts(fields[0])?.first == proof.quantCounts.reduce(0, +))
		#expect(model.qfThresholds == parseInts(fields[1])?.map(UInt32.init))
		#expect(model.numContexts == parseInts(fields[2])?.first)
		#expect(parseInts(fields[3])?.map(UInt8.init) == proof.contextMap)
		let rawQuant = decisions.quantFields.flatMap { $0 }
		#expect(rawQuant.count == 16_384)
		#expect(Set(rawQuant) == Set([6]))
		#expect(try Encoder.encode(input, distance: 1) == encoded.codestream)
	}

	@Test(
		"Sequential and concurrent optimized encodes carry the same frame model and produce identical bytes."
	)
	func sequentialAndConcurrentModelsAgree() async throws {
		let image = try ConcurrentEncodeTests.image(width: 512, height: 512)
		let sequential = try Encoder.encode(image, distance: 1)
		let concurrent = try await Encoder.encodeConcurrently(image, distance: 1)
		#expect(sequential == concurrent)
	}

}

private struct TestBitReader {
	let bytes: [UInt8]
	var bitOffset = 0

	mutating func read(_ count: Int) -> UInt64 {
		var result: UInt64 = 0
		for bit in 0..<count {
			let value = (bytes[bitOffset / 8] >> (bitOffset % 8)) & 1
			result |= UInt64(value) << bit
			bitOffset += 1
		}
		return result
	}

	mutating func skip(_ count: Int) {
		bitOffset += count
	}

	mutating func readPrefixSymbols(count: Int, code: PrefixCode) -> [Int] {
		let maxDepth = Int(code.depths.max() ?? 0)
		var symbols: [Int] = []
		for _ in 0..<count {
			var bits: UInt16 = 0
			var symbol: Int?
			for depth in 1...maxDepth {
				bits |= UInt16(read(1)) << UInt16(depth - 1)
				symbol = code.depths.indices.first {
					code.depths[$0] == depth && code.bits[$0] == bits
				}
				if symbol != nil { break }
			}
			guard let symbol else { return symbols }
			symbols.append(symbol)
		}
		return symbols
	}
}
