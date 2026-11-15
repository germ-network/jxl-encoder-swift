import Testing

@testable import JXLEncoder

@Suite("Pixel block entropy model")
struct PixelBlockEntropyModelTests {
	@Test(
		"Below the truncated model-size gate, all 39 default entries and 15 categories survive.",
		.disabled("Awaiting implementation"))
	func smallImagesRetainFullReferenceDefaultMap() throws {
		Issue.record(
			"Below the truncated model-size gate, all 39 default entries and 15 categories survive."
		)
	}

	@Test(
		"Model and quant-split decisions match below, at and above truncated Float distance gates.",
		.disabled("Awaiting implementation"))
	func modelSizeAndDistanceBoundariesMatchReference() throws {
		Issue.record(
			"Model and quant-split decisions match below, at and above truncated Float distance gates."
		)
	}

	@Test(
		"Uniform and mixed quant histograms preserve strict cuts and following-index recovery, including raw quant 1, 2, 255 and 256.",
		.disabled("Awaiting implementation"))
	func quantThresholdRecoveryMatchesReference() throws {
		Issue.record(
			"Uniform and mixed quant histograms preserve strict cuts and following-index recovery, including raw quant 1, 2, 255 and 256."
		)
	}

	@Test(
		"All transmitted entries and category counts match source sorting for reachable 13 and 26 entry lists.",
		.disabled("Awaiting implementation"))
	func tieHeavyFullMapsMatchPinnedSort() throws {
		Issue.record(
			"All transmitted entries and category counts match source sorting for reachable 13 and 26 entry lists."
		)
	}

	@Test(
		"Each channel uses the reference slot permutation and raw quant greater-than threshold lookup.",
		.disabled("Awaiting implementation"))
	func categoryLookupUsesStrictRawQuantBoundaries() throws {
		Issue.record(
			"Each channel uses the reference slot permutation and raw quant greater-than threshold lookup."
		)
	}

	@Test(
		"Transmitted DC lists, quant thresholds minus one, map entries and category count match the source wire fields.",
		.disabled("Awaiting implementation"))
	func quantThresholdWireFieldsMatchReference() throws {
		Issue.record(
			"Transmitted DC lists, quant thresholds minus one, map entries and category count match the source wire fields."
		)
	}

	@Test(
		"AC nonzero and coefficient tokens use the model category and full category count for every group block.",
		.disabled("Awaiting implementation"))
	func adaptiveTokensUseActualCategoryCount() throws {
		Issue.record(
			"AC nonzero and coefficient tokens use the model category and full category count for every group block."
		)
	}

	@Test(
		"Production computed models match bounded upstream decisions for large photos and non-default models without claiming full coefficient recovery.",
		.disabled("Awaiting implementation"))
	func productionModelMatchesLargePhotoObservations() throws {
		Issue.record(
			"Production computed models match bounded upstream decisions for large photos and non-default models without claiming full coefficient recovery."
		)
	}

	@Test(
		"Sequential and concurrent optimized encodes carry the same frame model and produce identical bytes.",
		.disabled("Awaiting implementation"))
	func sequentialAndConcurrentModelsAgree() throws {
		Issue.record(
			"Sequential and concurrent optimized encodes carry the same frame model and produce identical bytes."
		)
	}

}
