import Foundation
import Testing

@testable import JXLEncoder

/// One recorded reference encode: an input committed under
/// `Fixtures/semantic/`, the distance, and the harness's dump of the pinned
/// libjxl's `-e 4` encoding of it (`<name>.sem`). `Reference/provenance.tsv`
/// records how each was made.
struct SemanticCorpusEntry: CustomTestStringConvertible, Sendable {
	enum Input: Sendable {
		/// 8-bit sRGB binary PPM (`P6`), `Fixtures/semantic/<file>.ppm`.
		case srgb8(file: String)
		/// Linear float `StageDump`, `Fixtures/<file>.dump`.
		case linear(file: String)
	}

	let name: String
	let input: Input
	let distance: Float
	/// Category to the issues that must all land before Swift matches upstream
	/// there, for each category where Swift is known to decide differently on
	/// this entry. That category's comparison runs under `withKnownIssue`, so it
	/// stays green and fails the moment Swift starts matching (the cue to drop
	/// the entry here). Other categories of the same entry are compared normally.
	let knownIssues: [String: Set<String>]

	var testDescription: String { name }

	/// The committed corpus. Each entry has a `.sem` fixture and provenance row.
	static let all: [SemanticCorpusEntry] = []
}

/// One corpus entry compared in one category: the unit of expected divergence.
struct SemanticCase: CustomTestStringConvertible, Sendable {
	let entry: SemanticCorpusEntry
	let category: String

	/// Empty when this pair is expected to match.
	var knownIssues: Set<String> { entry.knownIssues[category] ?? [] }
	var testDescription: String { "\(entry.name)#\(category)" }

	/// Every corpus entry crossed with every Swift-emitted category.
	static var all: [SemanticCase] {
		SemanticCorpusEntry.all.flatMap { entry in
			SemanticDump.swiftEmittedCategories.sorted().map {
				SemanticCase(entry: entry, category: $0)
			}
		}
	}

	/// `<fixture path>#<category>` for every case, the form an inventory
	/// `fixture` reference takes. A reference outside this set is compared by
	/// no test.
	static var references: Set<String> {
		[]
	}

	/// The subset of `references` whose case runs under a known issue; such a
	/// fixture verifies nothing.
	static var knownIssueReferences: Set<String> {
		[]
	}
}

/// Stage fixtures (`Fixtures/*.dump`) whose consuming test runs under
/// `withKnownIssue`, by fixture path, with the issue. Kept next to the
/// wrappers it describes; an inventory row can't cite these as verification.
enum StageFixtureKnownIssues {
	static let byFixture: [String: String] = [:]
}

/// Reads an 8-bit binary PPM; Foundation-only so it runs on Linux CI.
func loadPPM(fixture name: String) throws -> ImageBuffer {
	throw SemanticDumpError.unimplemented
}

/// The Swift encoder's decisions, dumped from its own internals, agree with the
/// pinned libjxl's for every corpus entry in each category the Swift side
/// emits, except where a named issue records that Swift still differs.
@Suite("Semantic fixtures")
struct SemanticFixtureTests {
	@Test("the recomposed encode is byte-identical to Encoder.encode")
	func recompositionMatchesEncoder() throws {
		Issue.record("unimplemented")
	}

	@Test("the recomposed linear encode is byte-identical to Encoder.encodeFrame")
	func linearRecompositionMatchesEncodeFrame() throws {
		Issue.record("unimplemented")
	}

	@Test("the corpus has a large multi-group entry above 8 groups")
	func corpusCoversStreamingSize() throws {
		Issue.record("unimplemented")
	}

	@Test("every known issue names an emitted category and an accepted issue")
	func knownIssuesWellFormed() throws {
		Issue.record("unimplemented")
	}

	@Test(
		"Swift's decisions match the pinned libjxl's",
		arguments: SemanticCase.all)
	func matchesReference(_ semanticCase: SemanticCase) throws {
		Issue.record("unimplemented")
	}
}

/// A changed decision is caught by the comparison, even though the file it
/// produces still decodes.
@Suite("Semantic mutations")
struct SemanticMutationTests {
	@Test("a flipped entry of a token-free AC context is reported in context_map only")
	func flippedContextMapEntryCaught() throws {
		Issue.record("unimplemented")
	}

	@Test(
		"two swapped always-zero coefficient-order positions are reported in coeff_order only"
	)
	func swappedCoeffOrderCaught() throws {
		Issue.record("unimplemented")
	}
}
