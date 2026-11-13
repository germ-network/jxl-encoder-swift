import Foundation
import Testing

/// A `faithful` or `adapted` decision whose upstream output is pinned by a
/// full-libjxl fixture, compared without a known issue, no longer needs
/// GER-3392 to verify it; the inventory's `fixture` column names that fixture.
@Suite("Decision inventory fixture references")
struct DecisionInventoryFixtureTests {
	static let path = "Tests/JXLEncoderTests/Fixtures/semantic/example.sem#frame"

	private static var pinnedCommit: String? {
		guard let pin = try? PinRecord(contentsOf: RepositoryLayout.pinRecord) else {
			return nil
		}
		return pin["LIBJXL_COMMIT"]
	}

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
		guard let pinnedCommit = Self.pinnedCommit else { return .notFullLibjxl }
		return Self.status(reference, row: row, pinnedCommit: pinnedCommit)
	}

	private static func status(
		_ reference: DecisionInventory.FixtureReference, row: ProvenanceRow,
		pinnedCommit: String?
	) -> DecisionInventory.FixtureStatus {
		guard row.origin == .fullLibjxl,
			let pinnedCommit,
			row.upstream == "libjxl \(pinnedCommit)"
		else { return .notFullLibjxl }
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
			let references = SemanticCase.references
				.union(JPEGSemanticCase.references)
				.union(JPEGSemanticCase.contextWitnessReferences)
			guard references.contains(key) else { return .notCompared }
			let knownIssues = SemanticCase.knownIssueReferences
				.union(JPEGSemanticCase.knownIssueReferences)
			if knownIssues.contains(key) { return .knownIssue }
		} else {
			guard
				let comparison = StageFixtureCase.all.first(where: {
					$0.referencePath == reference.path
				})
			else { return .notCompared }
			if !comparison.knownIssues.isEmpty { return .knownIssue }
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
		let pinnedCommit = Self.pinnedCommit ?? "missing"
		let comparison = SemanticPrimitiveCase.quantBias
		guard let reference = DecisionInventory.FixtureReference(comparison.reference)
		else {
			Issue.record("invalid primitive fixture reference")
			return
		}
		func row(
			path: String, origin: ProvenanceOrigin = .fullLibjxl,
			upstream: String? = nil, consumers: [String] = []
		) -> ProvenanceRow {
			ProvenanceRow(
				path: path, kind: .fixture,
				sha256: String(repeating: "a", count: 64),
				origin: origin, generator: "generator", invocation: "generate",
				input: "input", upstream: upstream ?? "libjxl \(pinnedCommit)",
				config: "hwy=NEON", consumers: consumers)
		}
		#expect(
			Self.status(
				reference, row: row(path: reference.path),
				pinnedCommit: pinnedCommit)
				== .verifies)

		guard
			let unknownCategory = DecisionInventory.FixtureReference(
				"Tests/JXLEncoderTests/Fixtures/semantic/quant_bias.sem#unknown")
		else {
			Issue.record("invalid unknown-category reference")
			return
		}
		#expect(
			Self.status(
				unknownCategory, row: row(path: unknownCategory.path),
				pinnedCommit: pinnedCommit) == .notCompared)

		guard
			let knownIssue = DecisionInventory.FixtureReference(
				"Tests/JXLEncoderTests/Fixtures/semantic/edge.sem#inverse_quant_matrix"
			)
		else {
			Issue.record("invalid known-issue reference")
			return
		}
		#expect(
			Self.status(
				knownIssue, row: row(path: knownIssue.path),
				pinnedCommit: pinnedCommit)
				== .knownIssue)
		#expect(
			Self.status(
				reference,
				row: row(path: reference.path, upstream: "libjxl wrong-pin"),
				pinnedCommit: pinnedCommit) == .notFullLibjxl)
		#expect(
			Self.status(
				reference, row: row(path: reference.path, origin: .handSupplied),
				pinnedCommit: pinnedCommit) == .notFullLibjxl)

		let unconsumedPath = "Tests/JXLEncoderTests/Fixtures/unconsumed.dump"
		guard let unconsumed = DecisionInventory.FixtureReference(unconsumedPath) else {
			Issue.record("invalid unconsumed stage reference")
			return
		}
		for consumers in [[], ["StageTests.swift"]] as [[String]] {
			#expect(
				Self.status(
					unconsumed,
					row: row(path: unconsumedPath, consumers: consumers),
					pinnedCommit: pinnedCommit) == .notCompared)
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
		let path = "Tests/JXLEncoderTests/Fixtures/semantic/\(fixture).sem"
		let pinnedCommit = Self.pinnedCommit ?? "missing"
		let row = ProvenanceRow(
			path: path, kind: .fixture,
			sha256: String(repeating: "a", count: 64), origin: .fullLibjxl,
			generator: "generator", invocation: "generate", input: "input",
			upstream: "libjxl \(pinnedCommit)", config: "hwy=NEON",
			consumers: ["JPEGSemanticFixtureTests.swift"])
		let validReference = try #require(
			DecisionInventory.FixtureReference(path + "#jpeg_context"))
		let invalidReference = try #require(
			DecisionInventory.FixtureReference(path + "#block_context"))
		#expect(
			Self.status(validReference, row: row, pinnedCommit: pinnedCommit)
				== .verifies)
		#expect(
			Self.status(invalidReference, row: row, pinnedCommit: pinnedCommit)
				== .notCompared)
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
