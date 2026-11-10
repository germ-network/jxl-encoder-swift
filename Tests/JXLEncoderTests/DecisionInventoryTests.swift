import Foundation
import Testing

/// Every production encoder decision is recorded in
/// `Reference/decision-inventory.tsv` with its upstream libjxl source and
/// classification, and every deviation names an issue that replaces it.
@Suite("Decision inventory")
struct DecisionInventoryTests {
	typealias Rule = DecisionInventory.Rule

	static let header = DecisionInventory.columns.joined(separator: "\t")
	static let exemptHeader = DecisionInventory.exemptColumns.joined(separator: "\t")
	static let existing = Set(DecisionInventory.idPrefixes.values)
		.union(DecisionInventory.agreedExemptions)

	/// A valid, settled `faithful`/`diffed` row; tests override single fields.
	static func row(_ overrides: [String: String] = [:]) -> String {
		var fields: [String: String] = [
			"id": "AN-01",
			"swift_file": "Sources/JXLEncoder/ANSCoder.swift",
			"swift_symbol": "ANSCoder.encode",
			"decision": "rANS state update",
			"path": "both",
			"upstream": DecisionInventory.pinnedUpstream,
			"upstream_function": "lib/jxl/enc_ans.h:ANSCoder::PutSymbol",
			"config": "-e 4 kCheetah",
			"classification": "faithful",
			"verification": "diffed",
			"evidence": "lib/jxl/enc_ans.h:40 Sources/JXLEncoder/ANSCoder.swift:12",
			"replacement": "-",
			"notes": "-",
		]
		fields.merge(overrides) { _, new in new }
		return DecisionInventory.columns.map { fields[$0]! }.joined(separator: "\t")
	}

	static func merged(_ base: [String: String], _ extra: [String: String]) -> [String: String]
	{
		base.merging(extra) { _, new in new }
	}

	static func check(
		_ lines: [String], exempt: [String] = [], header: String = header,
		exemptHeader: String = exemptHeader,
		fileExists: (String) -> Bool = { existing.contains($0) }
	) -> [DecisionInventory.Violation] {
		let inventory = DecisionInventory(
			inventoryTSV: ([header] + lines).joined(separator: "\n") + "\n",
			exemptTSV: ([exemptHeader] + exempt).joined(separator: "\n") + "\n")
		return inventory.parseViolations
			+ inventory.violations(fileExists: fileExists)
	}

	static func rules(_ lines: [String], exempt: [String] = []) -> Set<Rule> {
		Set(check(lines, exempt: exempt).map(\.rule))
	}

	static func rules(_ overrides: [String: String]) -> Set<Rule> {
		rules([row(overrides)])
	}

	// MARK: The checker enforces the schema

	@Test("a well-formed row has no violations")
	func acceptsWellFormedRow() {
		#expect(Self.check([Self.row()]).isEmpty)
		#expect(
			Self.check([Self.row()], exempt: ["Sources/jxlbench/main.swift\ttooling"])
				.isEmpty)
	}

	@Test("both headers must list the schema's columns in order")
	func rejectsWrongHeader() {
		let swapped = Self.header.replacingOccurrences(
			of: "id\tswift_file", with: "swift_file\tid")
		#expect(Self.check([Self.row()], header: swapped).map(\.rule).contains(.header))
		let badExempt = Self.check([Self.row()], exemptHeader: "file\treason")
		#expect(badExempt.contains { $0.rule == .header && $0.file == .exempt })
	}

	@Test(
		"every line has the schema's field count, no empty field and no CR")
	func rejectsMalformedLines() {
		let fields = Self.row().split(separator: "\t", omittingEmptySubsequences: false)
		let short = fields.dropLast().joined(separator: "\t")
		let long = (fields + ["extra"]).joined(separator: "\t")
		for line in [short, long, Self.row(["notes": ""]), Self.row() + "\r"] {
			#expect(Self.rules([line]).contains(.shape), "\(line.debugDescription)")
		}
		for exempt in [
			"Sources/jxlbench/main.swift", "Sources/jxlbench/main.swift\t", "a\tb\tc",
			"Sources/jxlbench/main.swift\ttooling\r",
		] {
			let violations = Self.check([Self.row()], exempt: [exempt])
			#expect(
				violations.contains { $0.rule == .shape && $0.file == .exempt },
				"\(exempt)")
		}
	}

	@Test("only one blank trailing line is allowed")
	func rejectsExtraTrailingBlankLines() {
		let inventory = DecisionInventory(
			inventoryTSV: Self.header + "\n" + Self.row() + "\n\n",
			exemptTSV: Self.exemptHeader + "\n")
		#expect(inventory.parseViolations.map(\.rule).contains(.shape))
	}

	@Test("ids match ^[A-Z]{2,4}-[0-9]{2,3}$")
	func rejectsMalformedIds() {
		for bad in [
			"an-01", "AN-1", "AN-1234", "A-01", "ABCDE-01", "AN-01x", "xAN-01", "AN01",
		] {
			#expect(Self.rules(["id": bad]).contains(.idFormat), "\(bad)")
		}
		#expect(Self.check([Self.row(["id": "AN-123"])]).isEmpty)
	}

	@Test("ids are unique")
	func rejectsDuplicateIds() {
		#expect(Self.rules([Self.row(), Self.row()]).contains(.duplicateId))
	}

	@Test("an id's prefix is the one assigned to its swift_file")
	func rejectsIdPrefixOfAnotherFile() {
		#expect(Self.rules(["id": "HC-01"]).contains(.idPrefix))
		#expect(Self.rules(["id": "ZZ-01"]).contains(.idPrefix))
	}

	@Test(
		"path, classification and verification take only listed values")
	func rejectsUnknownValues() {
		for field in ["path", "classification", "verification"] {
			#expect(Self.rules([field: "maybe"]).contains(.unknownValue), "\(field)")
		}
	}

	static let noUpstream = ["upstream": "-", "upstream_function": "-", "config": "-"]

	@Test(
		"upstream is the pinned full libjxl revision, or - only for original rows")
	func rejectsUnpinnedUpstream() {
		#expect(Self.rules(["upstream": "libjxl@main"]).contains(.upstreamPin))
		#expect(Self.rules(["upstream": "libjxl-tiny@unpinned"]).contains(.upstreamPin))
		#expect(Self.rules(Self.noUpstream).contains(.upstreamPin))
		let original = Self.merged(
			Self.noUpstream,
			[
				"classification": "original", "replacement": "GER-3389",
				"evidence": "Sources/JXLEncoder/ANSCoder.swift:12",
			])
		#expect(Self.check([Self.row(original)]).isEmpty)
	}

	@Test(
		"upstream_function and config are - exactly when upstream is")
	func rejectsInconsistentUpstreamFields() {
		#expect(Self.rules(["upstream_function": "-"]).contains(.upstreamConsistency))
		#expect(Self.rules(["config": "-"]).contains(.upstreamConsistency))
		let dangling = Self.merged(
			Self.noUpstream,
			[
				"upstream_function": "lib/jxl/enc_ans.cc:X",
				"classification": "original",
				"replacement": "GER-3386",
			])
		#expect(Self.rules(dangling).contains(.upstreamConsistency))
	}

	@Test("every row traces to Swift and upstream locations")
	func rejectsMissingProvenance() {
		let cases: [[String: String]] = [
			["swift_symbol": "-"],
			["decision": "-"],
			["evidence": "-"],
			["evidence": "lib/jxl/enc_ans.h:40"],
			["evidence": "Sources/JXLEncoder/ANSCoder.swift:12"],
			["evidence": "lib/jxl/enc_ans.h Sources/JXLEncoder/ANSCoder.swift"],
			["evidence": "lib/jxl/enc_ans.h Sources/JXLEncoder/ANSCoder.swift:12"],
			["upstream_function": "PutSymbol"],
			["upstream_function": "lib/jxl/enc_ans.h"],
			["upstream_function": "src/enc_ans.h:PutSymbol"],
			["evidence": "lib/jxl/enc_ans.h:40 Sources/JXLEncoder/ANSCoder.swift:x"],
			["evidence": "lib/jxl/enc_ans.h:x Sources/JXLEncoder/ANSCoder.swift:12"],
		]
		for overrides in cases {
			#expect(Self.rules(overrides).contains(.provenance), "\(overrides)")
		}
		let cjxl = [
			"upstream_function": "tools/cjxl_main.cc:ProcessFlags",
			"evidence": "tools/cjxl_main.cc:900 Sources/JXLEncoder/ANSCoder.swift:12",
		]
		#expect(Self.check([Self.row(cjxl)]).isEmpty)
		let ranges = [
			"evidence":
				"lib/jxl/enc_ans.cc:84-165 Sources/JXLEncoder/ANSCoder.swift:12-20"
		]
		#expect(Self.check([Self.row(ranges)]).isEmpty)
	}

	static let absent = [
		"swift_symbol": "(absent)", "classification": "original", "replacement": "GER-3386",
		"evidence": "lib/jxl/enc_ans.cc:120",
	]

	@Test(
		"(absent) rows are original and name the missing upstream function")
	func checksAbsentDecisions() {
		#expect(Self.check([Self.row(Self.absent)]).isEmpty)
		#expect(
			Self.rules(
				Self.merged(
					Self.absent, ["classification": "adapted", "notes": "x"])
			)
			.contains(.absentDecision))
		let unanchored = Self.merged(
			Self.absent,
			Self.merged(
				Self.noUpstream, ["evidence": "Sources/JXLEncoder/ANSCoder.swift:1"]
			))
		#expect(Self.rules(unanchored).contains(.absentDecision))
	}

	@Test("inherited-tiny rows name their libjxl-tiny source")
	func rejectsInheritedTinyWithoutTinySource() {
		let tiny = ["classification": "inherited-tiny", "replacement": "GER-3386"]
		#expect(Self.rules(tiny).contains(.tinySource))
		let bare = Self.merged(
			tiny,
			[
				"evidence":
					"tiny:x lib/jxl/enc_ans.cc:120 Sources/JXLEncoder/ANSCoder.swift:12"
			])
		#expect(Self.rules(bare).contains(.tinySource))
		let named = Self.merged(
			tiny,
			[
				"evidence":
					"tiny:enc_ans.cc:NormalizeCounts lib/jxl/enc_ans.cc:120 Sources/JXLEncoder/ANSCoder.swift:12"
			])
		#expect(Self.check([Self.row(named)]).isEmpty)
	}

	@Test(
		"adapted rows carry their equivalence argument in notes")
	func rejectsAdaptedWithoutEquivalenceArgument() {
		#expect(Self.rules(["classification": "adapted"]).contains(.equivalenceArgument))
		let argued = [
			"classification": "adapted", "notes": "division is exact for 12-bit totals",
		]
		#expect(Self.check([Self.row(argued)]).isEmpty)
	}

	struct SettledCase: CustomTestStringConvertible, Sendable {
		let classification: DecisionInventory.Classification
		let verification: DecisionInventory.Verification
		var testDescription: String {
			"\(classification.rawValue)/\(verification.rawValue)"
		}

		/// The schema's rule, written out independently of the checker.
		var settled: Bool {
			switch (classification, verification) {
			case (.faithful, .diffed), (.adapted, .diffed): return true
			default: return false
			}
		}
	}

	static let settledCases = DecisionInventory.Classification.allCases.flatMap { c in
		DecisionInventory.Verification.allCases.map {
			SettledCase(classification: c, verification: $0)
		}
	}

	@Test(
		"every deviation and every unproven claim names a replacement issue",
		arguments: settledCases)
	func requiresReplacementUnlessSettled(_ settledCase: SettledCase) {
		#expect(
			DecisionInventory.isSettled(
				classification: settledCase.classification,
				verification: settledCase.verification)
				== settledCase.settled)
		var fields = [
			"classification": settledCase.classification.rawValue,
			"verification": settledCase.verification.rawValue,
			"notes": "argument",
		]
		if settledCase.classification == .inheritedTiny {
			fields["evidence"] =
				"tiny:x.cc:F lib/jxl/enc_ans.h:40 Sources/JXLEncoder/ANSCoder.swift:12"
		}
		#expect(Self.rules(fields).contains(.replacementRequired) == !settledCase.settled)
		fields["replacement"] = "GER-3386,GER-3392"
		#expect(!Self.rules(fields).contains(.replacementRequired))
	}

	@Test(
		"unproven faithful and adapted claims name GER-3392 as their verifier")
	func requiresVerifierForUnprovenClaims() {
		for classification in ["faithful", "adapted"] {
			for verification in ["cited", "assumed"] {
				var fields = [
					"classification": classification,
					"verification": verification,
					"notes": "argument", "replacement": "GER-3386",
				]
				#expect(
					Self.rules(fields).contains(.replacementRequired),
					"\(fields)")
				fields["replacement"] = "GER-3386,GER-3392"
				#expect(Self.check([Self.row(fields)]).isEmpty, "\(fields)")
			}
		}
	}

	@Test("deviations name an area issue, not only the verifier")
	func requiresAreaIssueForDeviations() {
		for classification in ["inherited-tiny", "original"] {
			var fields = [
				"classification": classification, "replacement": "GER-3392",
				"evidence":
					"tiny:x.cc:F lib/jxl/enc_ans.h:40 Sources/JXLEncoder/ANSCoder.swift:12",
			]
			#expect(
				Self.rules(fields).contains(.replacementRequired),
				"\(classification)")
			fields["replacement"] = "GER-3386,GER-3392"
			#expect(Self.check([Self.row(fields)]).isEmpty, "\(classification)")
		}
	}

	@Test(
		"replacement is - or a comma list of agreed replacement issues")
	func rejectsUnknownReplacementIssues() {
		let deviation = ["classification": "original"]
		for bad in [
			"3386", "GER-", "GER-3386;GER-3387", "GER-3386, GER-3387", "GER-3391",
			"GER-1",
		] {
			let fields = Self.merged(deviation, ["replacement": bad])
			#expect(Self.rules(fields).contains(.replacementIssue), "\(bad)")
		}
		let list = Self.merged(deviation, ["replacement": "GER-3386,GER-3392"])
		#expect(Self.check([Self.row(list)]).isEmpty)
	}

	@Test("swift_file is an existing .swift file under Sources/")
	func rejectsBadSwiftFile() {
		for bad in [
			"Package.swift", "Reference/tools/gencodes.cc",
			"Sources/JXLEncoder/Notes.txt",
		] {
			let fields = [
				"swift_file": bad, "evidence": "lib/jxl/enc_ans.h:40 \(bad):1",
			]
			let violations = Self.check([Self.row(fields)], fileExists: { _ in true })
			#expect(violations.map(\.rule).contains(.swiftFile), "\(bad)")
		}
		let gone = [
			"swift_file": "Sources/JXLEncoder/Gone.swift",
			"evidence": "lib/jxl/enc_ans.h:40 Sources/JXLEncoder/Gone.swift:1",
		]
		#expect(Self.rules(gone).contains(.swiftFile))
		let notSwift = Self.check(
			[Self.row()], exempt: ["Package.swift\tmanifest"], fileExists: { _ in true }
		)
		#expect(notSwift.contains { $0.rule == .swiftFile && $0.file == .exempt })
		let violations = Self.check([], exempt: ["Sources/JXLEncoder/Gone.swift\tgone"])
		#expect(violations.contains { $0.rule == .swiftFile && $0.file == .exempt })
	}

	@Test("a file is listed once: inventoried or exempt")
	func rejectsFileBothCoveredAndExempt() {
		let twice = Array(repeating: "Sources/jxlbench/main.swift\ttooling", count: 2)
		#expect(Self.rules([Self.row()], exempt: twice).contains(.duplicateId))
		let exempt = ["Sources/JXLEncoder/ANSCoder.swift\tno decisions"]
		#expect(Self.rules([Self.row()], exempt: exempt).contains(.coveredAndExempt))
	}

	@Test("coverage counts rows and exemptions")
	func reportsUncoveredFiles() {
		let inventory = DecisionInventory(
			inventoryTSV: Self.header + "\n" + Self.row() + "\n",
			exemptTSV: Self.exemptHeader
				+ "\nSources/JXLEncoder/Token.swift\tno decisions\n")
		let files = [
			"Sources/JXLEncoder/ANSCoder.swift", "Sources/JXLEncoder/Token.swift",
			"Sources/JXLEncoder/XYB.swift",
		]
		#expect(inventory.uncovered(files) == ["Sources/JXLEncoder/XYB.swift"])
	}

	// MARK: The committed inventory satisfies the schema

	#if os(Linux) || os(macOS)
		/// Fails loudly where CI runs, so the checkout-gated tests below can't
		/// skip silently there.
		@Test(
			"the package checkout is reachable through #filePath")
		func checkoutIsReachable() {
			#expect(PackageCheckout.isAvailable)
			#expect(PackageCheckout.fileExists("Package.swift"))
			#expect(!PackageCheckout.fileExists("Sources/JXLEncoder/Nope.swift"))
		}
	#endif

	static func committed() throws -> DecisionInventory {
		DecisionInventory(
			inventoryTSV: try PackageCheckout.read("Reference/decision-inventory.tsv"),
			exemptTSV: try PackageCheckout.read(
				"Reference/decision-inventory-exempt.tsv"))
	}

	@Test(
		"the committed inventory satisfies every rule",
		.enabled(if: PackageCheckout.isAvailable))
	func committedInventorySatisfiesRules() throws {
		let inventory = try Self.committed()
		let violations =
			inventory.parseViolations
			+ inventory.violations(fileExists: PackageCheckout.fileExists)
		#expect(
			violations.isEmpty,
			"\(violations.map(\.description).joined(separator: "\n"))")
	}

	@Test(
		"exemptions are exactly the agreed decision-free files",
		.enabled(if: PackageCheckout.isAvailable))
	func exemptionsAreTheAgreedSet() throws {
		let exempted = try Self.committed().exemptions.map(\.swiftFile)
		#expect(exempted.count == Set(exempted).count)
		#expect(Set(exempted) == DecisionInventory.agreedExemptions)
	}

	@Test(
		"every non-exempt source file has an id prefix, listed in the schema doc",
		.enabled(if: PackageCheckout.isAvailable))
	func idPrefixesCoverEveryInventoriedFile() throws {
		let inventoried = try PackageCheckout.swiftSources().subtracting(
			DecisionInventory.agreedExemptions)
		#expect(Set(DecisionInventory.idPrefixes.values) == inventoried)
		#expect(DecisionInventory.idPrefixes.count == inventoried.count)
		let doc = try PackageCheckout.read("Reference/decision-inventory.md")
		for (prefix, file) in DecisionInventory.idPrefixes {
			let name = file.split(separator: "/").last.map(String.init) ?? file
			let listed = doc.split(separator: "\n").contains {
				$0.hasPrefix("| `\(prefix)` |") && $0.contains(name)
			}
			#expect(listed, "\(prefix) → \(name) missing from decision-inventory.md")
		}
		let prefixTable = doc.components(separatedBy: "## Id prefixes").last ?? ""
		let documented = prefixTable.split(separator: "\n").filter { $0.hasPrefix("| `") }
			.compactMap {
				$0.split(separator: "`").dropFirst().first.map(String.init)
			}
		#expect(Set(documented) == Set(DecisionInventory.idPrefixes.keys))
	}

	@Test(
		"every source file belongs to exactly one audit group",
		.enabled(if: PackageCheckout.isAvailable))
	func everySourceFileHasOneGroup() throws {
		let grouped = SourceGroup.allCases.flatMap(\.files)
		#expect(grouped.count == Set(grouped).count)
		let sources = try PackageCheckout.swiftSources()
		#expect(Set(grouped) == sources)
	}

	static func expectCovered(_ group: SourceGroup) throws {
		let uncovered = try committed().uncovered(group.files)
		#expect(uncovered.isEmpty, "no rows or exemption: \(uncovered)")
	}

	@Test(
		"every entropy-coding file has a row or an agreed exemption",
		.enabled(if: PackageCheckout.isAvailable))
	func entropyGroupIsCovered() throws { try Self.expectCovered(.entropy) }

	@Test(
		"every pixel-path file has a row or an agreed exemption",
		.enabled(if: PackageCheckout.isAvailable))
	func pixelGroupIsCovered() throws { try Self.expectCovered(.pixel) }

	@Test(
		"every JPEG-path file has a row or an agreed exemption",
		.enabled(if: PackageCheckout.isAvailable))
	func jpegGroupIsCovered() throws { try Self.expectCovered(.jpeg) }

	@Test(
		"every orchestration and platform file has a row or an agreed exemption",
		.enabled(if: PackageCheckout.isAvailable))
	func orchestrationGroupIsCovered() throws { try Self.expectCovered(.orchestration) }
}
