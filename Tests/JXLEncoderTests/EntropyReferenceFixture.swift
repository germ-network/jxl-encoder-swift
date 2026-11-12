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
		func integers(in dump: SemanticDump, field: String) throws -> [Int64] {
			guard case .integers(let values)? = dump.fields[field] else {
				throw SemanticDumpError.malformedEntropyFixture(
					name: name, field: field)
			}
			return values
		}
		let inputFields: [String]
		let expectedFields: [String]
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
			let counts = try integers(in: input, field: "input.histogram.counts")
			let logAlpha = try integers(
				in: input, field: "input.histogram.log_alpha_size")
			let strategy = try integers(in: input, field: "input.histogram.strategy")
			guard counts.allSatisfy({ $0 >= 0 && $0 <= Int64(UInt32.max) }),
				logAlpha.count == 1,
				(1..<ANSConstants.logTabSize).contains(Int(logAlpha[0])),
				strategy.count == 1, (0...2).contains(strategy[0])
			else { throw SemanticDumpError.unsupportedEntropyFixture(name) }
		} else if name.hasPrefix("clusters_") {
			inputFields = [
				"input.clusters.mode", "input.clusters.limit",
				"input.clusters.lengths",
				"input.clusters.counts",
			]
			expectedFields = [
				"entropy.clusters.count", "entropy.clusters.map",
				"entropy.clusters.alphabet_lengths",
				"entropy.clusters.total_counts",
				"entropy.clusters.histogram_counts",
			]
			let mode = try integers(in: input, field: "input.clusters.mode")
			let limit = try integers(in: input, field: "input.clusters.limit")
			let lengths = try integers(in: input, field: "input.clusters.lengths")
			let counts = try integers(in: input, field: "input.clusters.counts")
			guard mode.count == 1, (0...1).contains(mode[0]), limit.count == 1,
				limit[0] > 0, lengths.count > 0,
				lengths.allSatisfy({ (1...64).contains($0) }),
				lengths.reduce(Int64(0), +) == Int64(counts.count),
				counts.allSatisfy({ $0 >= 0 && $0 <= Int64(UInt32.max) })
			else { throw SemanticDumpError.unsupportedEntropyFixture(name) }
		} else {
			throw SemanticDumpError.unsupportedEntropyFixture(name)
		}
		for field in inputFields where input.fields[field] == nil {
			throw SemanticDumpError.malformedEntropyFixture(name: name, field: field)
		}
		for field in expectedFields where expected.fields[field] == nil {
			throw SemanticDumpError.malformedEntropyFixture(name: name, field: field)
		}
		return Self(input: input, expected: expected)
	}
}
