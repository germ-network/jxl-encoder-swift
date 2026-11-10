import Foundation
import Testing

/// The reference build is only reproducible if it names one libjxl. Moving the
/// pin is a deliberate act: it has to change this test too.
@Suite("libjxl pin record")
struct PinRecordTests {
	@Test("pins full libjxl v0.12.0 at a7a9c787")
	func pinsV0_12_0() throws {
		Issue.record("unimplemented")
	}

	@Test("records a full commit for libjxl and every submodule the build fetches")
	func recordsSubmoduleCommits() throws {
		Issue.record("unimplemented")
	}

	@Test("sha256Hex matches the FIPS 180-2 test vectors")
	func digestKnownAnswers() throws {
		Issue.record("unimplemented")
	}
}
