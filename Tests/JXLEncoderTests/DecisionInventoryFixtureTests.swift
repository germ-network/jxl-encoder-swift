import Foundation
import Testing

/// A `faithful` or `adapted` decision whose upstream output is pinned by a
/// full-libjxl fixture, compared without a known issue, no longer needs
/// GER-3392 to verify it; the inventory's `fixture` column names that fixture.
@Suite("Decision inventory fixture references")
struct DecisionInventoryFixtureTests {
	static let path = "Tests/JXLEncoderTests/Fixtures/semantic/example.sem#frame"

	static func check(
		_ overrides: [String: String], status: DecisionInventory.FixtureStatus = .verifies
	) -> [DecisionInventory.Violation] {
		let inventory = DecisionInventory(
			inventoryTSV: DecisionInventoryTests.header + "\n"
				+ DecisionInventoryTests.row(overrides) + "\n",
			exemptTSV: DecisionInventoryTests.exemptHeader + "\n")
		return inventory.parseViolations
			+ inventory.violations(
				fileExists: { _ in true }, fixtureStatus: { _ in status })
	}

	static func committedStatus(_ reference: DecisionInventory.FixtureReference)
		-> DecisionInventory.FixtureStatus
	{
		guard
			let manifest = try? ProvenanceManifest(
				contentsOf: RepositoryLayout.provenanceManifest),
			let row = manifest.rows.first(where: {
				$0.kind == .fixture && $0.path == reference.path
			})
		else { return .missing }
		guard PackageCheckout.fileExists(reference.path) else { return .missing }
		return Self.status(reference, row: row)
	}

	private static func status(
		_ reference: DecisionInventory.FixtureReference, row: ProvenanceRow
	) -> DecisionInventory.FixtureStatus {
		guard row.origin == .fullLibjxl else { return .notFullLibjxl }
		if StageFixtureKnownIssues.byFixture[reference.path] != nil { return .knownIssue }
		if let category = reference.category {
			let key = reference.path + "#" + category
			if JPEGSemanticCase.contextWitnessReferences.contains(key) {
				let fixture = URL(fileURLWithPath: reference.path)
					.deletingPathExtension().lastPathComponent
				guard
					JPEGSemanticCase.contextWitnessContains(
						category, fixture: fixture)
				else { return .notCompared }
			}
			let references = SemanticCase.references.union(JPEGSemanticCase.references)
				.union(
					JPEGSemanticCase.contextWitnessReferences)
			guard references.contains(key) else { return .notCompared }
			let knownIssues = SemanticCase.knownIssueReferences.union(
				JPEGSemanticCase.knownIssueReferences)
			if knownIssues.contains(key) { return .knownIssue }
		} else if row.consumers.isEmpty {
			return .notCompared
		}
		return .verifies
	}
	@Test("the header ends with the fixture column")
	func headerHasFixtureColumn() {
		#expect(DecisionInventory.columns.last == "fixture")
		#expect(DecisionInventory.columns.count == 14)
	}

	@Test("a cited faithful or adapted row with a verifying fixture needs no GER-3392")
	func fixtureSettlesUnprovenClaim() {
		for classification in ["faithful", "adapted"] {
			#expect(
				Self.check([
					"classification": classification, "verification": "cited",
					"notes": "equivalent", "fixture": Self.path,
				]).isEmpty)
		}
	}

	@Test("a fixture does not settle inherited-tiny or original rows")
	func fixtureDoesNotSettleDeviations() {
		for classification in ["inherited-tiny", "original"] {
			#expect(
				Self.check(["classification": classification, "fixture": Self.path])
					.contains { $0.rule == .replacementRequired })
		}
	}

	@Test(
		"a fixture that is missing, not full-libjxl, not compared, or under a known issue is a violation"
	)
	func fixtureMustVerify() {
		for status: DecisionInventory.FixtureStatus in [
			.missing, .notFullLibjxl, .knownIssue, .notCompared,
		] {
			let violations = Self.check(
				["verification": "cited", "fixture": Self.path], status: status)
			#expect(violations.contains { $0.rule == .fixtureReference })
			#expect(violations.contains { $0.rule == .replacementRequired })
		}
		let path = "Tests/JXLEncoderTests/Fixtures/unconsumed.dump"
		guard let reference = DecisionInventory.FixtureReference(path) else {
			Issue.record("invalid stage fixture reference")
			return
		}
		for consumers in [[], ["StageTests.swift"]] as [[String]] {
			let row = ProvenanceRow(
				path: path, kind: .fixture,
				sha256: String(repeating: "a", count: 64),
				origin: .fullLibjxl, generator: "generator", invocation: "generate",
				input: "input", upstream: DecisionInventory.pinnedUpstream,
				config: "hwy=NEON", consumers: consumers)
			#expect(
				Self.status(reference, row: row)
					== (consumers.isEmpty ? .notCompared : .verifies))
		}
	}

	@Test("a JPEG witness reference names a present, compared category")
	func jpegWitnessCategoryIsVerified() throws {
		let fixture = "jpeg_flower_513x267_420_context"
		let expected = try SemanticDump(fixture: fixture)
		#expect(JPEGSemanticCase.contextWitnessContains("jpeg_context", fixture: fixture))
		#expect(!JPEGSemanticCase.contextWitnessContains("block_context", fixture: fixture))
		#expect(expected.fields.keys.contains { $0.hasPrefix("jpeg_context.") })
		#expect(!expected.fields.keys.contains { $0.hasPrefix("block_context.") })
		let invalidReference =
			"Tests/JXLEncoderTests/Fixtures/semantic/\(fixture).sem#block_context"
		guard let reference = DecisionInventory.FixtureReference(invalidReference),
			let manifest = try? ProvenanceManifest(
				contentsOf: RepositoryLayout.provenanceManifest),
			let row = manifest.rows.first(where: { $0.path == reference.path })
		else {
			Issue.record("missing JPEG context witness provenance")
			return
		}
		#expect(Self.status(reference, row: row) == .notCompared)
	}

	@Test("a malformed list, or a .sem without a category, is a violation")
	func fixtureListWellFormed() {
		for invalid in [
			"", ",", Self.path + ",", "," + Self.path, Self.path + ", " + Self.path,
			"a.sem", "a.sem#", "a.dump#frame", "a.sem#frame#size", "a.sem#bad.category",
		] {
			#expect(
				Self.check(["fixture": invalid]).contains {
					$0.rule == .fixtureReference || $0.rule == .shape
				}, "\(invalid)")
		}
		#expect(Self.check(["fixture": "a.dump," + Self.path]).isEmpty)
		#expect(Self.check(["fixture": "-"]).isEmpty)
	}

	@Test(
		"every committed fixture reference verifies",
		.enabled(if: PackageCheckout.isAvailable))
	func committedFixtureReferencesVerify() throws {
		let inventory = try DecisionInventoryTests.committed()
		let violations =
			inventory.parseViolations
			+ inventory.violations(
				fileExists: PackageCheckout.fileExists,
				fixtureStatus: Self.committedStatus)
		#expect(
			violations.isEmpty,
			"\(violations.map(\.description).joined(separator: "\n"))")
	}
}
