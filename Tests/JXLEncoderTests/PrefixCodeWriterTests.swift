import Foundation
import Testing

@testable import JXLEncoder

/// Expected bytes come from `Reference/tools/genprefix.cc`, which calls
/// libjxl-tiny's own `CreateHuffmanTree`, `WritePrefixCode` and
/// `WritePrefixCodes` through test hooks.
@Suite("Prefix code writer")
struct PrefixCodeWriterTests {
	struct Reference {
		var trees: [(counts: [UInt32], depths: [UInt8])] = []
		var streams: [String: (bits: Int, bytes: [UInt8])] = [:]

		init() throws {
			guard
				let url = Bundle.module.url(
					forResource: "prefix_codes", withExtension: "txt",
					subdirectory: "Fixtures")
			else { throw StageDump.DumpError.fixtureNotFound("prefix_codes") }
			let text = try String(contentsOf: url, encoding: .utf8)
			// tree lines carry only depths; the counts live in the generator, so
			// they are mirrored here
			let histograms: [[UInt32]] = [
				[1, 1, 1, 1],
				[5, 0, 3, 0, 1],
				[100, 1, 1, 1, 1, 1, 1, 1],
				[1],
				[0, 0, 7],
				[
					1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096,
					8192, 16384,
				],
			]
			for line in text.split(separator: "\n") {
				let parts = line.split(separator: " ").map(String.init)
				guard let label = parts.first else { continue }
				if label.hasPrefix("T"), let index = Int(label.dropFirst()) {
					let depths = parts.dropFirst(2).compactMap { UInt8($0) }
					trees.append((histograms[index], depths))
				} else if parts.count >= 3, label != "TREES", label != "CODES" {
					let bits = Int(parts[1]) ?? 0
					let bytes = parts.dropFirst(3).compactMap {
						UInt8($0, radix: 16)
					}
					streams[label] = (bits, bytes)
				}
			}
		}
	}

	@Test("CreateHuffmanTree matches libjxl-tiny")
	func huffmanTree() throws {
		let reference = try Reference()
		#expect(reference.trees.count == 6)
		for (counts, expected) in reference.trees {
			let actual = HuffmanTree.createTree(
				counts: counts, length: counts.count, treeLimit: 15)
			#expect(actual == expected, "counts \(counts)")
		}
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
