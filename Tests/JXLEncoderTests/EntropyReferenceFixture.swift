import Foundation

@testable import JXLEncoder

struct EntropyReferenceFixture {
	let input: SemanticDump
	let expected: SemanticDump

	static func load(_ name: String) throws -> Self {
		guard name.range(of: #"^[a-z0-9_]+$"#, options: .regularExpression) != nil else {
			throw SemanticDumpError.fixtureNotFound(name)
		}
		let bundle = Bundle.module
		guard
			let inputURL = bundle.url(
				forResource: "\(name).input", withExtension: "sem",
				subdirectory: "Fixtures/entropy"),
			let expectedURL = bundle.url(
				forResource: "\(name).expected", withExtension: "sem",
				subdirectory: "Fixtures/entropy")
		else {
			throw SemanticDumpError.fixtureNotFound(name)
		}
		let input = try SemanticDump(
			parsing: String(contentsOf: inputURL, encoding: .utf8))
		let expected = try SemanticDump(
			parsing: String(contentsOf: expectedURL, encoding: .utf8))
		try validate(name: name, input: input, expected: expected)
		return Self(input: input, expected: expected)
	}

	static func validate(
		name: String, input: SemanticDump, expected: SemanticDump
	) throws {
		func checkedSum(_ values: [Int64], limit: Int64) -> Int64? {
			var sum: Int64 = 0
			for value in values {
				guard value >= 0, value <= limit - sum else { return nil }
				sum += value
			}
			return sum
		}
		func integers(_ dump: SemanticDump, _ field: String) throws -> [Int64] {
			guard case .integers(let values)? = dump.fields[field] else {
				throw SemanticDumpError.malformedEntropyFixture(
					name: name, field: field)
			}
			return values
		}
		let inputFields: Set<String>
		let expectedFields: Set<String>
		if name.hasPrefix("ans_") {
			inputFields = [
				"input.histogram.counts", "input.histogram.log_alpha_size",
				"input.histogram.strategy",
			]
			expectedFields = [
				"entropy.histogram.normalized", "entropy.histogram.alphabet_size",
				"entropy.histogram.serialized_method",
				"entropy.histogram.serialized_shift",
				"entropy.histogram.log_alpha_size", "entropy.histogram.freqs",
				"entropy.histogram.reverse_map", "entropy.histogram.bit_count",
				"entropy.histogram.bytes",
			]
			let counts = try integers(input, "input.histogram.counts")
			let logAlpha = try integers(input, "input.histogram.log_alpha_size")
			let strategy = try integers(input, "input.histogram.strategy")
			guard logAlpha.count == 1,
				(5...8).contains(logAlpha[0]),
				counts.count <= 256,
				((counts.count + 15) / 16) * 16 <= (1 << Int(logAlpha[0])),
				checkedSum(counts, limit: Int64(UInt32.max)) != nil,
				counts.allSatisfy({ (0...Int64(Int32.max)).contains($0) }),
				strategy.count == 1, (0...2).contains(strategy[0])
			else { throw SemanticDumpError.unsupportedEntropyFixture(name) }
			let alphabet = try integers(expected, "entropy.histogram.alphabet_size")
			let method = try integers(expected, "entropy.histogram.serialized_method")
			let shift = try integers(expected, "entropy.histogram.serialized_shift")
			let outputAlpha = try integers(expected, "entropy.histogram.log_alpha_size")
			let normalized = try integers(expected, "entropy.histogram.normalized")
			let frequencies = try integers(expected, "entropy.histogram.freqs")
			let reverseMap = try integers(expected, "entropy.histogram.reverse_map")
			let bitCount = try integers(expected, "entropy.histogram.bit_count")
			let bytes = try integers(expected, "entropy.histogram.bytes")
			let inputAlphabet = Int64(
				counts.lastIndex(where: { $0 > 0 }).map { $0 + 1 } ?? 0)
			let encodedByteCount =
				bitCount.count == 1 && bitCount[0] >= 0
				? bitCount[0] / 8 + (bitCount[0].isMultiple(of: 8) ? 0 : 1)
				: -1
			guard alphabet.count == 1,
				alphabet[0] == inputAlphabet,
				method.count == 1, (0...2).contains(method[0]), shift.count == 1,
				outputAlpha == logAlpha, normalized.count == Int(alphabet[0]),
				frequencies.count == Int(alphabet[0]), bitCount.count == 1,
				encodedByteCount >= 0, Int64(bytes.count) == encodedByteCount,
				bytes.allSatisfy({ (0...255).contains($0) }),
				normalized.allSatisfy({
					(0...ANSConstants.tabSize).contains(Int($0))
				}),
				frequencies.allSatisfy({
					(0...ANSConstants.tabSize).contains(Int($0))
				}),
				reverseMap.count == (alphabet[0] == 0 ? 0 : ANSConstants.tabSize),
				reverseMap.allSatisfy({
					(0..<ANSConstants.tabSize).contains(Int($0))
				}),
				normalized.isEmpty
					|| normalized.reduce(Int64(0), +) == ANSConstants.tabSize,
				frequencies.isEmpty
					|| frequencies.reduce(Int64(0), +) == ANSConstants.tabSize,
				method[0] < 2
					? shift[0] == -1
					: (0..<ANSConstants.logTabSize).contains(Int(shift[0]))
			else { throw SemanticDumpError.unsupportedEntropyFixture(name) }
		} else if name.hasPrefix("clusters_") {
			inputFields = [
				"input.clusters.mode", "input.clusters.limit",
				"input.clusters.lengths", "input.clusters.counts",
			]
			expectedFields = [
				"entropy.clusters.count", "entropy.clusters.map",
				"entropy.clusters.alphabet_lengths",
				"entropy.clusters.total_counts",
				"entropy.clusters.histogram_counts",
				"entropy.clusters.input_total_count",
				"entropy.clusters.output_total_count",
			]
			let mode = try integers(input, "input.clusters.mode")
			let limit = try integers(input, "input.clusters.limit")
			let lengths = try integers(input, "input.clusters.lengths")
			let counts = try integers(input, "input.clusters.counts")
			guard let total = checkedSum(counts, limit: Int64(UInt32.max)),
				let lengthTotal = checkedSum(lengths, limit: Int64.max),
				lengthTotal == Int64(counts.count),
				mode.count == 1, (0...1).contains(mode[0]), limit.count == 1,
				(1...128).contains(limit[0]), !lengths.isEmpty,
				lengths.allSatisfy({ (1...64).contains($0) }),
				counts.allSatisfy({ (0...Int64(Int32.max)).contains($0) })
			else { throw SemanticDumpError.unsupportedEntropyFixture(name) }
			let clusterCount = try integers(expected, "entropy.clusters.count")
			let map = try integers(expected, "entropy.clusters.map")
			let alphabetLengths = try integers(
				expected, "entropy.clusters.alphabet_lengths")
			let totals = try integers(expected, "entropy.clusters.total_counts")
			let outputCounts = try integers(
				expected, "entropy.clusters.histogram_counts")
			let inputTotal = try integers(
				expected, "entropy.clusters.input_total_count")
			let outputTotal = try integers(
				expected, "entropy.clusters.output_total_count")
			guard clusterCount.count == 1,
				(1...min(Int(limit[0]), lengths.count)).contains(
					Int(clusterCount[0])),
				map.count == lengths.count,
				map.allSatisfy({ (0..<clusterCount[0]).contains($0) }),
				alphabetLengths.count == Int(clusterCount[0]),
				alphabetLengths.allSatisfy({ (0...64).contains($0) }),
				totals.count == Int(clusterCount[0]),
				totals.allSatisfy({ $0 >= 0 }),
				outputCounts.count == alphabetLengths.reduce(0, +),
				outputCounts.allSatisfy({ (0...Int64(Int32.max)).contains($0) }),
				inputTotal == [total], outputTotal == [total],
				checkedSum(totals, limit: Int64(UInt32.max)) == total
			else { throw SemanticDumpError.unsupportedEntropyFixture(name) }
			var offset = 0
			for index in alphabetLengths.indices {
				let end = offset + Int(alphabetLengths[index])
				guard end <= outputCounts.count,
					checkedSum(
						Array(outputCounts[offset..<end]),
						limit: Int64(UInt32.max))
						== totals[index]
				else { throw SemanticDumpError.unsupportedEntropyFixture(name) }
				offset = end
			}
		} else {
			throw SemanticDumpError.unsupportedEntropyFixture(name)
		}
		guard Set(input.fields.keys) == inputFields,
			Set(expected.fields.keys) == expectedFields
		else { throw SemanticDumpError.unsupportedEntropyFixture(name) }
	}
}
