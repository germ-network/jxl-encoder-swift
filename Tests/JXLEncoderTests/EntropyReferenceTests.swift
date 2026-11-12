import Testing

@Suite("Entropy reference contracts")
struct EntropyReferenceTests {
	@Test(.disabled("Awaiting entropy reference implementation"))
	func normalizedTablesAndPrecisionMatchReference() throws {
		Issue.record(
			"Normalized frequencies and selected precision match the pinned reference.")
	}

	@Test(.disabled("Awaiting entropy reference implementation"))
	func fastAndBestClustersMatchReference() throws {
		Issue.record(
			"Fast and best clustering choices have isolated reference comparisons.")
	}

	@Test(.disabled("Awaiting entropy reference implementation"))
	func contextMapChoiceMatchesReference() throws {
		Issue.record(
			"Context map coding choices match the reference for identical map inputs.")
	}

	@Test(.disabled("Awaiting entropy reference implementation"))
	func predefinedMATreeMatchesReference() throws {
		Issue.record("Predefined tree nodes and tokens match the reference configuration.")
	}

	@Test(.disabled("Awaiting entropy reference implementation"))
	func modularLeafContextsAndResidualsMatchReference() throws {
		Issue.record(
			"Modular leaf contexts and packed residuals match for identical samples.")
	}

	@Test(.disabled("Awaiting entropy reference implementation"))
	func acTokenContextsAndValuesMatchReference() throws {
		Issue.record(
			"Prescribed AC coefficients produce the reference token contexts and values."
		)
	}

	@Test(.disabled("Awaiting entropy reference implementation"))
	func sampledCoefficientStatisticsMatchReference() throws {
		Issue.record(
			"Observed coefficient statistics preserve group-boundary sampling behavior."
		)
	}

	@Test(.disabled("Awaiting entropy reference implementation"))
	func coefficientSortKeysMatchReferenceBelowRoundingBoundary() throws {
		Issue.record("Counts below 2^22 preserve reference ordering at bucket transitions.")
	}

	@Test(.disabled("Awaiting entropy reference implementation"))
	func coefficientSortKeysExposeRoundingBoundaryDivergence() throws {
		Issue.record(
			"The observed coefficient boundary retains its isolated GER-3386 divergence."
		)
	}

	@Test(.disabled("Awaiting entropy reference implementation"))
	func naturalDCT8OrderMatchesReference() throws {
		Issue.record("The natural DCT8 order equals the pinned upstream order.")
	}

	@Test(.disabled("Awaiting entropy reference implementation"))
	func smallFrameSharesOneACCodeAcrossIndependentGroupStreams() throws {
		Issue.record(
			"Small multigroup frames share one code across independently decodable streams."
		)
	}

	@Test(.disabled("Awaiting entropy reference implementation"))
	func streamingLayoutMatchesReferenceAboveEightGroups() throws {
		Issue.record(
			"Eligible large reference frames expose their streaming histogram partition."
		)
	}

	@Test(.disabled("Awaiting entropy reference implementation"))
	func entropyMutationIsReportedByItsExactField() throws {
		Issue.record("An entropy mutation is reported only by its changed semantic field.")
	}
}
