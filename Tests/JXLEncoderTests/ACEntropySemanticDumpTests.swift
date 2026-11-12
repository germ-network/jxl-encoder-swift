import Testing

@testable import JXLEncoder

@Suite("AC entropy semantic records")
struct ACEntropySemanticDumpTests {
	@Test(.disabled("Awaiting AC entropy reference implementation"))
	func acEntropyTablesMatchReference() throws {
		Issue.record("ANS, prefix and singleton tables match their actual reference code.")
	}

	@Test(.disabled("Awaiting AC entropy reference implementation"))
	func acEntropyPreservesTransmittedTableOrder() throws {
		Issue.record("Entropy table order remains the order transmitted by the code.")
	}

	@Test(.disabled("Awaiting AC entropy reference implementation"))
	func acEntropyCanonicalizesPrefixSingletons() throws {
		Issue.record("Singleton prefix tables use their zero-bit decoder representation.")
	}

	@Test(.disabled("Awaiting AC entropy reference implementation"))
	func acEntropyRejectsMalformedCapturesAtomically() throws {
		Issue.record("Invalid entropy data fails before the dump is changed.")
	}

	@Test(.disabled("Awaiting AC entropy reference implementation"))
	func acEntropyMutationIsReportedByItsExactField() throws {
		Issue.record("A code-table mutation reports its exact entropy field.")
	}

	@Test(.disabled("Awaiting AC entropy reference implementation"))
	func alphabetDivergenceDoesNotMaskEntropyMutation() throws {
		Issue.record("An alphabet-size known issue does not mask an entropy-table change.")
	}
}
