import Foundation
import Testing

/// Every committed reference artifact says where it came from, and its bytes
/// can't change without the manifest changing with it.
@Suite("Fixture provenance")
struct FixtureProvenanceTests {
	@Test("every file in both Fixtures directories has exactly one fixture row")
	func everyFixtureHasOneRow() throws {
		Issue.record("unimplemented")
	}

	@Test("every fixture row names a file that exists")
	func noOrphanRows() throws {
		Issue.record("unimplemented")
	}

	@Test("every fixture's bytes match its recorded sha256")
	func bytesMatchRecordedDigest() throws {
		Issue.record("unimplemented")
	}

	@Test("full-libjxl rows cite the pinned commit; inherited-tiny rows say unpinned")
	func upstreamMatchesOrigin() throws {
		Issue.record("unimplemented")
	}

	@Test("a malformed manifest row is rejected, not skipped")
	func malformedRowThrows() throws {
		Issue.record("unimplemented")
	}

	@Test("only fixture rows carry a sha256, and every fixture row does")
	func digestPresenceFollowsKind() throws {
		Issue.record("unimplemented")
	}

	@Test("every inline row names a test file that exists")
	func inlineRowsNameExistingTests() throws {
		Issue.record("unimplemented")
	}
}
