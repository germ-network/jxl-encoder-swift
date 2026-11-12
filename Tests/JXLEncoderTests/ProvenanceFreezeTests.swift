import Foundation
import Testing

/// Nothing new may come from libjxl-tiny: the inherited-tiny fixtures are a
/// closed, shrinking set, and every full-libjxl fixture records the input,
/// invocation and SIMD target it was generated with.
@Suite("Provenance freeze")
struct ProvenanceFreezeTests {
	/// The inherited-tiny fixture rows still allowed. Retargeting one removes it
	/// here; nothing is ever added.
	static let frozenInheritedTinyFixtures: Set<String> = [
		"Tests/JXLEncoderTests/Fixtures/edge_quant.dump",
		"Tests/JXLEncoderTests/Fixtures/edge_dcgroup.dump",
		"Tests/JXLEncoderTests/Fixtures/edge_acgroup.dump",
		"Tests/JXLEncoderTests/Fixtures/edge_dcextract.dump",
		"Tests/JXLEncoderTests/Fixtures/edge_whole.jxl",
		"Tests/JXLEncoderTests/Fixtures/multigroup_whole.jxl",
		"Tests/JXLEncoderTests/Fixtures/prefix_codes.txt",
		"Tests/JXLEncoderTests/Fixtures/context_tree.txt",
		"Tests/JXLEncoderTests/Fixtures/ac_context.bin",
	]

	@Test("inherited-tiny fixture rows are a subset of the frozen set")
	func noNewInheritedTinyFixtures() throws {
		let manifest = try ProvenanceManifest(
			contentsOf: RepositoryLayout.provenanceManifest)
		let inherited = Set(
			manifest.rows.filter { $0.kind == .fixture && $0.origin == .inheritedTiny }
				.map(\.path))
		#expect(
			inherited.isSubset(of: Self.frozenInheritedTinyFixtures),
			"New inherited-tiny fixtures: \(inherited.subtracting(Self.frozenInheritedTinyFixtures))"
		)
	}

	@Test("full-libjxl fixture rows record their input, invocation and SIMD target")
	func fullLibjxlRowsAreReproducible() throws {
		let manifest = try ProvenanceManifest(
			contentsOf: RepositoryLayout.provenanceManifest)
		for row in manifest.rows where row.kind == .fixture && row.origin == .fullLibjxl {
			#expect(
				row.invocation != "unrecorded" && row.invocation != "-",
				"\(row.path): invocation")
			#expect(row.input != "unrecorded" && row.input != "-", "\(row.path): input")
			#expect(row.config.contains("hwy="), "\(row.path): SIMD target")
		}
	}
}
