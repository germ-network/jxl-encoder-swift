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
		"GER-3386", "GER-3387", "GER-3388", "GER-3389", "GER-3392",
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
		fatalError("not implemented")
	}

	/// Whether a row needs no replacement issue: `faithful` or `adapted`, with
	/// `diffed` verification.
	static func isSettled(classification: Classification, verification: Verification) -> Bool {
		fatalError("not implemented")
	}

	/// Every rule violation except coverage, which `uncovered(_:)` reports
	/// per source group. `fileExists` takes a path from the package root.
	func violations(fileExists: (String) -> Bool) -> [Violation] {
		fatalError("not implemented")
	}

	/// The files among `sourceFiles` that have neither a row nor an exemption.
	func uncovered(_ sourceFiles: [String]) -> [String] {
		fatalError("not implemented")
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
		false
	}

	static func read(_ relativePath: String) throws -> String {
		fatalError("not implemented")
	}

	static func fileExists(_ relativePath: String) -> Bool {
		fatalError("not implemented")
	}

	/// Every `.swift` file under `Sources/`, as paths from the package root
	/// (`FileManager.enumerator(atPath:)` yields relative paths on Darwin and Linux).
	static func swiftSources() throws -> Set<String> {
		fatalError("not implemented")
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
