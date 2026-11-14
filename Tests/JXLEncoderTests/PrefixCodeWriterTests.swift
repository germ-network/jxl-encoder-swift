import Foundation
import Testing

@testable import JXLEncoder

/// Static-code bytes remain inherited-tiny regressions; adaptive tree depths
/// come from the pinned full-libjxl primitive fixture.
@Suite("Prefix code writer")
struct PrefixCodeWriterTests {
	struct Reference {
		var streams: [String: (bits: Int, bytes: [UInt8])] = [:]

		init() throws {
			guard
				let url = Bundle.module.url(
					forResource: "prefix_codes", withExtension: "txt",
					subdirectory: "Fixtures")
			else { throw StageDump.DumpError.fixtureNotFound("prefix_codes") }
			let text = try String(contentsOf: url, encoding: .utf8)
			for line in text.split(separator: "\n") {
				let parts = line.split(separator: " ").map(String.init)
				guard let label = parts.first else { continue }
				if parts.count >= 3, label != "CODES" {
					let bits = Int(parts[1]) ?? 0
					let bytes = parts.dropFirst(3).compactMap {
						UInt8($0, radix: 16)
					}
					streams[label] = (bits, bytes)
				}
			}
		}
	}

	@Test("CreateHuffmanTree matches pinned full libjxl")
	func huffmanTree() throws {
		let fixture = try EntropyReferenceFixture.load("huffman_tree_full_reference")
		let limit = try fixture.integers(fixture.input, "input.huffman.tree_limit")
		let lengths = try fixture.integers(fixture.input, "input.huffman.lengths")
		let counts = try fixture.integers(fixture.input, "input.huffman.counts")
		let expectedLengths = try fixture.integers(
			fixture.expected, "entropy.huffman.lengths")
		let expectedDepths = try fixture.integers(
			fixture.expected, "entropy.huffman.depths")
		#expect(limit == [15] && lengths == expectedLengths)
		#expect(lengths.reduce(0, +) == Int64(counts.count))
		var offset = 0
		for length in lengths {
			let end = offset + Int(length)
			let histogram = counts[offset..<end].map(UInt32.init)
			let actual = HuffmanTree.createTree(
				counts: histogram, length: histogram.count,
				treeLimit: Int(limit[0]))
			#expect(actual.map(Int64.init) == Array(expectedDepths[offset..<end]))
			offset = end
		}
		#expect(offset == expectedDepths.count)
	}

	@Test("each static prefix code serializes identically", arguments: 0..<8)
	func individualCodes(index: Int) throws {
		let reference = try Reference()
		for (prefix, codes) in [
			("DC", StaticEntropyCodes.dcPrefixCodes),
			("AC", StaticEntropyCodes.acPrefixCodes),
		] {
			guard let expected = reference.streams["\(prefix)\(index)"] else {
				Issue.record("missing reference for \(prefix)\(index)")
				continue
			}
			var writer = BitWriter()
			PrefixCodeWriter.writePrefixCode(codes[index], writer: &writer)
			#expect(writer.bitsWritten == expected.bits, "\(prefix)\(index) bit count")
			writer.zeroPadToByte()
			#expect(writer.take() == expected.bytes, "\(prefix)\(index) bytes")
		}
	}

	@Test("full code sets serialize identically", arguments: ["DC", "AC"])
	func codeSets(which: String) throws {
		let reference = try Reference()
		let codes =
			which == "DC"
			? StaticEntropyCodes.dcPrefixCodes : StaticEntropyCodes.acPrefixCodes
		let expected = try #require(reference.streams[which])

		var writer = BitWriter()
		writer.write(1, 1)  // use_prefix_code — the caller's job since ANS landed
		PrefixCodeWriter.writePrefixCodes(codes, writer: &writer)
		#expect(writer.bitsWritten == expected.bits)
		writer.zeroPadToByte()
		let actual = writer.take()
		let firstDifference = zip(actual, expected.bytes).enumerated()
			.first { $0.element.0 != $0.element.1 }?.offset
		#expect(firstDifference == nil, "first differing byte at \(firstDifference ?? -1)")
		#expect(actual.count == expected.bytes.count)
	}

	/// Canonical codes must be prefix-free and use their stated lengths, or the
	/// decoder desynchronises.
	@Test("generated symbols form a valid canonical code")
	func canonicalCodes() {
		let counts: [UInt32] = [10, 3, 3, 2, 1, 1, 1]
		let depths = HuffmanTree.createTree(
			counts: counts, length: counts.count, treeLimit: 15)
		let bits = HuffmanTree.convertBitDepthsToSymbols(
			depth: depths, length: counts.count)
		// Kraft equality: a complete code sums to exactly 1.
		var kraft = 0.0
		for d in depths where d != 0 { kraft += pow(2.0, -Double(d)) }
		#expect(abs(kraft - 1.0) < 1e-9)
		for i in 0..<counts.count where depths[i] != 0 {
			#expect(bits[i] < (1 << UInt16(depths[i])))
		}
	}
}
