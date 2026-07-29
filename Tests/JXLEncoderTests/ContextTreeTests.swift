import Foundation
import Testing

@testable import JXLEncoder

/// Reference bytes from `Reference/tools/gentree.cc`, which calls libjxl-tiny's
/// own `WriteContextTree` and `WriteEntropyCode`. These exercise histogram
/// clustering, context-map coding and prefix-code serialization together.
@Suite("Context tree and entropy code")
struct ContextTreeTests {
	static func loadReference() throws -> [String: (bits: Int, bytes: [UInt8])] {
		guard
			let url = Bundle.module.url(
				forResource: "context_tree", withExtension: "txt",
				subdirectory: "Fixtures")
		else { throw StageDump.DumpError.fixtureNotFound("context_tree") }
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

	@Test("context tree matches libjxl-tiny", arguments: [1, 2, 3, 7, 16, 100])
	func contextTree(dcGroupCount: Int) throws {
		let reference = try Self.loadReference()
		let expected = try #require(reference["TREE\(dcGroupCount)"])

		var writer = BitWriter()
		ContextTree.write(dcGroupCount: dcGroupCount, writer: &writer)

		#expect(writer.bitsWritten == expected.bits)
		writer.zeroPadToByte()
		let actual = writer.take()
		let firstDifference = zip(actual, expected.bytes).enumerated()
			.first { $0.element.0 != $0.element.1 }?.offset
		#expect(firstDifference == nil, "first differing byte at \(firstDifference ?? -1)")
		#expect(actual.count == expected.bytes.count)
	}

	@Test("entropy code serializes identically", arguments: ["DC", "AC"])
	func entropyCode(which: String) throws {
		let reference = try Self.loadReference()
		let expected = try #require(reference["EC\(which)"])
		let code: EntropyCode = which == "DC" ? .staticDC : .staticAC

		var writer = BitWriter()
		EntropyCodeWriter.write(code, writer: &writer)

		#expect(writer.bitsWritten == expected.bits)
		writer.zeroPadToByte()
		let actual = writer.take()
		let firstDifference = zip(actual, expected.bytes).enumerated()
			.first { $0.element.0 != $0.element.1 }?.offset
		#expect(firstDifference == nil, "first differing byte at \(firstDifference ?? -1)")
		#expect(actual.count == expected.bytes.count)
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
