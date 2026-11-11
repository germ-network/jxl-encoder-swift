import Foundation
import Testing

/// A `faithful` or `adapted` decision whose upstream output is pinned by a
/// full-libjxl fixture, compared without a known issue, no longer needs
/// GER-3392 to verify it; the inventory's `fixture` column names that fixture.
@Suite("Decision inventory fixture references")
struct DecisionInventoryFixtureTests {
	@Test("the header ends with the fixture column")
	func headerHasFixtureColumn() {
		Issue.record("unimplemented")
	}

	@Test("a cited faithful or adapted row with a verifying fixture needs no GER-3392")
	func fixtureSettlesUnprovenClaim() {
		Issue.record("unimplemented")
	}

	@Test("a fixture does not settle inherited-tiny or original rows")
	func fixtureDoesNotSettleDeviations() {
		Issue.record("unimplemented")
	}

	@Test(
		"a fixture that is missing, not full-libjxl, not compared, or under a known issue is a violation"
	)
	func fixtureMustVerify() {
		Issue.record("unimplemented")
	}

	@Test("a malformed list, or a .sem without a category, is a violation")
	func fixtureListWellFormed() {
		Issue.record("unimplemented")
	}

	@Test(
		"every committed fixture reference verifies",
		.enabled(if: PackageCheckout.isAvailable))
	func committedFixtureReferencesVerify() throws {
		Issue.record("unimplemented")
	}
}
