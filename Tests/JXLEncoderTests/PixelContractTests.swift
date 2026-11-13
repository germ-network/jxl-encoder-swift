import Testing

@testable import JXLEncoder

@Suite("Pixel semantic fixtures")
struct PixelSemanticFixtureTests {
	private func assertFixture(_ entry: SemanticCorpusEntry, categories: Set<String>) throws {
		let expected = try SemanticDump(fixture: entry.name)
		let actual = try SemanticDump(swiftDecisions: try entry.encoded().decisions)
		for category in categories {
			let reference = expected.restricted(to: [category])
			let emitted = actual.restricted(to: [category])
			#expect(
				!reference.fields.isEmpty,
				"missing \(category) fixture for \(entry.name)")
			#expect(
				!emitted.fields.isEmpty,
				"missing \(category) emitter for \(entry.name)")
			if !entry.knownIssues[category, default: []].isEmpty {
				let issues = entry.knownIssues[category, default: []].sorted()
				withKnownIssue(Comment(rawValue: issues.joined(separator: ", "))) {
					#expect(emitted.differences(from: reference).isEmpty)
				}
			} else {
				#expect(
					emitted.differences(from: reference).isEmpty,
					"\(entry.name)#\(category)")
			}
		}
	}

	@Test(
		"image header fields match the pinned reference independently of sample format",
	)
	func imageHeaderFieldsMatchReference() throws {
		let categories: Set<String> = ["image_header", "image_sample_format"]
		for entry in SemanticCorpusEntry.all {
			try assertFixture(entry, categories: categories)
		}
	}

	@Test(
		"filter decisions match the pinned reference as independent comparison units",
	)
	func filterFieldsMatchReference() throws {
		let categories: Set<String> = [
			"frame_flags", "gaborish", "epf", "x_matrix_scale", "b_matrix_scale",
		]
		for entry in SemanticCorpusEntry.all {
			try assertFixture(entry, categories: categories)
		}
	}

	@Test("quant fields match upstream around clamp and decision boundaries")
	func quantFieldBoundaryDistancesMatchReference() throws {
		let reference = try SemanticDump(fixture: "distance_params")
		let boundaries: [Float] = [
			0.03, 0.05, 0.299, 0.5, 0.7, 1.25, 1.5, 2.5, 3, 4, 5, 5.5, 9, 9.5, 10,
		]
		var distances: [Float] = []
		for boundary in boundaries {
			distances.append(boundary.nextDown)
			distances.append(boundary)
			distances.append(boundary.nextUp)
		}
		var emitted = SemanticDump()
		emitted.record("distance_params.neon_target", .integers([1]))
		emitted.record(
			"distance_params.inputs",
			.integers(distances.map { Int64($0.bitPattern) }))
		emitted.record(
			"distance_params.effective_distance",
			.floats(try distances.map { try DistanceParams(distance: $0).distance }))
		emitted.record(
			"distance_params.global_scale",
			.integers(
				try distances.map {
					Int64(try DistanceParams(distance: $0).globalScale)
				}))
		emitted.record(
			"distance_params.quant_dc",
			.integers(
				try distances.map {
					Int64(try DistanceParams(distance: $0).quantDC)
				}))
		emitted.record(
			"distance_params.quant_field",
			.integers(
				try distances.map {
					Int64(try DistanceParams(distance: $0).uniformQuant)
				}))
		#expect(reference.fields["distance_params.neon_target"] == .integers([1]))
		#expect(emitted.differences(from: reference).isEmpty)
	}

	@Test("upstream filter and matrix transition boundaries are explicit per category")
	func filterAndMatrixTransitionsAtDistanceBoundsMatchReference() throws {
		let reference = try SemanticDump(fixture: "distance_filters")
		let params = try SemanticDump(fixture: "distance_params")
		guard
			case .integers(let inputBits)? = params.fields["distance_params.inputs"],
			case .integers(let gaborish)? = reference.fields[
				"distance_filters.gaborish_effort4"],
			case .integers(let epf)? = reference.fields[
				"distance_filters.epf_iterations_effort4"],
			case .integers(let xScale)? = reference.fields[
				"distance_filters.x_matrix_scale_effort4"],
			case .integers(let bScale)? = reference.fields[
				"distance_filters.b_matrix_scale_effort4"]
		else {
			Issue.record("missing distance filter observations")
			return
		}
		let distances = inputBits.map { Float(bitPattern: UInt32(truncatingIfNeeded: $0)) }
		#expect(reference.fields["distance_filters.inputs"] == .integers(inputBits))
		#expect(gaborish == [Int64](repeating: 0, count: distances.count))
		for (boundary, expected) in [
			(Float(0.7), [Int64(0), 1, 1]),
			(Float(1.5), [Int64(1), 2, 2]),
			(Float(4), [Int64(2), 3, 3]),
		] {
			let index = try #require(distances.firstIndex(of: boundary.nextDown))
			#expect(Array(epf[index..<(index + 3)]) == expected)
		}
		#expect(
			xScale
				== distances.map {
					Int64($0 <= 2.5 ? 3 : $0 <= 5.5 ? 4 : $0 <= 9.5 ? 5 : 6)
				})
		#expect(bScale == [Int64](repeating: 2, count: distances.count))

		let swiftGaborish = try distances.map { distance -> Int64 in
			let params = try DistanceParams(distance: distance)
			return params.epfIterations == 2 ? 1 : 0
		}
		let swiftXScale = try distances.map {
			Int64(try DistanceParams(distance: $0).xQuantMatrixScale)
		}
		let swiftEPF = try distances.map {
			Int64(try DistanceParams(distance: $0).epfIterations)
		}
		let gaborishIssues = Set(19...27)
		let xScaleIssues = Set(Array(7...16) + Array(23...44))
		let epfIssues: Set<Int> = [43, 44]
		for index in distances.indices {
			let distance = distances[index]
			if gaborishIssues.contains(index) {
				withKnownIssue(Comment(rawValue: "GER-3387")) {
					#expect(
						swiftGaborish[index] == gaborish[index],
						"Gaborish at \(distance)")
				}
			} else {
				#expect(
					swiftGaborish[index] == gaborish[index],
					"Gaborish at \(distance)")
			}
			if xScaleIssues.contains(index) {
				withKnownIssue(Comment(rawValue: "GER-3387")) {
					#expect(
						swiftXScale[index] == xScale[index],
						"X matrix scale at \(distance)")
				}
			} else {
				#expect(
					swiftXScale[index] == xScale[index],
					"X matrix scale at \(distance)")
			}
			if epfIssues.contains(index) {
				withKnownIssue(Comment(rawValue: "GER-3387")) {
					#expect(
						swiftEPF[index] == epf[index],
						"EPF iterations at \(distance)")
				}
			} else {
				#expect(
					swiftEPF[index] == epf[index],
					"EPF iterations at \(distance)")
			}
			#expect(bScale[index] == 2, "B matrix scale at \(distance)")
		}
	}

	@Test("upstream group extents match Swift full-frame geometry")
	func quantizedCoefficientLayoutMatchesReference() throws {
		for (name, width, height) in [
			("flower_1024", 1024, 1024),
			("pixel_lifecycle_2057x521", 2057, 521),
		] {
			let pixels = try loadPPM(fixture: name)
			let encoded = try SwiftSemanticEncoding.encode(pixels, distance: 1)
			let groups = try #require(encoded.decisions.pixelGroups)
			let dim = ImageDim(width: width, height: height)
			let metadata = try SemanticDump(fixture: name + ".stages")
			#expect(
				metadata.fields["pixel_stages.dimensions"]
					== .integers([
						Int64(width), Int64(height),
						Int64(dim.widthInBlocks),
						Int64(dim.heightInBlocks), Int64(dim.groupCount),
						Int64(dim.dcGroupCount),
					]))
			#expect(
				metadata.fields["pixel_stages.quant_field_mismatches"]
					== .integers([0]))
			#expect(metadata.fields["pixel_stages.resampling"] == .integers([1]))
			#expect(
				metadata.fields["pixel_stages.streaming_mode"]
					== .integers([dim.groupCount > 8 ? 1 : 0]))
			if name == "pixel_lifecycle_2057x521" {
				#expect(
					metadata.fields["pixel_stages.dc_group_lifecycle"]
						== .integers([
							0, 1, 0, 0, 2056, 521, 2056, 528, 0, 0, 256,
							66,
							1, 0, 2040, 0, 17, 521, 24, 528, 8, 0, 2,
							66,
						]))
			}
			let groupsByIndex = Dictionary(
				uniqueKeysWithValues: groups.map {
					($0.groupY * dim.widthInGroups + $0.groupX, $0)
				})
			let groupDimValues: [Int64]
			switch try SemanticDump(fixture: name + ".stages").fields[
				"pixel_stages.ac_group_block_dims"]
			{
			case .integers(let values): groupDimValues = values
			default:
				Issue.record("missing AC group dimensions")
				continue
			}
			var referenceGroupDims: [Int: (Int64, Int64)] = [:]
			for offset in stride(from: 0, to: groupDimValues.count, by: 3) {
				referenceGroupDims[Int(groupDimValues[offset])] =
					(groupDimValues[offset + 1], groupDimValues[offset + 2])
			}
			for groupIndex in 0..<dim.groupCount {
				let group = try #require(groupsByIndex[groupIndex])
				let reference = try #require(referenceGroupDims[groupIndex])
				#expect(reference.0 == group.widthInBlocks)
				#expect(reference.1 == group.heightInBlocks)
			}
		}
	}

	@Test("every Swift AC and DC integer is compared with pinned upstream stages")
	func coefficientIntegersMatchPinnedStages() throws {
		for (name, width, height) in [
			("flower_1024", 1024, 1024),
			("pixel_lifecycle_2057x521", 2057, 521),
		] {
			let encoded = try SwiftSemanticEncoding.encode(
				loadPPM(fixture: name), distance: 1)
			let groups = try #require(encoded.decisions.pixelGroups)
			let swift = SwiftSemanticEncoding.coefficients(
				from: groups, dimension: ImageDim(width: width, height: height))
			let dimension = ImageDim(width: width, height: height)
			let metadata = try SemanticDump(fixture: name + ".stages")
			let groupValues: [Int64]
			switch metadata.fields["pixel_stages.ac_group_block_dims"] {
			case .integers(let values): groupValues = values
			default:
				Issue.record("missing AC group dimensions for \(name)")
				continue
			}
			let referenceGroups = stride(
				from: 0, to: groupValues.count, by: 3
			).map { offset in
				(
					index: Int(groupValues[offset]),
					width: Int(groupValues[offset + 1]),
					height: Int(groupValues[offset + 2])
				)
			}.sorted { $0.index < $1.index }
			// The binary is ordered by absolute group ID; lifecycle metadata is not.
			#expect(referenceGroups.map(\.index) == Array(0..<dimension.groupCount))
			let upstreamAC = try UInt32Fixture(
				name: name + ".ac", subdirectory: "Fixtures/semantic"
			).values.map {
				Int32(bitPattern: $0)
			}
			let upstreamDC = try UInt32Fixture(
				name: name + ".dc", subdirectory: "Fixtures/semantic"
			).values.map {
				Int32(bitPattern: $0)
			}
			var expectedAC = Array(
				repeating: Array(
					repeating: Int32(0),
					count: dimension.widthInBlocks * dimension.heightInBlocks
						* 64),
				count: 3)
			var sourceOffset = 0
			for referenceGroup in referenceGroups {
				let group = try #require(
					groups.first {
						$0.groupY * dimension.widthInGroups + $0.groupX
							== referenceGroup.index
					})
				let groupWidth = referenceGroup.width
				let groupHeight = referenceGroup.height
				let groupCoefficients = groupWidth * groupHeight * 64
				for channel in 0..<3 {
					for y in 0..<groupHeight {
						for x in 0..<groupWidth {
							let source =
								sourceOffset + channel
								* groupCoefficients
								+ (y * groupWidth + x) * 64
							let destination =
								((group.groupY
									* Geometry.groupDimInBlocks
									+ y)
									* dimension.widthInBlocks
									+ group.groupX
									* Geometry.groupDimInBlocks
									+ x) * 64
							expectedAC[channel][
								destination..<(destination + 64)] =
								upstreamAC[source..<(source + 64)]
						}
					}
				}
				sourceOffset += groupCoefficients * 3
			}
			#expect(sourceOffset == upstreamAC.count)
			#expect(
				upstreamDC.count == dimension.widthInBlocks
					* dimension.heightInBlocks * 3)
			for channel in 0..<3 {
				let acIssues =
					name == "flower_1024"
					? ["GER-3387", "GER-3419"] : ["GER-3387"]
				let acDifferences = zip(swift.ac[channel], expectedAC[channel])
					.enumerated().filter { $0.element.0 != $0.element.1 }
				let acDifferenceCount = acDifferences.count
				let firstACDifference = acDifferences.first?.offset
				#expect(swift.ac[channel].count == expectedAC[channel].count)
				withKnownIssue(Comment(rawValue: acIssues.joined(separator: ", ")))
				{
					#expect(
						acDifferenceCount == 0,
						"\(name)#ac.c\(channel): \(acDifferenceCount) differences; first \(firstACDifference?.description ?? "none")"
					)
				}
				let dcStart =
					channel * dimension.widthInBlocks * dimension.heightInBlocks
				let expectedChannelDC = upstreamDC[
					dcStart..<(dcStart + dimension.widthInBlocks
						* dimension.heightInBlocks)]
				let actualChannelDC = swift.dc[channel].map(Int32.init)
				let dcDifferences = zip(actualChannelDC, expectedChannelDC)
					.enumerated().filter { $0.element.0 != $0.element.1 }
				let dcDifferenceCount = dcDifferences.count
				let firstDCDifference = dcDifferences.first?.offset
				#expect(actualChannelDC.count == expectedChannelDC.count)
				withKnownIssue(Comment(rawValue: "GER-3387")) {
					#expect(
						dcDifferenceCount == 0,
						"\(name)#dc.c\(channel): \(dcDifferenceCount) differences; first \(firstDCDifference?.description ?? "none")"
					)
				}
			}
		}
	}

	@Test("full-frame coefficient placement preserves channel, group, and block identity")
	func coefficientPlacementPreservesDistinctValues() {
		let dimension = ImageDim(width: 513, height: 257)
		var groups: [Encoder.ACGroupCompute] = []
		for index in 0..<dimension.groupCount {
			let gx = index % dimension.widthInGroups
			let gy = index / dimension.widthInGroups
			let rect = dimension.pixelRect(ix: gx, iy: gy, dim: Geometry.groupDim)
			let groupDim = ImageDim(width: rect.width, height: rect.height)
			let blocks = groupDim.widthInBlocks * groupDim.heightInBlocks
			var coefficients = [[Int32]](repeating: [], count: 3)
			var quantDC = [[Int16]](repeating: [], count: 3)
			for channel in 0..<3 {
				var channelCoefficients: [Int32] = []
				channelCoefficients.reserveCapacity(blocks * 64)
				for offset in 0..<(blocks * 64) {
					channelCoefficients.append(
						Int32(channel * 1_000_000 + index * 10_000 + offset)
					)
				}
				coefficients[channel] = channelCoefficients

				var channelDC: [Int16] = []
				channelDC.reserveCapacity(blocks)
				for block in 0..<blocks {
					channelDC.append(
						Int16(channel * 1000 + index * 100 + block))
				}
				quantDC[channel] = channelDC
			}
			let group = Encoder.ACGroupCompute(
				groupX: gx, groupY: gy,
				widthInBlocks: groupDim.widthInBlocks,
				heightInBlocks: groupDim.heightInBlocks,
				coefficients: coefficients,
				quantDC: quantDC, quantField: [])
			groups.append(group)
		}
		let result = SwiftSemanticEncoding.coefficients(from: groups, dimension: dimension)
		for channel in 0..<3 {
			for group in groups {
				for block in 0..<(group.widthInBlocks * group.heightInBlocks) {
					let x =
						group.groupX * Geometry.groupDimInBlocks + block
						% group.widthInBlocks
					let y =
						group.groupY * Geometry.groupDimInBlocks + block
						/ group.widthInBlocks
					let destination = y * dimension.widthInBlocks + x
					let base = Int32(
						channel * 1_000_000
							+ (group.groupY * dimension.widthInGroups
								+ group.groupX) * 10_000 + block
							* 64)
					#expect(
						Array(
							result.ac[channel][
								(destination * 64)..<(destination
									* 64 + 64)])
							== (0..<64).map { base + Int32($0) })
					#expect(
						result.dc[channel][destination]
							== Int16(
								channel * 1000
									+ (group.groupY
										* dimension
										.widthInGroups
										+ group.groupX)
									* 100 + block))
				}
			}
		}
	}
}

@Suite("Quantization matrix fixtures")
struct QuantMatrixFixtureTests {
	@Test(
		"forward quantization matrices and DC constants match the pinned reference exactly",
	)
	func matricesMatchReference() throws {
		let reference = try SemanticDump(fixture: "edge")
		let emitted = try SemanticDump(
			swiftDecisions: try SemanticCorpusEntry.all[0].encoded().decisions)
		let categories: Set<String> = ["quant_matrix", "dc_quant_matrix"]
		for category in categories {
			let expected = reference.restricted(to: [category])
			let actual = emitted.restricted(to: [category])
			#expect(!expected.fields.isEmpty, "missing \(category) fixture")
			#expect(actual.differences(from: expected).isEmpty)
		}
	}

	@Test(
		"inverse quantization matrices and DC constants are compared independently",
	)
	func inverseMatricesMatchReference() throws {
		let reference = try SemanticDump(fixture: "edge")
		let emitted = try SemanticDump(
			swiftDecisions: try SemanticCorpusEntry.all[0].encoded().decisions)
		let categories: Set<String> = ["inverse_quant_matrix", "inverse_dc_quant_matrix"]
		for category in categories {
			let expected = reference.restricted(to: [category])
			let actual = emitted.restricted(to: [category])
			#expect(!expected.fields.isEmpty, "missing \(category) fixture")
			if category == "inverse_quant_matrix" {
				withKnownIssue(Comment(rawValue: "GER-3387")) {
					#expect(actual.differences(from: expected).isEmpty)
				}
			} else {
				#expect(actual.differences(from: expected).isEmpty)
			}
		}
	}
}

extension QuantizerTests {
	@Test(
		"bounded quantized conversions match actual upstream integer decisions",
	)
	func quantizedConversionMatchesReferenceOnBoundedValues() throws {
		let reference = try SemanticDump(fixture: "bounded_quantized")
		let expected = reference.restricted(to: ["quantized_ac"])
		#expect(reference.fields["quantized_ac.neon_target"] == .integers([1]))
		let coefficients = (0..<DCT.blockSize).map { index in
			Float((index * 37) % 101 - 50) * 0.03125
		}
		let multipliers: [Float] = [1.25, 1, 1]
		var emitted = SemanticDump()
		emitted.record("quantized_ac.neon_target", .integers([1]))
		for channel in 0..<3 {
			let actual = Quantizer.quantizeBlockAC(
				coefficients: coefficients[...], channel: channel,
				inverseMatrix: QuantMatrices.inverseMatrix(channel: channel),
				quant: 5,
				scale: 0.1120758056640625, matrixMultiplier: multipliers[channel])
			emitted.record(
				"quantized_ac.c\(channel)", .integers(actual.map(Int64.init)))
		}
		#expect(expected.fields.count == 4, "reference includes target and channel fields")
		#expect(emitted.differences(from: expected).isEmpty)
	}
}

extension ReciprocalEstimateTests {
	@Test("quantization bias matches the pinned upstream NEON routine")
	func quantBiasMatchesPinnedNEON() throws {
		let comparison = SemanticPrimitiveCase.quantBias
		let reference = try SemanticDump(fixture: comparison.fixture)
		let expected = reference.restricted(to: [comparison.category])
		#expect(reference.fields["quant_bias.neon_target"] == .integers([1]))
		#expect(comparison.knownIssues.isEmpty)
		var emitted = SemanticDump()
		emitted.record("quant_bias.neon_target", .integers([1]))
		for channel in comparison.channels {
			let bits = comparison.inputs.map { quantized in
				Int64(
					Quantizer.adjustQuantBias(
						channel: channel, quantized: quantized
					).bitPattern)
			}
			emitted.record("quant_bias.c\(channel)", .integers(bits))
		}
		#expect(expected.fields.count == 4)
		#expect(emitted.differences(from: expected).isEmpty)
	}
}

extension ChromaSubsamplingTests {
	@Test("coded block counts match upstream for supported shifts")
	func codedBlockCountsMatchReference() throws {
		let reference = try SemanticDump(fixture: "coded_dimensions")
		let inputDimensions = [1, 7, 8, 9, 15, 16, 17, 255, 256, 257]
		#expect(
			reference.fields["coded_blocks.dimensions"]
				== .integers(inputDimensions.map(Int64.init)))
		var emitted = SemanticDump()
		var widths: [Int64] = []
		var heights: [Int64] = []
		var blockWidths: [String: [Int64]] = [:]
		var blockHeights: [String: [Int64]] = [:]
		for hshift in 0...1 {
			for vshift in 0...1 {
				let suffix = "h\(hshift)v\(vshift)"
				blockWidths["coded_blocks.width_blocks." + suffix] = []
				blockHeights["coded_blocks.height_blocks." + suffix] = []
			}
		}
		for width in inputDimensions {
			for height in inputDimensions {
				widths.append(Int64(width))
				heights.append(Int64(height))
				for hshift in 0...1 {
					for vshift in 0...1 {
						let dim = ImageDim(
							width: width, height: height,
							blockAlignment: (
								x: 1 << hshift, y: 1 << vshift
							))
						let suffix = "h\(hshift)v\(vshift)"
						blockWidths["coded_blocks.width_blocks." + suffix]?
							.append(
								Int64(dim.widthInBlocks))
						blockHeights[
							"coded_blocks.height_blocks." + suffix]?
							.append(
								Int64(dim.heightInBlocks))
					}
				}
			}
		}
		emitted.record(
			"coded_blocks.dimensions", .integers(inputDimensions.map(Int64.init)))
		emitted.record("coded_blocks.widths", .integers(widths))
		emitted.record("coded_blocks.heights", .integers(heights))
		for (name, values) in blockWidths { emitted.record(name, .integers(values)) }
		for (name, values) in blockHeights { emitted.record(name, .integers(values)) }
		#expect(emitted.differences(from: reference).isEmpty)
	}
}

extension ImageHeaderTests {
	@Test(
		"image header capture preserves the transfer function passed to the writer",
	)
	func imageHeaderTransferFunctionIsCaptured() throws {
		let linearInput = try StageDump(fixture: "edge_linear")
		let linear = try SwiftSemanticEncoding.encode(linear: linearInput, distance: 1)
		let srgbInput = try loadPPM(fixture: "flower_512")
		let srgb = try SwiftSemanticEncoding.encode(srgbInput, distance: 1)
		for (result, value) in [(linear, 8), (srgb, 13)] {
			#expect(
				try SemanticDump(swiftDecisions: result.decisions).fields[
					"image_header.transfer_function"]
					== .integers([Int64(value)]))
			var written = BitWriter()
			try ImageHeader.write(
				width: result.decisions.width, height: result.decisions.height,
				transferFunction: result.decisions.transferFunction, to: &written)
			#expect(
				Array(result.codestream.prefix(written.bytes.count))
					== written.bytes)
		}
	}
}
