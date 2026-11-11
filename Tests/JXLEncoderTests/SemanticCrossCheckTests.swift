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
	static var directory: URL? {
		ProcessInfo.processInfo.environment["JXL_CROSSCHECK_DIR"].map {
			URL(fileURLWithPath: $0, isDirectory: true)
		}
	}

	@Test(
		"writes Swift's encoding of each corpus entry, plus mutated encodings",
		.enabled(if: directory != nil))
	func write() throws {
		Issue.record("unimplemented")
	}

	@Test(
		"the harness's dump of Swift's file equals the Swift-side dump",
		.enabled(if: directory != nil))
	func harnessAgreesWithEmitters() throws {
		Issue.record("unimplemented")
	}

	@Test(
		"each mutated file's harness dump differs from the unaltered file's in exactly the mutated field",
		.enabled(if: directory != nil))
	func mutationsDifferInMutatedFieldOnly() throws {
		Issue.record("unimplemented")
	}
}
