import Foundation
import Testing

/// Nothing new may come from libjxl-tiny: the inherited-tiny fixtures are a
/// closed, shrinking set, and every full-libjxl fixture records the input,
/// invocation and SIMD target it was generated with.
@Suite("Provenance freeze")
struct ProvenanceFreezeTests {
	/// The inherited-tiny fixture rows still allowed. Retargeting one removes it
	/// here; nothing is ever added.
	static let frozenInheritedTinyFixtures: Set<String> = []

	@Test("inherited-tiny fixture rows are a subset of the frozen set")
	func noNewInheritedTinyFixtures() throws {
		Issue.record("unimplemented")
	}

	@Test("full-libjxl fixture rows record their input, invocation and SIMD target")
	func fullLibjxlRowsAreReproducible() throws {
		Issue.record("unimplemented")
	}
}
