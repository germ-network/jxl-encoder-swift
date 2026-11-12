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
				withKnownIssue(issues.joined(separator: ", ")) {
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

	@Test(
		"quant fields match the reference around clamp and decision boundaries",
		.disabled("Awaiting predecessor, exact and successor distance fixtures"))
	func quantFieldBoundaryDistancesMatchReference() {
		Issue.record(
			"Compare exact quant fields at Swift and upstream clamp, quantization, matrix and filter transitions, including distinct 0.03 and 0.05 cases and pow-sensitive distances."
		)
	}

	@Test(
		"quantized coefficients preserve channel and full-frame block placement",
		.disabled(
			"Awaiting distinctive layout inputs and real upstream coefficient observations"
		))
	func quantizedCoefficientLayoutMatchesReference() {
		Issue.record(
			"Verify every AC/DC channel and block position using distinctive groups and real upstream output, including the sixteen-group image and sequential 2057x521 two-DC-group case with cropped borders and retained global state."
		)
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
				withKnownIssue("inverse AC matrix has known 1 ULP entries") {
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
		.disabled(
			"Awaiting pinned primitive inputs and explicit conversion-domain evidence"))
	func quantizedConversionMatchesReferenceOnBoundedValues() {
		Issue.record(
			"Compare every quantized integer for all channels over explicitly bounded inputs and fixed primitive parameters, retaining ties-even, threshold and DC-zero invariants without claiming unrestricted conversion safety."
		)
	}
}

extension DCQuantizationTests {
	@Test(
		"DC quantization matches upstream at distance bounds",
		.disabled("Awaiting exact upstream DC integer observations at distance bounds"))
	func quantizedDCMatchesReferenceAtDistanceBounds() {
		Issue.record(
			"Compare X/Y/B DC integers at distance bounds with explicit DC precision and correlation factors, preserving fused arithmetic, ties-away rounding and B subtraction."
		)
	}
}

extension ReciprocalEstimateTests {
	@Test(
		"quantization bias matches the pinned upstream NEON routine",
		.disabled("Awaiting actual AdjustQuantBias NEON input and output bit fixtures"))
	func quantBiasMatchesPinnedNEON() {
		Issue.record(
			"Assert the pinned NEON target and compare actual AdjustQuantBias float bits for every channel at zero, both signs of one and two, and bounded larger magnitudes with zero-ULP equality."
		)
	}
}

extension ChromaSubsamplingTests {
	@Test(
		"coded block counts match the upstream dimension primitive",
		.disabled("Awaiting upstream coded-dimension fixtures for supported shifts"))
	func codedBlockCountsMatchReference() {
		Issue.record(
			"Compare exact coded block counts for supported shifts at dimensions 1, 7, 8, 9, 15, 16, 17, 255, 256 and 257, including asymmetric axes."
		)
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
