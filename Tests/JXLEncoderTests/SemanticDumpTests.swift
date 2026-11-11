import Foundation
import Testing

/// The semantic dump is the contract between the reference harness and these
/// tests: integers compare exactly, floats within a documented per-field
/// tolerance, and any added, missing or reshaped field is a difference.
@Suite("Semantic dump format")
struct SemanticDumpTests {
	@Test("serializing then parsing gives an equal dump, independent of record order")
	func roundTrips() throws {
		Issue.record("unimplemented")
	}

	@Test(
		"the harness writer's golden output parses to the expected dump",
		.enabled(if: PackageCheckout.isAvailable))
	func parsesHarnessGolden() throws {
		Issue.record("unimplemented")
	}

	@Test("a bad header, malformed line, duplicate field or unparsable value throws")
	func rejectsMalformedText() throws {
		Issue.record("unimplemented")
	}

	@Test("integer fields compare exactly")
	func integersExact() throws {
		Issue.record("unimplemented")
	}

	@Test("float fields compare within their tolerance, and fail just outside it")
	func floatsWithinTolerance() throws {
		Issue.record("unimplemented")
	}

	@Test("a float field without a documented tolerance is reported, not compared")
	func floatWithoutToleranceReported() throws {
		Issue.record("unimplemented")
	}

	@Test("missing, unexpected, kind and count differences are each reported")
	func structuralDifferences() throws {
		Issue.record("unimplemented")
	}

	@Test("one flipped entry in a long integer field is caught")
	func singleFlipCaught() throws {
		Issue.record("unimplemented")
	}

	@Test("restricting to categories keeps exactly those fields")
	func restrictsByCategory() throws {
		Issue.record("unimplemented")
	}

	@Test("every documented tolerance names a float field some committed fixture carries")
	func documentedTolerancesAreUsed() throws {
		Issue.record("unimplemented")
	}
}
