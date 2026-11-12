import Testing

@testable import JXLEncoder

struct JPEGSemanticCorpusEntry: Sendable, CustomTestStringConvertible {
	let name: String
	let jpegFixture: String
	let knownIssues: [String: Set<String>]

	var testDescription: String { fatalError("Pending JPEG corpus") }
	static var all: [Self] { fatalError("Pending JPEG corpus") }
	static var rejectedJPEGFixtures: [String] { fatalError("Pending JPEG rejection corpus") }

	func encoded() throws -> SwiftJPEGSemanticEncoding.Result {
		fatalError("Pending JPEG corpus encoding")
	}
}

struct JPEGSemanticCase: Sendable, CustomTestStringConvertible {
	let entry: JPEGSemanticCorpusEntry
	let category: String

	var knownIssues: Set<String> { fatalError("Pending JPEG known issues") }
	var testDescription: String { fatalError("Pending JPEG case description") }
	static var all: [Self] { fatalError("Pending JPEG cases") }
	static var references: Set<String> { fatalError("Pending JPEG references") }
	static var knownIssueReferences: Set<String> {
		fatalError("Pending JPEG known-issue references")
	}
}

@Suite("JPEG semantic fixtures")
struct JPEGSemanticFixtureTests {
	@Test(
		"the recomposed JPEG encode is byte-identical to Encoder.encodeJPEG",
		.disabled("Pending implementation"))
	func jpegRecompositionMatchesEncoder() throws {}

	@Test(
		"actual Swift JPEG decisions match the pinned reference categories",
		.disabled("Pending implementation"))
	func jpegMatchesReference() throws {}

	@Test(
		"the JPEG corpus covers sampling, odd bounds and partial multigroup edges",
		.disabled("Pending implementation"))
	func jpegCorpusCoversSamplingAndEdges() throws {}

	@Test(
		"known JPEG issues name applicable categories and cannot verify inventory rows",
		.disabled("Pending implementation"))
	func jpegKnownIssuesWellFormed() throws {}

	@Test(
		"parsed JPEG component grids cover every encoded block",
		.disabled("Pending implementation"))
	func jpegComponentGridsCoverEncodedBlocks() throws {}

	@Test(
		"JPEG tokens use full-resolution luma DC buckets at sampled chroma positions",
		.disabled("Pending implementation"))
	func jpegContextsUseFullResolutionLumaDCBuckets() throws {}

	@Test(
		"DC buckets advance only when the DC value is strictly greater than a threshold",
		.disabled("Pending implementation"))
	func jpegDCBucketBoundaryUsesStrictGreaterThan() throws {}
}
