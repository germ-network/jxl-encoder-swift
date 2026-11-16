import Foundation
import Testing

@testable import JXLEncoder

/// Frozen bytes from `Reference/legacy-tiny/tools/gentree.cc`, which calls
/// libjxl-tiny's own `WriteContextTree` and `WriteEntropyCode`.
@Suite("Legacy tiny-tree byte diagnostics")
struct ContextTreeTests {
	static func loadReference(
		_ name: String = "context_tree"
	) throws -> [String: (bits: Int, bytes: [UInt8])] {
		guard
			let url = Bundle.module.url(
				forResource: name, withExtension: "txt",
				subdirectory: "Fixtures")
		else { throw StageDump.DumpError.fixtureNotFound(name) }
		var result: [String: (Int, [UInt8])] = [:]
		for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
			let parts = line.split(separator: " ").map(String.init)
			guard parts.count >= 3 else { continue }
			result[parts[0]] = (
				Int(parts[1]) ?? 0,
				parts.dropFirst(3).compactMap { UInt8($0, radix: 16) }
			)
		}
		return result
	}

	@Test("legacy tiny context tree bytes", arguments: [1, 2, 3, 7, 16, 100])
	func contextTree(dcGroupCount: Int) throws {
		let reference = try Self.loadReference()
		let expected = try #require(reference["TREE\(dcGroupCount)"])

		var writer = BitWriter()
		ContextTree.write(dcGroupCount: dcGroupCount, writer: &writer)

		withKnownIssue(
			Comment(rawValue: "GER-3389: TREE\(dcGroupCount) bit count")
		) {
			#expect(writer.bitsWritten == expected.bits)
		}
		writer.zeroPadToByte()
		let actual = writer.take()
		let firstDifference = zip(actual, expected.bytes).enumerated()
			.first { $0.element.0 != $0.element.1 }?.offset
		withKnownIssue(
			Comment(rawValue: "GER-3389: TREE\(dcGroupCount) bytes")
		) {
			#expect(
				firstDifference == nil,
				"first differing byte at \(firstDifference ?? -1)")
		}
		withKnownIssue(
			Comment(rawValue: "GER-3389: TREE\(dcGroupCount) byte count")
		) {
			#expect(actual.count == expected.bytes.count)
		}
	}

	@Test("entropy code serializes identically", arguments: ["DC", "AC"])
	func entropyCode(which: String) throws {
		let frozenReference = try Self.loadReference()
		let frozen = try #require(frozenReference["EC\(which)"])
		let supplementalReference = try Self.loadReference("context_entropy_code")
		let supplemental = try #require(supplementalReference["EC\(which)"])
		let code: EntropyCode = which == "DC" ? .staticDC : .staticAC

		var writer = BitWriter()
		EntropyCodeWriter.write(code, writer: &writer)

		withKnownIssue(
			Comment(
				rawValue:
					"GER-3396 \(which): shared source map policy changes static-code bit count (lib/jxl/enc_context_map.cc:65-139)"
			)
		) {
			#expect(writer.bitsWritten == frozen.bits)
		}
		#expect(writer.bitsWritten == supplemental.bits)
		writer.zeroPadToByte()
		let actual = writer.take()
		let frozenDifference = zip(actual, frozen.bytes).enumerated()
			.first { $0.element.0 != $0.element.1 }?.offset
		withKnownIssue(
			Comment(
				rawValue:
					"GER-3396 \(which): shared source map policy changes static-code bytes (lib/jxl/enc_context_map.cc:65-139)"
			)
		) {
			#expect(
				frozenDifference == nil,
				"first differing byte at \(frozenDifference ?? -1)")
		}
		withKnownIssue(
			Comment(
				rawValue:
					"GER-3396 \(which): shared source map policy changes static-code byte count (lib/jxl/enc_context_map.cc:65-139)"
			)
		) {
			#expect(actual.count == frozen.bytes.count)
		}
		#expect(actual == supplemental.bytes)
	}

	@Test("the static tree carries 313 tokens")
	func tokenCount() {
		#expect(ContextTree.staticTokens.count == 313)
	}

	/// Clustering must produce a context map whose symbols first appear in
	/// increasing order — the format's canonical form.
	@Test("clustered context maps are canonical")
	func canonicalContextMap() {
		var histograms: [Histogram] = []
		for i in 0..<12 {
			var h = Histogram()
			for _ in 0..<(i + 1) { h.add(UInt32(i % 5)) }
			histograms.append(h)
		}
		let (clusters, contextMap) = HistogramCluster.cluster(histograms)
		#expect(clusters.count <= HistogramCluster.clustersLimit)

		var seen = -1
		for entry in contextMap {
			#expect(
				Int(entry) <= seen + 1,
				"context map is not canonical: \(contextMap)")
			seen = max(seen, Int(entry))
		}
	}
}
