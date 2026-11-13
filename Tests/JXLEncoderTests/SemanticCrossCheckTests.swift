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
	static func verifyMutations(in directory: URL) throws {
		let baseline = try SemanticDump(
			parsing: String(
				contentsOf: directory.appendingPathComponent(
					"multigroup.harness.sem"), encoding: .utf8))
		for (flip, suffix) in [(true, "ctxflip"), (false, "orderswap")] {
			let pair = try SemanticMutationTests.encodings(contextFlip: flip)
			let mutated = try SemanticDump(
				parsing: String(
					contentsOf: directory.appendingPathComponent(
						"multigroup." + suffix + ".harness.sem"),
					encoding: .utf8))
			let differences = mutated.differences(from: baseline)
			#expect(
				differences == [
					SemanticDifference(field: pair.field, kind: pair.expected)
				], "\(suffix): \(differences)")
			print("decoded \(suffix): \(differences)")
		}
	}
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
		for entry in JPEGSemanticCorpusEntry.all where entry.knownIssues.isEmpty {
			let result = try entry.encoded()
			try Data(result.codestream).write(
				to: directory.appendingPathComponent(entry.name + ".jxl"))
			try SemanticDump(swiftJPEGDecisions: result.decisions).serialized.write(
				to: directory.appendingPathComponent(entry.name + ".swift.sem"),
				atomically: true, encoding: .utf8)
		}
		if let eligiblePath = ProcessInfo.processInfo.environment[
			"JXL_CROSSCHECK_ELIGIBLE_INPUT"]
		{
			let image = try loadPPM(
				data: [UInt8](Data(contentsOf: URL(fileURLWithPath: eligiblePath))),
				name: "eligible pixel crop")
			let result = try SwiftSemanticEncoding.encode(image, distance: 1)
			try Data(result.codestream).write(
				to: directory.appendingPathComponent("swift_2057x257.jxl"))
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
		#expect(files.filter { $0.pathExtension == "jxl" }.count >= 8)
		if ProcessInfo.processInfo.environment["JXL_CROSSCHECK_ELIGIBLE_INPUT"] != nil {
			#expect(files.contains { $0.lastPathComponent == "swift_2057x257.jxl" })
		}
		#expect(files.filter { $0.lastPathComponent.hasSuffix(".swift.sem") }.count == 6)
	}

	@Test(
		"the harness's dump of Swift's file equals the Swift-side dump",
		.enabled(if: directory != nil))
	func harnessAgreesWithEmitters() throws {
		let directory = try #require(Self.directory)
		let pixelEntries = SemanticCorpusEntry.all.map { ($0.name, $0.knownIssues) }
		let jpegEntries = JPEGSemanticCorpusEntry.all
			.filter { $0.knownIssues.isEmpty }.map { ($0.name, $0.knownIssues) }
		#expect(pixelEntries.count == 5)
		#expect(jpegEntries.count == 1)
		for (name, issues) in pixelEntries + jpegEntries {
			let reference = try SemanticDump(
				parsing: String(
					contentsOf: directory.appendingPathComponent(
						name + ".harness.sem"), encoding: .utf8))
			let actual = try SemanticDump(
				parsing: String(
					contentsOf: directory.appendingPathComponent(
						name + ".swift.sem"), encoding: .utf8))
			let emittedCategories =
				name == "jpeg_flat_444"
				? SemanticDump.decoderObservableCategories
				: SemanticDump.swiftEmittedCategories
			#expect(
				Set(actual.fields.keys.map { String($0.split(separator: ".")[0]) })
					== emittedCategories)
			if name == "jpeg_flat_444" { #expect(issues.isEmpty) }
			#expect(
				reference.restricted(to: SemanticDump.decoderObservableCategories)
					.differences(
						from: actual.restricted(
							to: SemanticDump.decoderObservableCategories
						)
					).isEmpty,
				"\(name): \(reference.restricted(to: SemanticDump.decoderObservableCategories).differences(from: actual.restricted(to: SemanticDump.decoderObservableCategories)))"
			)
		}
	}

	@Test(
		"each mutated file's harness dump differs from the unaltered file's in exactly the mutated field",
		.enabled(if: directory != nil))
	func mutationsDifferInMutatedFieldOnly() throws {
		try Self.verifyMutations(in: #require(Self.directory))
	}

	@Test(
		"upstream observes sections and selectors in actual Swift codestreams",
		.enabled(if: directory != nil))
	func actualSwiftLayoutsDecode() throws {
		let directory = try #require(Self.directory)
		for (name, groups, grid) in [
			("flower_512_d1", 4, [Int64(2), 2]),
			("flower_1024", 16, [Int64(4), 4]),
			("reference_flower_512", 4, [Int64(2), 2]),
			("reference_flower_1024", 16, [Int64(4), 4]),
		] {
			let layout = try SemanticDump(
				parsing: String(
					contentsOf: directory.appendingPathComponent(
						name + ".layout.sem"),
					encoding: .utf8))
			let codestream = try Data(
				contentsOf: directory.appendingPathComponent(name + ".jxl"))
			#expect(try integers(layout, "entropy_layout.group_grid") == grid)
			#expect(
				try integers(layout, "entropy_layout.group_count") == [
					Int64(groups)
				])
			#expect(try integers(layout, "entropy_layout.histogram_set_count") == [1])
			#expect(try integers(layout, "entropy_layout.selector_bits") == [0])
			let ids = try integers(layout, "entropy_layout.section_ids")
			let offsets = try integers(layout, "entropy_layout.section_offsets")
			let sizes = try integers(layout, "entropy_layout.section_sizes")
			let indices = try integers(layout, "entropy_layout.section_indices")
			#expect(Set(ids).count == ids.count)
			#expect(indices == (0..<Int64(ids.count)).map { $0 })
			#expect(offsets.count == ids.count && sizes.count == ids.count)
			#expect(
				zip(offsets, sizes).allSatisfy {
					$0.0 >= 0 && $0.1 >= 0
						&& $0.0 + $0.1 <= Int64(codestream.count)
				})
			let selectors = try integers(layout, "entropy_layout.ac_selectors")
			#expect(selectors.count == groups * 4)
			#expect(
				stride(from: 3, to: selectors.count, by: 4).allSatisfy {
					selectors[$0] == 0
				})
		}
		let eligible = try SemanticDump(
			parsing: String(
				contentsOf: directory.appendingPathComponent(
					"reference_2057x257.layout.sem"), encoding: .utf8))
		#expect(try integers(eligible, "entropy_layout.group_grid") == [9, 2])
		#expect(try integers(eligible, "entropy_layout.group_count") == [18])
		#expect(try integers(eligible, "entropy_layout.dc_group_count") == [2])
		#expect(try integers(eligible, "entropy_layout.histogram_set_count") == [2])
		#expect(try integers(eligible, "entropy_layout.selector_bits") == [1])
		let selectorRecords = try integers(eligible, "entropy_layout.ac_selectors")
		#expect(selectorRecords.count == 18 * 4)
		#expect(
			stride(from: 1, to: selectorRecords.count, by: 4).map {
				selectorRecords[$0]
			} == Array(0..<18).map(Int64.init))
		#expect(
			stride(from: 3, to: selectorRecords.count, by: 4).map {
				selectorRecords[$0]
			} == Array(repeating: 0, count: 8) + [1] + Array(repeating: 0, count: 8) + [
				1
			])
		let eligibleBytes = try Data(
			contentsOf: directory.appendingPathComponent("reference_2057x257.jxl"))
		let eligibleIDs = try integers(eligible, "entropy_layout.section_ids")
		let eligibleIndices = try integers(eligible, "entropy_layout.section_indices")
		let eligibleOffsets = try integers(eligible, "entropy_layout.section_offsets")
		let eligibleSizes = try integers(eligible, "entropy_layout.section_sizes")
		#expect(Set(eligibleIDs).count == eligibleIDs.count)
		#expect(eligibleIndices == (0..<Int64(eligibleIDs.count)).map { $0 })
		#expect(
			eligibleOffsets.count == eligibleIDs.count
				&& eligibleSizes.count == eligibleIDs.count)
		#expect(
			zip(eligibleOffsets, eligibleSizes).allSatisfy {
				$0.0 >= 0 && $0.1 >= 0 && $0.0 + $0.1 <= Int64(eligibleBytes.count)
			})
		let swiftEligible = try SemanticDump(
			parsing: String(
				contentsOf: directory.appendingPathComponent(
					"swift_2057x257.layout.sem"), encoding: .utf8))
		#expect(try integers(swiftEligible, "entropy_layout.group_grid") == [9, 2])
		#expect(try integers(swiftEligible, "entropy_layout.group_count") == [18])
		#expect(try integers(swiftEligible, "entropy_layout.dc_group_count") == [2])
		#expect(try integers(swiftEligible, "entropy_layout.histogram_set_count") == [1])
		#expect(try integers(swiftEligible, "entropy_layout.selector_bits") == [0])
		let swiftSelectors = try integers(swiftEligible, "entropy_layout.ac_selectors")
		#expect(swiftSelectors.count == 18 * 4)
		#expect(
			stride(from: 1, to: swiftSelectors.count, by: 4).map {
				swiftSelectors[$0]
			} == Array(0..<18).map(Int64.init))
		#expect(
			stride(from: 3, to: swiftSelectors.count, by: 4).allSatisfy {
				swiftSelectors[$0] == 0
			})
		let swiftBytes = try Data(
			contentsOf: directory.appendingPathComponent("swift_2057x257.jxl"))
		let swiftIDs = try integers(swiftEligible, "entropy_layout.section_ids")
		let swiftIndices = try integers(swiftEligible, "entropy_layout.section_indices")
		let swiftOffsets = try integers(swiftEligible, "entropy_layout.section_offsets")
		let swiftSizes = try integers(swiftEligible, "entropy_layout.section_sizes")
		#expect(Set(swiftIDs).count == swiftIDs.count)
		#expect(swiftIndices == (0..<Int64(swiftIDs.count)).map { $0 })
		#expect(
			swiftOffsets.count == swiftIDs.count
				&& swiftSizes.count == swiftIDs.count)
		#expect(
			zip(swiftOffsets, swiftSizes).allSatisfy {
				$0.0 >= 0 && $0.1 >= 0 && $0.0 + $0.1 <= Int64(swiftBytes.count)
			})
	}

	private func integers(_ dump: SemanticDump, _ field: String) throws -> [Int64] {
		guard case .integers(let values)? = dump.fields[field] else {
			throw SemanticDumpError.malformedEntropyFixture(
				name: "layout", field: field)
		}
		return values
	}
}
