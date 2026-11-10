import Foundation
import Testing

/// A generated table compiled into the encoder carries its own provenance, so a
/// reader of the source sees the generator, upstream and configuration without
/// going to the manifest — and the two can't disagree.
@Suite("Generated table headers")
struct GeneratedTableHeaderTests {
	@Test("every table row's source file header cites its generator, upstream and config")
	func headersCiteManifestRow() throws {
		Issue.record("unimplemented")
	}
}
