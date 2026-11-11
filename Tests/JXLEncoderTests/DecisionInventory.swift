import Foundation

/// Reader and rule checker for `Reference/decision-inventory.tsv` and
/// `Reference/decision-inventory-exempt.tsv`; `Reference/decision-inventory.md`
/// is the schema these rules implement.
///
/// Parsing never throws: every problem, including a malformed line, is
/// reported as a `Violation` so a test can list them all at once.
struct DecisionInventory {
	static let columns = [
		"id", "swift_file", "swift_symbol", "decision", "path", "upstream",
		"upstream_function",
		"config", "classification", "verification", "evidence", "replacement", "notes",
	]
	static let exemptColumns = ["swift_file", "reason"]
	static let pinnedUpstream = "libjxl@a7a9c787341cf703dede03c2009fa460cae5e5df"

	enum Classification: String, CaseIterable {
		case faithful
		case adapted
		case inheritedTiny = "inherited-tiny"
		case original
	}

	enum Verification: String, CaseIterable {
		case diffed
		case cited
		case assumed
	}

	enum EncodePath: String, CaseIterable {
		case pixel
		case jpeg
		case both
		case staticCodes = "static"
		case platform
	}

	/// One data line of the inventory, fields kept as written so that unknown
	/// values surface as violations rather than parse failures.
	struct Row {
		let line: Int
		let id: String
		let swiftFile: String
		let swiftSymbol: String
		let decision: String
		let path: String
		let upstream: String
		let upstreamFunction: String
		let config: String
		let classification: String
		let verification: String
		let evidence: String
		let replacement: String
		let notes: String
	}

	struct Exemption {
		let line: Int
		let swiftFile: String
		let reason: String
	}

	enum Rule: CaseIterable {
		/// Header line differs from the schema's column list.
		case header
		/// A line has the wrong number of fields, an empty field, or a carriage return.
		case shape
		/// Id doesn't match `^[A-Z]{2,4}-[0-9]{2,3}$`.
		case idFormat
		/// Id prefix is not the one `idPrefixes` assigns to the row's `swift_file`.
		case idPrefix
		/// Id repeated, or an exempt file listed twice.
		case duplicateId
		/// `path`, `classification` or `verification` outside its listed values.
		case unknownValue
		/// `upstream` is neither the pinned revision nor `-`, or is `-` on a
		/// non-`original` row.
		case upstreamPin
		/// `upstream_function` / `config` are not `-` exactly when `upstream` is.
		case upstreamConsistency
		/// `swift_symbol`, `decision` or `evidence` is `-`; `evidence` lacks a
		/// `<swift_file>:<line>` (unless `(absent)`) or, with a pinned upstream, a
		/// `lib/…:<line>` or `tools/…:<line>` (a line may be a range `12-20`); or
		/// `upstream_function` isn't `(lib|tools)/<path>:<Function>`, split at the
		/// first colon so `<Function>` may be qualified (`ANSCoder::PutSymbol`).
		case provenance
		/// `(absent)` row that isn't `original` with a pinned upstream.
		case absentDecision
		/// `inherited-tiny` row without a `tiny:` source in `evidence`.
		case tinySource
		/// `adapted` row whose `notes` doesn't carry the equivalence argument.
		case equivalenceArgument
		/// Row that still needs work has no replacement issue, or an unproven
		/// `faithful`/`adapted` claim doesn't name GER-3392 as its verifier, or
		/// an `inherited-tiny`/`original` row names only GER-3392.
		case replacementRequired
		/// `replacement` is neither `-` nor a comma list of ids in `replacementIssues`.
		case replacementIssue
		/// `swift_file` (row or exemption) isn't `Sources/…/*.swift` or doesn't exist.
		case swiftFile
		/// File both has rows and is listed as exempt.
		case coveredAndExempt
		/// `fixture` is neither `-` nor a comma list of well-formed references
		/// that each `.verifies`: a `full-libjxl` fixture (and, for a `.sem`,
		/// category) that a test compares, not under a known issue.
		case fixtureReference
	}

	enum InventoryFile: String {
		case inventory = "decision-inventory.tsv"
		case exempt = "decision-inventory-exempt.tsv"
	}

	struct Violation: CustomStringConvertible {
		let rule: Rule
		let file: InventoryFile
		/// 1-based line in `file`, if the violation is about one line.
		let line: Int?
		let message: String

		var description: String {
			"\(rule) \(file.rawValue):\(line.map(String.init) ?? "-"): \(message)"
		}
	}

	/// Issues a deviation may name as its replacement or verifier. An issue the
	/// planner files for this audit is added here in the same change.
	static let replacementIssues: Set<String> = [
		"GER-3386", "GER-3387", "GER-3388", "GER-3389", "GER-3392", "GER-3418",
		"GER-3419",
	]

	/// Id prefix for each inventoried source file; mirrors the table in
	/// `Reference/decision-inventory.md`.
	static let idPrefixes: [String: String] = [
		"AC": "Sources/JXLEncoder/ACContext.swift",
		"AG": "Sources/JXLEncoder/ACGroupEncoder.swift",
		"AH": "Sources/JXLEncoder/ANSHistogramWriter.swift",
		"AN": "Sources/JXLEncoder/ANSCoder.swift",
		"AQ": "Sources/JXLEncoder/AdaptiveQuantPipeline.swift",
		"AT": "Sources/JXLEncoder/ACTokenizer.swift",
		"AW": "Sources/JXLEncoder/ANSTokenWriter.swift",
		"BC": "Sources/JXLEncoder/JPEGBlockContextMap.swift",
		"BW": "Sources/JXLEncoder/BitWriter.swift",
		"CO": "Sources/JXLEncoder/CoeffOrder.swift",
		"CS": "Sources/JXLEncoder/ChromaSubsampling.swift",
		"CT": "Sources/JXLEncoder/ContextTree.swift",
		"DCT": "Sources/JXLEncoder/DCT.swift",
		"DG": "Sources/JXLEncoder/DCGroupEncoder.swift",
		"DP": "Sources/JXLEncoder/DistanceParams.swift",
		"DPR": "Sources/JXLEncoder/DCPredictor.swift",
		"EC": "Sources/JXLEncoder/EntropyCode.swift",
		"ENC": "Sources/JXLEncoder/Encoder.swift",
		"EW": "Sources/JXLEncoder/EntropyCodeWriter.swift",
		"FA": "Sources/JXLEncoder/FrameAssembly.swift",
		"FC": "Sources/JXLEncoder/Float16Coder.swift",
		"FM": "Sources/JXLEncoder/FastMath.swift",
		"GE": "Sources/JXLEncoder/Geometry.swift",
		"HC": "Sources/JXLEncoder/HistogramCluster.swift",
		"HT": "Sources/JXLEncoder/HuffmanTree.swift",
		"IH": "Sources/JXLEncoder/ImageHeader.swift",
		"JH": "Sources/JXLEncoder/JPEGHuffman.swift",
		"JO": "Sources/JXLEncoder/JPEGOrientation.swift",
		"JP": "Sources/JXLEncoder/JPEGParser.swift",
		"JR": "Sources/JXLEncoder/JPEGRecompression.swift",
		"JT": "Sources/JXLEncoder/JPEGTranscode.swift",
		"PB": "Sources/JXLEncoder/PlaneBuffer.swift",
		"PC": "Sources/JXLEncoder/PrefixCodeWriter.swift",
		"QM": "Sources/JXLEncoder/QuantMatrices.swift",
		"QR": "Sources/JXLEncoder/QuantizeRoundtrip.swift",
		"QW": "Sources/JXLEncoder/QuantMatrixWriter.swift",
		"QZ": "Sources/JXLEncoder/Quantizer.swift",
		"RE": "Sources/JXLEncoder/ReciprocalEstimate.swift",
		"SE": "Sources/JXLEncoder/StaticEntropyCodes.swift",
		"SR": "Sources/JXLEncoder/SRGBTransfer.swift",
		"SW": "Sources/JXLEncoder/SectionWriter.swift",
		"TK": "Sources/JXLEncoder/Token.swift",
		"XYB": "Sources/JXLEncoder/XYB.swift",
		"APL": "Sources/JXLEncoderApple/JXLEncoderApple.swift",
	]

	/// Files agreed to hold no production decision (P-4). Changing this set
	/// is a reviewed decision, not a way to pass coverage.
	static let agreedExemptions: Set<String> = [
		"Sources/JXLEncoder/EncoderError.swift",
		"Sources/JXLEncoder/EntropyDiagnostics.swift",
		"Sources/jxlbench/main.swift",
		"Sources/jxlencode/main.swift",
	]

	let rows: [Row]
	let exemptions: [Exemption]
	/// Violations found while splitting lines and fields (`header`, `shape`).
	let parseViolations: [Violation]

	init(inventoryTSV: String, exemptTSV: String) {
		var violations: [Violation] = []
		let inventoryLines = Self.fieldLines(
			inventoryTSV, columns: Self.columns, file: .inventory, into: &violations)
		let exemptLines = Self.fieldLines(
			exemptTSV, columns: Self.exemptColumns, file: .exempt, into: &violations)
		rows = inventoryLines.map { line, f in
			Row(
				line: line, id: f[0], swiftFile: f[1], swiftSymbol: f[2],
				decision: f[3],
				path: f[4], upstream: f[5], upstreamFunction: f[6], config: f[7],
				classification: f[8], verification: f[9], evidence: f[10],
				replacement: f[11], notes: f[12])
		}
		exemptions = exemptLines.map { line, f in
			Exemption(line: line, swiftFile: f[0], reason: f[1])
		}
		parseViolations = violations
	}

	/// Data lines of `text` as (1-based line, fields). A mismatched header
	/// stops the file; a malformed line is reported and skipped. `\r\n` is a
	/// single `Character` in Swift, so line splitting and the carriage-return
	/// test work on `String` separators and unicode scalars.
	private static func fieldLines(
		_ text: String, columns: [String], file: InventoryFile,
		into violations: inout [Violation]
	) -> [(Int, [String])] {
		var lines = text.components(separatedBy: "\n")
		if lines.last == "" { lines.removeLast() }
		guard let header = lines.first,
			header.components(separatedBy: "\t") == columns
		else {
			violations.append(
				Violation(
					rule: .header, file: file, line: 1,
					message: "header must be \(columns.joined(separator: "\t"))"
				))
			return []
		}
		var result: [(Int, [String])] = []
		for (index, line) in lines.enumerated().dropFirst() {
			let number = index + 1
			let fields = line.components(separatedBy: "\t")
			let problem: String?
			if line.unicodeScalars.contains("\r") {
				problem = "carriage return"
			} else if fields.count != columns.count {
				problem = "\(fields.count) fields, expected \(columns.count)"
			} else if fields.contains("") {
				problem = "empty field"
			} else {
				problem = nil
			}
			if let problem {
				violations.append(
					Violation(
						rule: .shape, file: file, line: number,
						message: problem))
			} else {
				result.append((number, fields))
			}
		}
		return result
	}

	/// Whether a row needs no replacement issue: `faithful` or `adapted`, with
	/// `diffed` verification.
	static func isSettled(classification: Classification, verification: Verification) -> Bool {
		switch (classification, verification) {
		case (.faithful, .diffed), (.adapted, .diffed): return true
		default: return false
		}
	}

	/// One entry of the `fixture` column: a fixture path as written in
	/// `Reference/provenance.tsv`, and for a semantic dump (`.sem`) the
	/// category that compares the row's decision, as `<path>#<category>`.
	struct FixtureReference: Hashable {
		let path: String
		let category: String?

		/// Nil unless `text` is `<path>` or `<path>#<category>` with both parts
		/// non-empty; a `.sem` path requires the category, anything else forbids it.
		init?(_ text: String) {
			return nil
		}
	}

	/// What a fixture reference can establish.
	enum FixtureStatus: Equatable {
		/// A `full-libjxl` fixture whose comparison runs without a known issue.
		case verifies
		/// A `full-libjxl` fixture compared under `withKnownIssue`.
		case knownIssue
		/// A `full-libjxl` fixture (or `.sem` category) that no test compares,
		/// e.g. a category the Swift side doesn't emit.
		case notCompared
		/// The path's provenance row has another origin.
		case notFullLibjxl
		/// No fixture row for the path.
		case missing
	}

	/// Whether a row needs no GER-3392 verifier: `faithful` or `adapted`, and
	/// either `diffed` or citing at least one fixture that `.verifies`.
	static func isSettled(
		classification: Classification, verification: Verification, hasFixture: Bool
	) -> Bool {
		isSettled(classification: classification, verification: verification)
	}

	/// Every rule violation except coverage, with each `fixture` reference
	/// checked through `fixtureStatus`; only `.verifies` is accepted.
	func violations(
		fileExists: (String) -> Bool, fixtureStatus: (FixtureReference) -> FixtureStatus
	) -> [Violation] {
		violations(fileExists: fileExists)
	}

	/// Every rule violation except coverage, which `uncovered(_:)` reports
	/// per source group. `fileExists` takes a path from the package root.
	func violations(fileExists: (String) -> Bool) -> [Violation] {
		var found: [Violation] = []
		func add(_ rule: Rule, _ row: Row, _ message: String) {
			found.append(
				Violation(
					rule: rule, file: .inventory, line: row.line,
					message: message))
		}

		var seenIds = Set<String>()
		for row in rows {
			if !Self.isValidId(row.id) {
				add(.idFormat, row, "id \(row.id)")
			} else if let prefix = row.id.components(separatedBy: "-").first,
				Self.idPrefixes[prefix] != row.swiftFile
			{
				add(
					.idPrefix, row,
					"prefix \(prefix) is not assigned to \(row.swiftFile)")
			}
			if !seenIds.insert(row.id).inserted {
				add(.duplicateId, row, "id \(row.id) repeated")
			}

			let classification = Classification(rawValue: row.classification)
			let verification = Verification(rawValue: row.verification)
			if EncodePath(rawValue: row.path) == nil {
				add(.unknownValue, row, "path \(row.path)")
			}
			if classification == nil {
				add(.unknownValue, row, "classification \(row.classification)")
			}
			if verification == nil {
				add(.unknownValue, row, "verification \(row.verification)")
			}

			let pinned = row.upstream == Self.pinnedUpstream
			if !pinned && row.upstream != "-" {
				add(.upstreamPin, row, "upstream \(row.upstream)")
			}
			if row.upstream == "-"
				&& row.classification != Classification.original.rawValue
			{
				add(.upstreamPin, row, "only original rows may have no upstream")
			}
			let noUpstream = row.upstream == "-"
			if (row.upstreamFunction == "-") != noUpstream
				|| (row.config == "-") != noUpstream
			{
				add(
					.upstreamConsistency, row,
					"upstream_function and config must be - exactly when upstream is"
				)
			}

			checkProvenance(row, pinned: pinned, add: add)

			if row.swiftSymbol == Self.absentSymbol
				&& (row.classification != Classification.original.rawValue
					|| !pinned)
			{
				add(
					.absentDecision, row,
					"(absent) rows are original with a pinned upstream")
			}
			if classification == .inheritedTiny
				&& !Self.evidenceTokens(row).contains(where: {
					let parts = $0.components(separatedBy: ":")
					return parts.count >= 3 && parts[0] == "tiny"
						&& !parts[1].isEmpty
						&& !parts[2].isEmpty
				})
			{
				add(
					.tinySource, row,
					"inherited-tiny needs a tiny:<file>:<function> source")
			}
			if classification == .adapted && row.notes == "-" {
				add(
					.equivalenceArgument, row,
					"adapted rows argue equivalence in notes")
			}

			let issues = row.replacement.components(separatedBy: ",")
			let named = row.replacement == "-" ? [] : issues
			if !named.isEmpty && !named.allSatisfy(Self.replacementIssues.contains) {
				add(.replacementIssue, row, "replacement \(row.replacement)")
			}
			if let classification, let verification,
				let message = Self.replacementShortfall(
					classification, verification, named: Set(named))
			{
				add(.replacementRequired, row, message)
			}

			checkSwiftFile(row.swiftFile, fileExists: fileExists) { message in
				add(.swiftFile, row, message)
			}
		}

		var seenExempt = Set<String>()
		let covered = Set(rows.map(\.swiftFile))
		for exemption in exemptions {
			func addExempt(_ rule: Rule, _ message: String) {
				found.append(
					Violation(
						rule: rule, file: .exempt, line: exemption.line,
						message: message))
			}
			if !seenExempt.insert(exemption.swiftFile).inserted {
				addExempt(.duplicateId, "\(exemption.swiftFile) exempted twice")
			}
			if covered.contains(exemption.swiftFile) {
				addExempt(.coveredAndExempt, "\(exemption.swiftFile) also has rows")
			}
			checkSwiftFile(exemption.swiftFile, fileExists: fileExists) {
				addExempt(.swiftFile, $0)
			}
		}
		return found
	}

	static let absentSymbol = "(absent)"

	private static func isValidId(_ id: String) -> Bool {
		let parts = id.components(separatedBy: "-")
		guard parts.count == 2 else { return false }
		let letters = parts[0].unicodeScalars
		let digits = parts[1].unicodeScalars
		return (2...4).contains(letters.count)
			&& letters.allSatisfy { ("A"..."Z").contains($0) }
			&& (2...3).contains(digits.count)
			&& digits.allSatisfy { ("0"..."9").contains($0) }
	}

	private static func evidenceTokens(_ row: Row) -> [String] {
		row.evidence.components(separatedBy: " ").filter { !$0.isEmpty }
	}

	/// Whether `spec` is `<line>` or `<first>-<last>`.
	private static func isLineSpec(_ spec: some StringProtocol) -> Bool {
		let numbers = spec.components(separatedBy: "-")
		return (1...2).contains(numbers.count)
			&& numbers.allSatisfy {
				!$0.isEmpty
					&& $0.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
			}
	}

	/// Whether `token` is `<prefix><line spec>`.
	private static func hasLine(_ token: String, prefix: String) -> Bool {
		token.hasPrefix(prefix) && isLineSpec(token.dropFirst(prefix.count))
	}

	/// Whether `token` is `lib/<path>:<line spec>` or `tools/<path>:<line spec>`.
	private static func isUpstreamLocation(_ token: String) -> Bool {
		guard token.hasPrefix("lib/") || token.hasPrefix("tools/"),
			let colon = token.lastIndex(of: ":")
		else { return false }
		return isLineSpec(token[token.index(after: colon)...])
	}

	private func checkProvenance(
		_ row: Row, pinned: Bool, add: (Rule, Row, String) -> Void
	) {
		for (name, value) in [
			("swift_symbol", row.swiftSymbol), ("decision", row.decision),
			("evidence", row.evidence),
		] where value == "-" {
			add(.provenance, row, "\(name) is -")
		}
		let tokens = Self.evidenceTokens(row)
		if row.swiftSymbol != Self.absentSymbol
			&& !tokens.contains(where: { Self.hasLine($0, prefix: row.swiftFile + ":") }
			)
		{
			add(.provenance, row, "evidence lacks \(row.swiftFile):<line>")
		}
		if pinned
			&& !tokens.contains(where: Self.isUpstreamLocation)
		{
			add(.provenance, row, "evidence lacks a lib/…:<line> or tools/…:<line>")
		}
		if row.upstreamFunction != "-" {
			let parts = row.upstreamFunction.split(
				separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
			let wellFormed =
				parts.count == 2 && !parts[1].isEmpty
				&& (parts[0].hasPrefix("lib/") || parts[0].hasPrefix("tools/"))
				&& !parts[0].hasSuffix("/")
			if !wellFormed {
				add(
					.provenance, row,
					"upstream_function must be (lib|tools)/<path>:<Function>")
			}
		}
	}

	private func checkSwiftFile(
		_ file: String, fileExists: (String) -> Bool, report: (String) -> Void
	) {
		if !file.hasPrefix("Sources/") || !file.hasSuffix(".swift") {
			report("\(file) is not a .swift file under Sources/")
		} else if !fileExists(file) {
			report("\(file) does not exist")
		}
	}

	private static func replacementShortfall(
		_ classification: Classification, _ verification: Verification, named: Set<String>
	) -> String? {
		let verifier = "GER-3392"
		if isSettled(classification: classification, verification: verification) {
			return nil
		}
		switch classification {
		case .faithful, .adapted:
			return named.contains(verifier)
				? nil
				: "unproven \(classification.rawValue) claim must name \(verifier)"
		case .inheritedTiny, .original:
			return named.subtracting([verifier]).isEmpty
				? "\(classification.rawValue) rows must name an area issue" : nil
		}
	}

	/// The files among `sourceFiles` that have neither a row nor an exemption.
	func uncovered(_ sourceFiles: [String]) -> [String] {
		let covered = Set(rows.map(\.swiftFile)).union(exemptions.map(\.swiftFile))
		return sourceFiles.filter { !covered.contains($0) }
	}
}

/// The package checkout, reached through `#filePath`; absent where the test
/// bundle runs away from the source tree (e.g. on a device).
enum PackageCheckout {
	static let root: URL = URL(fileURLWithPath: #filePath)
		.deletingLastPathComponent()
		.deletingLastPathComponent()
		.deletingLastPathComponent()

	static var isAvailable: Bool {
		fileExists("Package.swift")
	}

	static func read(_ relativePath: String) throws -> String {
		try String(
			contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
	}

	static func fileExists(_ relativePath: String) -> Bool {
		FileManager.default.fileExists(
			atPath: root.appendingPathComponent(relativePath).path)
	}

	/// Every `.swift` file under `Sources/`, as paths from the package root
	/// (`FileManager.enumerator(atPath:)` yields relative paths on Darwin and Linux).
	static func swiftSources() throws -> Set<String> {
		let sources = root.appendingPathComponent("Sources").path
		guard let walker = FileManager.default.enumerator(atPath: sources) else {
			throw CocoaError(.fileReadNoSuchFile)
		}
		var found = Set<String>()
		for case let path as String in walker where path.hasSuffix(".swift") {
			found.insert("Sources/" + path)
		}
		return found
	}
}

/// Source files partitioned by audit area, so coverage can be checked one
/// area at a time. Every file under `Sources/` belongs to exactly one group.
enum SourceGroup: String, CaseIterable {
	case entropy
	case pixel
	case jpeg
	case orchestration

	var files: [String] {
		switch self {
		case .entropy:
			return [
				"ANSCoder", "ANSHistogramWriter", "ANSTokenWriter", "BitWriter",
				"CoeffOrder",
				"EntropyCode", "EntropyCodeWriter", "EntropyDiagnostics",
				"HistogramCluster",
				"HuffmanTree", "PrefixCodeWriter", "SectionWriter",
				"StaticEntropyCodes", "Token",
			].map { "Sources/JXLEncoder/\($0).swift" }
		case .pixel:
			return [
				"ACContext", "ACGroupEncoder", "ACTokenizer",
				"AdaptiveQuantPipeline",
				"ChromaSubsampling", "ContextTree", "DCGroupEncoder", "DCPredictor",
				"DCT",
				"DistanceParams", "FastMath", "Float16Coder", "Geometry",
				"ImageHeader", "PlaneBuffer",
				"QuantMatrices", "QuantMatrixWriter", "QuantizeRoundtrip",
				"Quantizer",
				"ReciprocalEstimate", "SRGBTransfer", "XYB",
			].map { "Sources/JXLEncoder/\($0).swift" }
		case .jpeg:
			return [
				"JPEGBlockContextMap", "JPEGHuffman", "JPEGOrientation",
				"JPEGParser",
				"JPEGRecompression", "JPEGTranscode",
			].map { "Sources/JXLEncoder/\($0).swift" }
		case .orchestration:
			return [
				"Sources/JXLEncoder/Encoder.swift",
				"Sources/JXLEncoder/EncoderError.swift",
				"Sources/JXLEncoder/FrameAssembly.swift",
				"Sources/JXLEncoderApple/JXLEncoderApple.swift",
				"Sources/jxlbench/main.swift",
				"Sources/jxlencode/main.swift",
			]
		}
	}
}
