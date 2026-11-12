import Testing

@Suite("Pixel semantic fixtures")
struct PixelSemanticFixtureTests {
	@Test(
		"image header fields match the pinned reference independently of sample format",
		.disabled("Awaiting independent image-header fixtures and exact field comparisons"))
	func imageHeaderFieldsMatchReference() {
		Issue.record(
			"Compare decoded size, transfer function, color metadata, XYB and extra-channel fields exactly against the pinned reference."
		)
	}

	@Test(
		"filter decisions match the pinned reference as independent comparison units",
		.disabled(
			"Awaiting independent frame-flag, gaborish, EPF and matrix-scale fixtures"))
	func filterFieldsMatchReference() {
		Issue.record(
			"Compare frame flags, gaborish, EPF iterations and separate X/B matrix scales exactly without one known divergence masking another unit."
		)
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
		.disabled(
			"Awaiting forward AC and DC matrix fixtures with strict float comparisons"))
	func matricesMatchReference() {
		Issue.record(
			"Compare all 64 forward matrix entries in each X/Y/B channel and the separate forward DC constants with zero-ULP float equality, preserving signed zero."
		)
	}

	@Test(
		"inverse quantization matrices and DC constants are compared independently",
		.disabled("Awaiting inverse AC and DC matrix fixtures with explicit DC-slot policy")
	)
	func inverseMatricesMatchReference() {
		Issue.record(
			"Compare all 64 inverse matrix entries per channel, including the already-zero DC slot, and separate inverse DC constants with zero-ULP equality; isolate documented inverse divergences."
		)
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
		.disabled("Awaiting linear and sRGB header capture comparisons"))
	func imageHeaderTransferFunctionIsCaptured() {
		Issue.record(
			"Compare captured linear and sRGB transfer functions with the corresponding written and reference-decoded image headers."
		)
	}
}
