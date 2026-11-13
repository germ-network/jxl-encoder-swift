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
		} else if name.hasPrefix("context_") {
			var requiredInputFields: Set<String> = [
				"input.context_map.entries", "input.context_map.num_histograms",
				"input.context_map.allow_ans", "input.context_map.map_length",
			]
			var requiredExpectedFields: Set<String> = [
				"entropy.context_map.entries", "entropy.context_map.num_histograms",
				"entropy.context_map.simple", "entropy.context_map.entry_bits",
				"entropy.context_map.use_mtf",
				"entropy.context_map.use_prefix_code",
				"entropy.context_map.token_count",
				"entropy.context_map.token_count_status",
				"entropy.context_map.bit_count", "entropy.context_map.bytes",
			]
			let hasCandidates = [
				"context_simple_profitability", "context_simple_tie_candidate",
				"context_tie_raw_mtf", "context_mtf_ans", "context_raw_rle",
			].contains(name)
			if hasCandidates {
				requiredInputFields.insert("input.context_map.mtf_entries")
				requiredExpectedFields.formUnion([
					"entropy.context_map.mtf_entries",
					"entropy.context_map.raw_cost",
					"entropy.context_map.mtf_cost",
					"entropy.context_map.simple_cost",
					"entropy.context_map.raw_token_count",
					"entropy.context_map.mtf_token_count",
				])
			}
			inputFields = requiredInputFields
			expectedFields = requiredExpectedFields
			let entries = try integers(input, "input.context_map.entries")
			let mapLength = try integers(input, "input.context_map.map_length")
			let candidateMTF =
				hasCandidates
				? try integers(input, "input.context_map.mtf_entries") : nil
			let histograms = try integers(input, "input.context_map.num_histograms")
			let allowANS = try integers(input, "input.context_map.allow_ans")
			guard histograms.count == 1, (1...255).contains(histograms[0]),
				allowANS.count == 1, (0...1).contains(allowANS[0]),
				!entries.isEmpty, entries.count <= 1_000_000,
				mapLength == [Int64(entries.count)],
				entries.allSatisfy({ (0..<histograms[0]).contains($0) })
			else { throw SemanticDumpError.unsupportedEntropyFixture(name) }
			let outputEntries = try integers(expected, "entropy.context_map.entries")
			let outputHistograms = try integers(
				expected, "entropy.context_map.num_histograms")
			let simple = try integers(expected, "entropy.context_map.simple")
			let entryBits = try integers(expected, "entropy.context_map.entry_bits")
			let useMTF = try integers(expected, "entropy.context_map.use_mtf")
			let usePrefix = try integers(
				expected, "entropy.context_map.use_prefix_code")
			let tokenCount = try integers(expected, "entropy.context_map.token_count")
			let tokenCountStatus = try integers(
				expected, "entropy.context_map.token_count_status")
			let bitCount = try integers(expected, "entropy.context_map.bit_count")
			let bytes = try integers(expected, "entropy.context_map.bytes")
			guard simple.count == 1, entryBits.count == 1,
				useMTF.count == 1, usePrefix.count == 1,
				tokenCount.count == 1, tokenCountStatus.count == 1,
				bitCount.count == 1
			else { throw SemanticDumpError.unsupportedEntropyFixture(name) }
			if hasCandidates {
				let outputMTF = try integers(
					expected, "entropy.context_map.mtf_entries")
				let rawCost = try integers(expected, "entropy.context_map.raw_cost")
				let mtfCost = try integers(expected, "entropy.context_map.mtf_cost")
				let simpleCost = try integers(
					expected, "entropy.context_map.simple_cost")
				let rawTokenCount = try integers(
					expected, "entropy.context_map.raw_token_count")
				let mtfTokenCount = try integers(
					expected, "entropy.context_map.mtf_token_count")
				let entryWidth = Int64(ceilLog2Nonzero(Int(histograms[0])))
				guard outputMTF == candidateMTF,
					rawCost.count == 1, rawCost[0] >= 0,
					mtfCost.count == 1, mtfCost[0] >= 0,
					rawTokenCount.count == 1, rawTokenCount[0] >= 0,
					mtfTokenCount.count == 1, mtfTokenCount[0] >= 0,
					simpleCost == [
						entryWidth < 4
							? entryWidth * Int64(entries.count) : -1
					]
				else { throw SemanticDumpError.unsupportedEntropyFixture(name) }
				if name == "context_tie_raw_mtf" {
					guard candidateMTF == entries, mtfCost == rawCost,
						entries == [0, 1], histograms == [16],
						simpleCost == [-1]
					else {
						throw SemanticDumpError.unsupportedEntropyFixture(
							name)
					}
				} else if name == "context_simple_profitability" {
					guard entries == [0, 1, 0, 1, 0, 1],
						candidateMTF == [0, 1, 1, 1, 1, 1],
						histograms == [2],
						simpleCost[0] < rawCost[0],
						simpleCost[0] < mtfCost[0]
					else {
						throw SemanticDumpError.unsupportedEntropyFixture(
							name)
					}
				} else if name == "context_mtf_ans" {
					guard
						entries
							== Array(repeating: [0, 1], count: 150)
							.flatMap({ $0 }),
						candidateMTF == [0]
							+ Array(repeating: 1, count: 299),
						histograms == [4], simpleCost == [600],
						mtfCost[0] < rawCost[0],
						mtfTokenCount[0] == tokenCount[0]
					else {
						throw SemanticDumpError.unsupportedEntropyFixture(
							name)
					}
				} else if name == "context_raw_rle" {
					var expectedEntries = [Int]()
					expectedEntries.reserveCapacity(80)
					for value in 0..<4 {
						expectedEntries.append(
							contentsOf: repeatElement(value, count: 20))
					}
					var expectedMTF = [Int](repeating: 0, count: 20)
					for value in 1...3 {
						expectedMTF.append(value)
						expectedMTF.append(
							contentsOf: repeatElement(0, count: 19))
					}
					guard entries.map(Int.init) == expectedEntries,
						candidateMTF?.map(Int.init) == expectedMTF,
						histograms == [4], rawCost[0] < mtfCost[0],
						simpleCost == [160], simple == [0], useMTF == [0],
						tokenCountStatus == [1]
					else {
						throw SemanticDumpError.unsupportedEntropyFixture(
							name)
					}
				} else {
					guard
						entries == [
							1, 1, 0, 1, 1, 1, 1, 1, 1, 2, 2, 1, 1, 2, 2,
							1,
							2, 1, 0, 1, 1, 2, 1, 1, 0, 0, 2, 1, 1, 1, 1,
							0, 0, 0,
							1, 0, 2, 2, 2, 1, 0, 1, 1, 0, 1, 1, 0, 0,
						],
						candidateMTF == [
							1, 0, 1, 1, 0, 0, 0, 0, 0, 2, 0, 1, 0, 1,
							0, 1, 1, 1, 2, 1, 0, 2, 1, 0, 2, 0, 2, 2, 0,
							0, 0, 2,
							0, 0, 1, 1, 2, 0, 0, 2, 2, 1, 0, 1, 1, 0, 1,
							0,
						],
						histograms == [3], rawCost == simpleCost,
						simple == [0], useMTF == [0]
					else {
						throw SemanticDumpError.unsupportedEntropyFixture(
							name)
					}
				}
			}
			let encodedByteCount =
				bitCount[0] >= 0
				? bitCount[0] / 8 + (bitCount[0].isMultiple(of: 8) ? 0 : 1)
				: -1
			guard outputEntries == entries,
				outputHistograms == histograms,
				(0...1).contains(simple[0]),
				simple[0] == 1
					? (0...3).contains(entryBits[0]) : entryBits[0] == -1,
				(0...1).contains(useMTF[0]),
				simple[0] == 1
					? usePrefix[0] == -1 : (0...1).contains(usePrefix[0]),
				simple[0] == 1
					? tokenCount == [-1] && tokenCountStatus == [0]
					: (tokenCount[0] >= 0
						&& (1...3).contains(tokenCountStatus[0])),
				encodedByteCount == Int64(bytes.count),
				bytes.allSatisfy({ (0...255).contains($0) })
			else { throw SemanticDumpError.unsupportedEntropyFixture(name) }
			if name == "context_prefix_99" || name == "context_ans_100" {
				let boundary = name == "context_prefix_99" ? 99 : 100
				guard mapLength == [Int64(boundary)],
					tokenCount == [Int64(boundary)], tokenCountStatus == [1]
				else { throw SemanticDumpError.unsupportedEntropyFixture(name) }
			}
			if name == "context_mtf_ans" {
				guard simple == [0], useMTF == [1], tokenCountStatus == [2]
				else { throw SemanticDumpError.unsupportedEntropyFixture(name) }
			}
		} else if name.hasPrefix("tree_gradient_fixed_") {
			inputFields = [
				"input.tree.kind", "input.tree.total_pixels", "input.tree.bitdepth",
				"input.tree.prevprop", "input.tree.dc_group_count",
				"input.tree.projection_root",
			]
			expectedFields = [
				"entropy.tree.kind", "entropy.tree.total_pixels",
				"entropy.tree.bitdepth", "entropy.tree.prevprop",
				"entropy.tree.node_count", "entropy.tree.nodes",
				"entropy.tree.token_count", "entropy.tree.tokens",
			]
			let kind = try integers(input, "input.tree.kind")
			let totalPixels = try integers(input, "input.tree.total_pixels")
			let bitdepth = try integers(input, "input.tree.bitdepth")
			let prevprop = try integers(input, "input.tree.prevprop")
			let dcGroupCount = try integers(input, "input.tree.dc_group_count")
			let projectionRoot = try integers(input, "input.tree.projection_root")
			let outputKind = try integers(expected, "entropy.tree.kind")
			let outputPixels = try integers(expected, "entropy.tree.total_pixels")
			let outputBitdepth = try integers(expected, "entropy.tree.bitdepth")
			let outputPrevprop = try integers(expected, "entropy.tree.prevprop")
			let nodeCount = try integers(expected, "entropy.tree.node_count")
			let nodes = try integers(expected, "entropy.tree.nodes")
			let tokenCount = try integers(expected, "entropy.tree.token_count")
			let tokens = try integers(expected, "entropy.tree.tokens")
			let caseConfig: (Int64, Int64)? =
				switch name {
				case "tree_gradient_fixed_8192_dc1": (8192, 1)
				case "tree_gradient_fixed_8193_dc2": (8193, 2)
				default: nil
				}
			guard kind == [6], totalPixels.count == 1,
				[8192, 8193].contains(totalPixels[0]), bitdepth == [8],
				prevprop == [0], dcGroupCount.count == 1,
				(1...2).contains(dcGroupCount[0]), projectionRoot == [2],
				caseConfig.map({ totalPixels[0] == $0.0 && dcGroupCount[0] == $0.1 }
				)
					== true,
				outputKind == kind, outputPixels == totalPixels,
				outputBitdepth == bitdepth, outputPrevprop == prevprop,
				nodeCount.count == 1, nodeCount[0] > 0,
				nodeCount[0] <= Int64(nodes.count / 7),
				nodes.count.isMultiple(of: 7),
				nodes.count / 7 == Int(nodeCount[0]),
				tokenCount.count == 1, tokenCount[0] > 0,
				tokenCount[0] <= Int64(tokens.count / 2),
				tokens.count.isMultiple(of: 2),
				tokens.count / 2 == Int(tokenCount[0]),
				tokens.allSatisfy({ $0 >= 0 && $0 <= Int64(UInt32.max) })
			else { throw SemanticDumpError.unsupportedEntropyFixture(name) }
			var leafCount: Int64 = 0
			for index in 0..<Int(nodeCount[0]) {
				let base = index * 7
				let property = nodes[base]
				if property == -1 {
					guard nodes[base + 2] == leafCount, nodes[base + 3] == 0
					else {
						throw SemanticDumpError.unsupportedEntropyFixture(
							name)
					}
					leafCount += 1
				} else {
					guard (0...Int64(Int16.max)).contains(property),
						(0..<nodeCount[0]).contains(nodes[base + 2]),
						(0..<nodeCount[0]).contains(nodes[base + 3])
					else {
						throw SemanticDumpError.unsupportedEntropyFixture(
							name)
					}
				}
			}
		} else {
			throw SemanticDumpError.unsupportedEntropyFixture(name)
		}
		guard Set(input.fields.keys) == inputFields,
			Set(expected.fields.keys) == expectedFields
		else { throw SemanticDumpError.unsupportedEntropyFixture(name) }
	}
}
