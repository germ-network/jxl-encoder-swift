import Testing

@testable import JXLEncoder

@Suite("Selected modular DC")
struct ModularDCContractTests {
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
				(0, 0), (0, 0), (100, -800), (33, -800), (19, 1600), (-89, 1600),
			])
		checkRaster(
			[4, -2, 3], width: 1,
			expected: [(0, 0), (4, -32), (-3, 48)])
		checkRaster(
			[100, 0, 0, 0], width: 2,
			expected: [(0, 0), (100, -800), (80, -800), (0, 800)])

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

	@Test("nonlinear DC uses strict deadzone and even residual transitions", .disabled())
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

	@Test("pixel DC folds prepared luma across AC-group boundaries", .disabled())
	func foldedDCUsesPreparedLumaAcrossACGroupBoundary() throws {
		var data = DCGroupData(widthInBlocks: 33, heightInBlocks: 2)
		let rawDC = [[Float]](repeating: [Float](repeating: 0, count: 66), count: 3)
		try DCGroupEncoder.preparePixel(rawDC: rawDC, scaleDC: 1, data: &data)
		#expect(data.extraDCPrecision == 1)
		Issue.record(
			"Use asymmetric luma/B values at columns31/32 and compare fixed prepared samples"
		)
	}

	@Test(
		"DC keeps Int32 samples and rejects unsupported sample or residual ranges",
		.disabled())
	func dcPreparationPreservesInt32AndRejectsUnsupportedRange() throws {
		#expect(
			try DCGroupEncoder.quantizedValue(scaledResidual: 0, prediction: 40_000)
				== 40_000)
		#expect(throws: EncoderError.unsupportedDCRange) {
			try DCGroupEncoder.quantizedValue(scaledResidual: .infinity, prediction: 0)
		}
		Issue.record(
			"Cover negative Int16 crossing, NaN, Float/Int32 limits and predictor-plus-residual overflow"
		)
	}

	@Test("JPEG DC preserves coefficient integers and subsampled plane geometry", .disabled())
	func jpegDCPreservesCoefficientsAndSubsampledGeometry() throws {
		Issue.record(
			"Run the production JPEG caller with exact coefficient values and a partial subsampled group"
		)
	}

	@Test(
		"fixed trees use family totals, metadata selection and strict split equality",
		.disabled())
	func fixedTreesUseFamilyTotalsAndSelectedMetadata() throws {
		let groups = [DCGroupData(widthInBlocks: 1, heightInBlocks: 1)]
		let pixelTree = ContextTree.prepare(groups: groups, jpegTranscode: false)
		let jpegTree = ContextTree.prepare(groups: groups, jpegTranscode: true)
		#expect(pixelTree.contextCount > 0)
		#expect(jpegTree.contextCount > 0)
		Issue.record(
			"Assert source-pruned nodes at family power-of-two and metadata1024 boundaries, leaf IDs and token roundtrip"
		)
	}

	@Test("DC and metadata tokens use the serialized tree's leaf contexts", .disabled())
	func treeSerializationAndTokenContextsAgree() throws {
		let data = DCGroupData(widthInBlocks: 2, heightInBlocks: 2)
		let tree = ContextTree.prepare(groups: [data], jpegTranscode: false)
		let streams = try DCGroupEncoder.tokenStreams(data: data, groupIndex: 0, tree: tree)
		#expect(streams.dc.count == 12)
		#expect(streams.metadata.count == 14)
		Issue.record(
			"Replace shape smoke with fixed values/contexts, metadata row transitions and stream-id split cases"
		)
	}

	@Test("modular models select source hybrid uint and prefix or ANS decisions", .disabled())
	func modularEntropySelectsSourceUintAndCoder() {
		let code = SectionOptimizer.modularCode(
			tokenStreams: [[Token(context: 0, value: 0)]], contextCount: 1,
			extraDCPrecision: 1)
		#expect(code.ansInfoTables == nil)
		Issue.record(
			"Use fixed nondegenerate streams across threshold100, all four uint candidates and tied-cost source order"
		)
	}

	@Test("each modular payload resets ANS while sharing its entropy model", .disabled())
	func modularPayloadsUseIndependentANSStates() {
		Issue.record(
			"Serialize two nondegenerate token payloads separated by headers and decode both with shared model"
		)
	}

	@Test("smooth photo and multi-group pixel encodings independently decode", .disabled())
	func encodedPixelDCDecodesAcrossGroups() throws {
		Issue.record(
			"Decode actual Swift codestreams and check dimensions, meaningful pixel reconstruction and group seams"
		)
	}

	@Test("JPEG modular coding recovers exact source coefficients", .disabled())
	func encodedJPEGRecoversExactCoefficients() throws {
		Issue.record(
			"Independently decode actual Swift JPEG transcodes and compare every recovered source coefficient"
		)
	}
}
