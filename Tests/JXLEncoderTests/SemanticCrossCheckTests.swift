import Foundation
import Testing

@testable import JXLEncoder

/// The local cross-check `Reference/semantic-crosscheck.sh` drives: it runs
/// `write` with `JXL_CROSSCHECK_DIR` set, dumps every written codestream with
/// the reference harness, then runs the comparing tests. Without the variable
/// they all skip, so CI (which has no libjxl) never runs them.
///
/// This is what proves the Swift-side emitters report what the bitstream
/// actually carries, and that a mutated file still decodes.
@Suite("Semantic cross-check")
struct SemanticCrossCheckTests {
	static func writeEncodings(to directory: URL) throws {
		try FileManager.default.createDirectory(
			at: directory, withIntermediateDirectories: true)
		for entry in SemanticCorpusEntry.all {
			let result = try entry.encoded()
			try Data(result.codestream).write(
				to: directory.appendingPathComponent(entry.name + ".jxl"))
			try SemanticDump(swiftDecisions: result.decisions).serialized.write(
				to: directory.appendingPathComponent(entry.name + ".swift.sem"),
				atomically: true, encoding: .utf8)
		}
		for (flip, suffix) in [(true, "ctxflip"), (false, "orderswap")] {
			let pair = try SemanticMutationTests.encodings(contextFlip: flip)
			try Data(pair.actual.codestream).write(
				to: directory.appendingPathComponent(
					"multigroup." + suffix + ".jxl"))
		}
	}

	static var directory: URL? {
		ProcessInfo.processInfo.environment["JXL_CROSSCHECK_DIR"].map {
			URL(fileURLWithPath: $0, isDirectory: true)
		}
	}

	@Test(
		"writes Swift's encoding of each corpus entry, plus mutated encodings",
		.enabled(if: directory != nil))
	func write() throws {
		let directory = try #require(Self.directory)
		try Self.writeEncodings(to: directory)
		let files = try FileManager.default.contentsOfDirectory(
			at: directory, includingPropertiesForKeys: nil)
		#expect(files.filter { $0.pathExtension == "jxl" }.count == 7)
		#expect(files.filter { $0.lastPathComponent.hasSuffix(".swift.sem") }.count == 5)
	}

	@Test(
		"the harness's dump of Swift's file equals the Swift-side dump",
		.enabled(if: directory != nil))
	func harnessAgreesWithEmitters() throws {
		let directory = try #require(Self.directory)
		#expect(SemanticCorpusEntry.all.count == 5)
		for entry in SemanticCorpusEntry.all {
			let reference = try SemanticDump(
				parsing: String(
					contentsOf: directory.appendingPathComponent(
						entry.name + ".harness.sem"), encoding: .utf8))
			let actual = try SemanticDump(
				parsing: String(
					contentsOf: directory.appendingPathComponent(
						entry.name + ".swift.sem"), encoding: .utf8))
			#expect(
				Set(actual.fields.keys.map { String($0.split(separator: ".")[0]) })
					== SemanticDump.swiftEmittedCategories)
			#expect(
				reference.differences(from: actual).isEmpty,
				"\(entry.name): \(reference.differences(from: actual))")
		}
	}

	@Test(
		"each mutated file's harness dump differs from the unaltered file's in exactly the mutated field",
		.enabled(if: directory != nil))
	func mutationsDifferInMutatedFieldOnly() throws {
		Issue.record("unimplemented")
	}
}
