import Foundation
import Testing

@testable import JXLEncoder

@Suite("Selected modular DC")
struct ModularDCContractTests {
	static let nativeHarnessPath = ProcessInfo.processInfo.environment["JXL_HARNESS_PATH"]
	@Test(
		"weighted prediction preserves edge, update and signed property tie rules")
	func weightedPredictionEdgesUpdatesAndTies() {
		func checkRaster(_ values: [Int32], width: Int, expected: [(Int64, Int64)]) {
			var state = DCPredictor.WeightedState(width: width)
			for index in values.indices {
				let x = index % width
				let y = index / width
				let left =
					x > 0
					? values[index - 1] : (y > 0 ? values[index - width] : 0)
				let north = y > 0 ? values[index - width] : left
				let northWest = x > 0 && y > 0 ? values[index - width - 1] : left
				let northEast =
					x + 1 < width && y > 0 ? values[index - width + 1] : north
				let northNorth = y > 1 ? values[index - 2 * width] : north
				let result = state.predict(
					x: x, y: y, north: north, west: left,
					northEast: northEast, northWest: northWest,
					northNorth: northNorth)
				#expect(result.guess == expected[index].0)
				#expect(result.property == expected[index].1)
				state.updateErrors(value: values[index], x: x, y: y)
			}
		}

		checkRaster(
			[0, 100, -100, 50, -50, 100], width: 3,
			expected: [
				(0, 0), (0, 0), (100, -800), (45, -800), (16, 1600), (-100, 1600),
			])
		checkRaster(
			[4, -2, 3], width: 1,
			expected: [(0, 0), (4, -32), (-5, 48)])
		checkRaster(
			[100, 0, 0, 0], width: 2,
			expected: [(0, 0), (100, -800), (92, -800), (0, 800)])

		let nativeSamples: [Int32] = [
			0, 22, 46, 72, 96, 118, 138, 156, 176, 192, 210, 226, 242, 258, 272, 288,
			-15, 4, 33, 62, 90, 114, 137, 161, 178, 194, 212, 230, 247, 262, 278, 286,
		]
		// Native trace witness: channel 1 at x=0,y=1 predicts 9 with property -176.
		var nativeTraceState = DCPredictor.WeightedState(width: 16)
		for index in nativeSamples.indices {
			let x = index % 16
			let y = index / 16
			let left =
				x > 0
				? nativeSamples[index - 1] : (y > 0 ? nativeSamples[index - 16] : 0)
			let north = y > 0 ? nativeSamples[index - 16] : left
			let northWest = x > 0 && y > 0 ? nativeSamples[index - 17] : left
			let northEast = x + 1 < 16 && y > 0 ? nativeSamples[index - 15] : north
			let result = nativeTraceState.predict(
				x: x, y: y, north: north, west: left, northEast: northEast,
				northWest: northWest, northNorth: north)
			if x == 0 && y == 1 {
				#expect(result.guess == 9)
				#expect(result.property == -176)
			}
			nativeTraceState.updateErrors(value: nativeSamples[index], x: x, y: y)
		}

		var defaultNeighbors = DCPredictor.WeightedState(width: 1)
		var changedZeroWeightNeighbors = DCPredictor.WeightedState(width: 1)
		let baseline = defaultNeighbors.predict(
			x: 0, y: 0, north: 2, west: 3, northEast: 4,
			northWest: 5, northNorth: 6)
		let changed = changedZeroWeightNeighbors.predict(
			x: 0, y: 0, north: 2, west: 3, northEast: 4,
			northWest: -50, northNorth: 60)
		#expect(changed.guess == baseline.guess)
		#expect(changed.property == baseline.property)
	}

	@Test("nonlinear DC uses strict deadzone and even residual transitions")
	func nonlinearDCDeadzoneAndEvenResidualBoundaries() throws {
		let cases: [(Float, Int32)] = [
			(-0.62, -1), (-0.61, 0), (0.61, 0), (0.62, 1),
			(-3, -4), (-2.5, -2), (2.5, 2), (3, 4),
		]
		for (input, expected) in cases {
			#expect(
				try DCGroupEncoder.quantizedValue(
					scaledResidual: input, prediction: 0)
					== expected)
		}
	}

	@Test("pixel DC folds prepared luma across AC-group boundaries")
	func foldedDCUsesPreparedLumaAcrossACGroupBoundary() throws {
		var data = DCGroupData(widthInBlocks: 33, heightInBlocks: 2)
		var rawDC = [[Float]](repeating: [Float](repeating: 0, count: 66), count: 3)
		rawDC[1][31] = 0.25
		rawDC[1][32] = 0.25
		rawDC[2][32] = 0.25
		try DCGroupEncoder.preparePixel(
			rawDC: rawDC, globalScale: 32_768, quantDC: 3, data: &data)
		#expect(data.extraDCPrecision == 1)
		#expect(data.quantDC[1][31] == 384)
		#expect(data.quantDC[1][32] == 384)
		#expect(data.quantDC[2][32] == 0)
	}

	@Test("AC-group extraction keeps original Float DC before CfL")
	func rawDCExtractionPrecedesCfL() {
		let width = 16
		let height = 8
		let planes = ChannelPlanes(
			planes: [
				(0..<width * height).map { Float($0 % 13) / 16 },
				(0..<width * height).map { Float($0 % 7) / 8 },
				(0..<width * height).map { Float($0 % 11) / 9 },
			],
			widths: [width, width, width], heights: [height, height, height])
		var rawDC = (0..<3).map { _ in [Float](repeating: .nan, count: 2) }
		_ = ACGroupEncoder.computeGroup(
			planes: planes, widthInBlocks: 2, heightInBlocks: 1,
			subsampling: .none, quantField: [5, 5], scale: 0.1,
			xQuantMatrixScale: 2, rawDC: &rawDC)
		for channel in 0..<3 {
			let expected = (0..<2).map { block in
				DCT.forward8x8(
					pixels: planes.planes[channel], stride: width,
					originX: block * DCT.blockDim, originY: 0)[0]
			}
			#expect(rawDC[channel] == expected)
		}
	}

	@Test(
		"DC keeps Int32 samples and rejects unsupported sample or residual ranges")
	func dcPreparationPreservesInt32AndRejectsUnsupportedRange() throws {
		#expect(
			try DCGroupEncoder.quantizedValue(scaledResidual: 0, prediction: 40_000)
				== 40_000)
		#expect(
			try DCGroupEncoder.quantizedValue(scaledResidual: 0, prediction: -40_000)
				== -40_000)
		#expect(throws: EncoderError.unsupportedDCRange) {
			try DCGroupEncoder.quantizedValue(scaledResidual: .infinity, prediction: 0)
		}
		#expect(throws: EncoderError.unsupportedDCRange) {
			try DCGroupEncoder.quantizedValue(scaledResidual: .nan, prediction: 0)
		}
		#expect(throws: EncoderError.unsupportedDCRange) {
			try DCGroupEncoder.quantizedValue(
				scaledResidual: 2_147_483_648, prediction: 0)
		}
		#expect(throws: EncoderError.unsupportedDCRange) {
			try DCGroupEncoder.quantizedValue(scaledResidual: 0, prediction: Int64.max)
		}
		#expect(throws: EncoderError.unsupportedDCRange) {
			try DCGroupEncoder.quantizedValue(scaledResidual: 1, prediction: Int64.max)
		}
	}

	@Test("JPEG DC preserves coefficient integers and subsampled plane geometry")
	func jpegDCPreservesCoefficientsAndSubsampledGeometry() throws {
		let transcode = try JPEGTranscode(
			JPEGParser.parse(JPEGParserTests.fixture("hopper_420_restart")))
		let alignment = (
			x: 1 << transcode.subsampling.maxHorizontalShift,
			y: 1 << transcode.subsampling.maxVerticalShift
		)
		let dim = ImageDim(
			width: transcode.width, height: transcode.height,
			blockAlignment: alignment)
		var quantDC = (0..<3).map { channel in
			let width = transcode.subsampling.blocksAcross(
				channel: channel, fullWidthInBlocks: dim.widthInBlocks)
			let height = transcode.subsampling.blocksDown(
				channel: channel, fullHeightInBlocks: dim.heightInBlocks)
			return [Int32](repeating: 0, count: width * height)
		}
		var writer = SectionWriter(mode: .direct(.staticAC))
		ACGroupEncoder.encodeJPEG(
			transcode: transcode, blockX0: 0, blockY0: 0,
			widthInBlocks: dim.widthInBlocks, heightInBlocks: dim.heightInBlocks,
			quantDC: &quantDC, blockContextMap: nil,
			order: CoeffOrder.Result.identity.orders, writer: &writer)
		for channel in 0..<3 {
			let width = transcode.subsampling.blocksAcross(
				channel: channel, fullWidthInBlocks: dim.widthInBlocks)
			let height = transcode.subsampling.blocksDown(
				channel: channel, fullHeightInBlocks: dim.heightInBlocks)
			let expected = (0..<height).flatMap { y in
				(0..<width).map { x in
					transcode.block(channel: channel, x: x, y: y)[0]
				}
			}
			#expect(quantDC[channel].count == width * height)
			#expect(quantDC[channel] == expected)
		}
	}

	@Test(
		"fixed trees use family totals, metadata selection and strict split equality",
	)
	func fixedTreesUseFamilyTotalsAndSelectedMetadata() throws {
		func predictor(_ node: ContextTree.Node) -> ContextTree.Predictor {
			guard case .leaf(let predictor, _) = node else {
				Issue.record("expected selected tree leaf")
				return .zero
			}
			return predictor
		}
		let groups = [DCGroupData(widthInBlocks: 8, heightInBlocks: 8)]
		let pixelTree = ContextTree.prepare(groups: groups, jpegTranscode: false)
		let jpegTree = ContextTree.prepare(groups: groups, jpegTranscode: true)
		#expect(pixelTree.nodes.count == 3)
		#expect(
			pixelTree.nodes[0]
				== .split(
					property: 1, threshold: 2, greater: 1, notGreater: 2))
		#expect(pixelTree.nodes[1] == .leaf(predictor: .left, context: 0))
		#expect(pixelTree.nodes[2] == .leaf(predictor: .weighted, context: 1))
		#expect(pixelTree.tokens.map(\.context) == [1, 0, 1, 2, 3, 4, 5, 1, 2, 3, 4, 5])
		#expect(pixelTree.tokens.map(\.value) == [2, 4, 0, 1, 0, 0, 0, 0, 6, 0, 0, 0])
		#expect(pixelTree.contextCount == 2)
		#expect(
			pixelTree.leaf(
				streamID: 2, channel: 0, row: 0, north: 0, west: 0,
				weightedProperty: 0) == .leaf(predictor: .weighted, context: 1))
		#expect(
			pixelTree.leaf(
				streamID: 3, channel: 0, row: 0, north: 0, west: 0,
				weightedProperty: 0) == .leaf(predictor: .left, context: 0))
		let merged = ContextTree.prepare(
			groups: [groups[0], groups[0]], jpegTranscode: false)
		#expect(
			merged.nodes[0]
				== .split(
					property: 1, threshold: 4, greater: 1, notGreater: 2))
		#expect(
			predictor(
				merged.leaf(
					streamID: 4, channel: 0, row: 0, north: 0, west: 0,
					weightedProperty: 0)) == .weighted)
		#expect(
			predictor(
				merged.leaf(
					streamID: 5, channel: 0, row: 0, north: 0, west: 0,
					weightedProperty: 0)) == .left)
		#expect(
			predictor(
				jpegTree.leaf(
					streamID: 3, channel: 0, row: 0, north: 0, west: 0,
					weightedProperty: 0)) == .zero)

		let rich = DCGroupData(widthInBlocks: 19, heightInBlocks: 19)
		let richTree = ContextTree.prepare(groups: [rich], jpegTranscode: false)
		#expect(
			richTree.nodes[1]
				== .split(
					property: 0, threshold: 1, greater: 3, notGreater: 4))
		#expect(
			predictor(
				richTree.leaf(
					streamID: 3, channel: 0, row: 0, north: 0, west: 0,
					weightedProperty: 0)) == .gradient)
		#expect(
			predictor(
				richTree.leaf(
					streamID: 3, channel: 0, row: 0, north: 0, west: 0,
					weightedProperty: 0))
				== predictor(
					richTree.leaf(
						streamID: 3, channel: 1, row: 0, north: 0, west: 0,
						weightedProperty: 0)))
		#expect(
			predictor(
				richTree.leaf(
					streamID: 3, channel: 2, row: 0, north: 0, west: 0,
					weightedProperty: 0)) == .zero)
		#expect(
			predictor(
				richTree.leaf(
					streamID: 3, channel: 2, row: 1, north: 0, west: 0,
					weightedProperty: 0)) == .left)
		let richStreams = try DCGroupEncoder.tokenStreams(
			data: rich, groupIndex: 0, tree: richTree)
		let metadataContexts = richStreams.metadata.map(\.context)
		let mapsEnd = 18
		let strategyEnd = mapsEnd + 19 * 19
		let quantEnd = strategyEnd + 19 * 19
		#expect(Set(metadataContexts[0..<9]).count == 1)
		#expect(Set(metadataContexts[9..<18]).count == 1)
		#expect(Set(metadataContexts[18..<strategyEnd]).count == 1)
		#expect(Set(metadataContexts[strategyEnd..<quantEnd]).count == 1)
		#expect(metadataContexts[18] != metadataContexts[strategyEnd])
		#expect(Set(metadataContexts[quantEnd...]).count == 2)
	}

	@Test("DC and metadata tokens use the serialized tree's leaf contexts")
	func treeSerializationAndTokenContextsAgree() throws {
		var data = DCGroupData(widthInBlocks: 2, heightInBlocks: 2)
		data.quantDC[1] = [1, 2, 4, 8]
		data.quantDC[0] = [3, 5, 7, 9]
		data.quantDC[2] = [2, 4, 6, 8]
		data.rawQuantField = [1, 2, 3, 4]
		let tree = ContextTree.prepare(groups: [data], jpegTranscode: false)
		let streams = try DCGroupEncoder.tokenStreams(data: data, groupIndex: 0, tree: tree)
		#expect(streams.dc.count == 12)
		#expect(streams.metadata.count == 14)
		#expect(streams.dc.map(\.context) == [UInt32](repeating: 1, count: 12))
		#expect(streams.metadata.map(\.context) == [UInt32](repeating: 0, count: 14))
		#expect(streams.dc.map(\.value) == [2, 2, 4, 8, 6, 4, 4, 2, 4, 4, 4, 2])
	}

	@Test("modular models select source hybrid uint and prefix or ANS decisions")
	func modularEntropySelectsSourceUintAndCoder() {
		let short = SectionOptimizer.modularCode(
			tokenStreams: [[Token(context: 0, value: 0)]], contextCount: 1,
			extraDCPrecision: 1)
		#expect(short.ansInfoTables == nil)
		#expect(short.uintConfigurations != nil)

		let tokens = (0..<128).map { index in
			Token(context: UInt32(index % 2), value: UInt32((index * 37) % 93))
		}
		let pixel = SectionOptimizer.modularCode(
			tokenStreams: [tokens], contextCount: 2, extraDCPrecision: 1)
		let jpeg = SectionOptimizer.modularCode(
			tokenStreams: [tokens], contextCount: 2, extraDCPrecision: 0)
		#expect(pixel.uintConfigurations != nil)
		#expect(pixel.logAlphabetSize >= 5 && pixel.logAlphabetSize <= 8)
		#expect(pixel.contextMap.count == 2)
		#expect(jpeg.uintConfigurations == nil)
	}

	@Test("each modular payload resets ANS while sharing its entropy model")
	func modularPayloadsUseIndependentANSStates() {
		let tokens = (0..<180).map { index in
			Token(context: 0, value: UInt32((index * 13 + index / 7) % 41))
		}
		let code = SectionOptimizer.modularCode(
			tokenStreams: [tokens], contextCount: 1, extraDCPrecision: 1)
		#expect(code.ansInfoTables != nil)
		var first = BitWriter()
		var second = BitWriter()
		EntropyCodeWriter.writeTokens(tokens, code: code, writer: &first)
		EntropyCodeWriter.writeTokens(tokens, code: code, writer: &second)
		#expect(first.bitsWritten == second.bitsWritten)
		#expect(first.bytes == second.bytes)
	}

	@Test(
		"JPEG codestream decodes and preserves source coefficient semantics",
		.enabled(if: nativeHarnessPath != nil))
	func encodedJPEGRecoversExactCoefficients() throws {
		let fixture = try JPEGParserTests.fixture("hopper_420_restart")
		let transcode = try JPEGTranscode(JPEGParser.parse(fixture))
		let codestream = try Encoder.encodeJPEG(transcode)
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("jxl-jpeg-witness-\(UUID().uuidString)")
		try FileManager.default.createDirectory(
			at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let sourceURL = directory.appendingPathComponent("source.jpg")
		let codestreamURL = directory.appendingPathComponent("encoded.jxl")
		try Data(fixture).write(to: sourceURL)
		try Data(codestream).write(to: codestreamURL)

		let process = Process()
		process.executableURL = URL(fileURLWithPath: try #require(Self.nativeHarnessPath))
		process.arguments = [
			"jpeg-witness", sourceURL.path, codestreamURL.path,
		]
		let output = Pipe()
		process.standardOutput = output
		process.standardError = FileHandle.nullDevice
		try process.run()
		let data = output.fileHandleForReading.readDataToEndOfFile()
		process.waitUntilExit()
		#expect(process.terminationStatus == 0)
		let witness = try SemanticDump(
			parsing: String(decoding: data, as: UTF8.self))
		#expect(witness.fields["jpeg_context.size"] == .integers([26, 26]))
		#expect(
			witness.fields["jpeg_context.reconstructed_coefficients_exact"]
				== .integers([1]))
		#expect(witness.fields["jpeg_context.group_count"] == .integers([1]))
		#expect(witness.fields["jpeg_context.g0.token_count"] == .integers([19068]))
	}
}
