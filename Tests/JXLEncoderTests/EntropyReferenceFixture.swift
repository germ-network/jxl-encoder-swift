import Foundation

@testable import JXLEncoder

struct EntropyReferenceFixture {
	let input: SemanticDump
	let expected: SemanticDump

	func integers(_ dump: SemanticDump, _ field: String) throws -> [Int64] {
		guard case .integers(let values)? = dump.fields[field] else {
			throw SemanticDumpError.malformedEntropyFixture(
				name: "entropy", field: field)
		}
		return values
	}

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
		var inputFields: Set<String>
		let expectedFields: Set<String>
		if name == "tree_entropy_cheetah" {
			inputFields = [
				"input.tree_entropy.speed_tier", "input.tree_entropy.decoding_tier",
				"input.tree_entropy.extra_dc_precision",
				"input.tree_entropy.context_count",
				"input.tree_entropy.tokens",
			]
			expectedFields = [
				"entropy.tree_entropy.speed_tier",
				"entropy.tree_entropy.decoding_tier",
				"entropy.tree_entropy.extra_dc_precision",
				"entropy.tree_entropy.context_count",
				"entropy.tree_entropy.clustering",
				"entropy.tree_entropy.ans_strategy",
				"entropy.tree_entropy.lz77_method",
				"entropy.tree_entropy.uint_method",
				"entropy.tree_entropy.use_prefix_code",
				"entropy.tree_entropy.log_alpha_size",
				"entropy.tree_entropy.input_token_count",
				"entropy.tree_entropy.tokens",
				"entropy.tree_entropy.context_map",
				"entropy.tree_entropy.uint_configs",
				"entropy.tree_entropy.table_lengths",
				"entropy.tree_entropy.table_frequencies",
				"entropy.tree_entropy.table_reverse_maps",
				"entropy.tree_entropy.cost",
				"entropy.tree_entropy.bit_count", "entropy.tree_entropy.bytes",
			]
			let speed = try integers(input, "input.tree_entropy.speed_tier")
			let decoding = try integers(input, "input.tree_entropy.decoding_tier")
			let precision = try integers(input, "input.tree_entropy.extra_dc_precision")
			let contexts = try integers(input, "input.tree_entropy.context_count")
			let tokens = try integers(input, "input.tree_entropy.tokens")
			let encodedTokens = try integers(expected, "entropy.tree_entropy.tokens")
			let bitCount = try integers(expected, "entropy.tree_entropy.bit_count")
			let bytes = try integers(expected, "entropy.tree_entropy.bytes")
			guard speed == [6], decoding == [0], precision == [0], contexts == [6],
				tokens.count == 626, tokens == encodedTokens,
				try integers(expected, "entropy.tree_entropy.input_token_count")
					== [313],
				try integers(expected, "entropy.tree_entropy.context_count")
					== contexts,
				try integers(expected, "entropy.tree_entropy.speed_tier") == speed,
				try integers(expected, "entropy.tree_entropy.decoding_tier")
					== decoding,
				try integers(expected, "entropy.tree_entropy.extra_dc_precision")
					== precision,
				bitCount.count == 1, bitCount[0] > 0,
				bytes.count == Int((bitCount[0] + 7) / 8),
				bytes.allSatisfy({ (0...255).contains($0) })
			else { throw SemanticDumpError.unsupportedEntropyFixture(name) }
		} else if name.hasPrefix("ans_") {
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
		} else if name.hasPrefix("ac_tokens_") {
			inputFields = [
				"input.ac_tokens.width", "input.ac_tokens.height",
				"input.ac_tokens.strategy", "input.ac_tokens.dct8_order",
				"input.ac_tokens.channel_order", "input.ac_tokens.context_count",
				"input.ac_tokens.context_map", "input.ac_tokens.order",
				"input.ac_tokens.qdc", "input.ac_tokens.qf",
				"input.ac_tokens.channel0", "input.ac_tokens.channel1",
				"input.ac_tokens.channel2",
			]
			expectedFields = [
				"entropy.ac_tokens.context_count", "entropy.ac_tokens.contexts",
				"entropy.ac_tokens.token_count", "entropy.ac_tokens.values",
			]
			let width = try integers(input, "input.ac_tokens.width")
			let height = try integers(input, "input.ac_tokens.height")
			let strategy = try integers(input, "input.ac_tokens.strategy")
			let dct8Order = try integers(input, "input.ac_tokens.dct8_order")
			let channelOrder = try integers(input, "input.ac_tokens.channel_order")
			let contextCount = try integers(input, "input.ac_tokens.context_count")
			let contextMap = try integers(input, "input.ac_tokens.context_map")
			let order = try integers(input, "input.ac_tokens.order")
			let qdc = try integers(input, "input.ac_tokens.qdc")
			let qf = try integers(input, "input.ac_tokens.qf")
			var expectedTinyMap: [Int64] = []
			for category in [0, 2, 2] {
				expectedTinyMap.append(
					contentsOf: repeatElement(Int64(category), count: 13))
			}
			let expectedDefaultMap: [Int64] = [
				0, 1, 2, 2, 3, 3, 4, 5, 6, 6, 6, 6, 6,
				7, 8, 9, 9, 10, 11, 12, 13, 14, 14, 14, 14, 14,
				7, 8, 9, 9, 10, 11, 12, 13, 14, 14, 14, 14, 14,
			]
			let requiredContextCount: Int64 =
				name == "ac_tokens_tiny_map" ? 4 : 15
			let requiredMap =
				name == "ac_tokens_tiny_map" ? expectedTinyMap : expectedDefaultMap
			guard name == "ac_tokens_tiny_map" || name == "ac_tokens_default_map",
				width == [2], height == [2], strategy == [0], dct8Order == [0],
				channelOrder == [1, 0, 2], contextCount == [requiredContextCount],
				contextMap == requiredMap, order.count == 64, order[0] == 0,
				Set(order) == Set((0..<64).map(Int64.init)),
				qdc == [0, 0, 0, 0], qf == [1, 1, 1, 1]
			else { throw SemanticDumpError.unsupportedEntropyFixture(name) }
			for channel in 0..<3 {
				let coefficients = try integers(
					input, "input.ac_tokens.channel\(channel)")
				guard coefficients.count == 2 * 2 * 64,
					coefficients.allSatisfy({
						Int64(Int32.min)...Int64(Int32.max) ~= $0
					})
				else { throw SemanticDumpError.unsupportedEntropyFixture(name) }
			}
			let outputContextCount = try integers(
				expected, "entropy.ac_tokens.context_count")
			let contexts = try integers(expected, "entropy.ac_tokens.contexts")
			let tokenCount = try integers(expected, "entropy.ac_tokens.token_count")
			let values = try integers(expected, "entropy.ac_tokens.values")
			guard outputContextCount == contextCount, tokenCount.count == 1,
				tokenCount[0] > 0, contexts.count == Int(tokenCount[0]),
				values.count == contexts.count,
				contexts.allSatisfy({ (0...10_000).contains($0) }),
				values.allSatisfy({ (0...Int64(UInt32.max)).contains($0) })
			else { throw SemanticDumpError.unsupportedEntropyFixture(name) }
		} else if name == "modular_dc_gradient_rows" {
			var modularInputFields: Set<String> = [
				"input.modular.tree_kind", "input.modular.total_pixels",
				"input.modular.bitdepth", "input.modular.prevprop",
				"input.modular.context_offset", "input.modular.dc_group_count",
			]
			var modularExpectedFields = Set<String>()
			for group in 0..<2 {
				let prefix = "input.modular.group\(group)"
				modularInputFields.formUnion([
					"\(prefix).width", "\(prefix).height",
					"\(prefix).group_id", "\(prefix).channel_order",
					"\(prefix).channel0", "\(prefix).channel1",
					"\(prefix).channel2",
				])
				modularExpectedFields.formUnion([
					"entropy.modular.group\(group).bitdepth",
					"entropy.modular.group\(group).group_id",
					"entropy.modular.group\(group).height",
					"entropy.modular.group\(group).token_count",
					"entropy.modular.group\(group).tokens",
					"entropy.modular.group\(group).total_pixels",
					"entropy.modular.group\(group).tree_kind",
					"entropy.modular.group\(group).channel_order",
					"entropy.modular.group\(group).prevprop",
					"entropy.modular.group\(group).tree_node_count",
					"entropy.modular.group\(group).tree_nodes",
					"entropy.modular.group\(group).tree_tokens",
					"entropy.modular.group\(group).width",
				])
			}
			inputFields = modularInputFields
			expectedFields = modularExpectedFields
			let treeKind = try integers(input, "input.modular.tree_kind")
			let totalPixels = try integers(input, "input.modular.total_pixels")
			let bitdepth = try integers(input, "input.modular.bitdepth")
			let prevprop = try integers(input, "input.modular.prevprop")
			let contextOffset = try integers(input, "input.modular.context_offset")
			let groupCount = try integers(input, "input.modular.dc_group_count")
			guard treeKind == [6], totalPixels == [8193], bitdepth == [8],
				prevprop == [0], contextOffset == [11], groupCount == [2]
			else { throw SemanticDumpError.unsupportedEntropyFixture(name) }
			for group in 0..<2 {
				let prefix = "input.modular.group\(group)"
				let width = try integers(input, "\(prefix).width")
				let height = try integers(input, "\(prefix).height")
				let groupID = try integers(input, "\(prefix).group_id")
				let order = try integers(input, "\(prefix).channel_order")
				let dimensions =
					width.count == 1 && height.count == 1
					&& (1...32).contains(width[0])
					&& (1...32).contains(height[0])
				let expectedGroupID = Int64(3 + group)
				guard dimensions, groupID == [expectedGroupID],
					order == [1, 0, 2]
				else { throw SemanticDumpError.unsupportedEntropyFixture(name) }
				for channel in 0..<3 {
					let samples = try integers(
						input, "\(prefix).channel\(channel)")
					guard samples.count == Int(width[0] * height[0]),
						samples.allSatisfy({
							Int64(Int16.min)...Int64(Int16.max) ~= $0
						})
					else {
						throw SemanticDumpError.unsupportedEntropyFixture(
							name)
					}
				}
				let outputPrefix = "entropy.modular.group\(group)"
				let outputTreeKind = try integers(
					expected, "\(outputPrefix).tree_kind")
				let outputPixels = try integers(
					expected, "\(outputPrefix).total_pixels")
				let outputBitdepth = try integers(
					expected, "\(outputPrefix).bitdepth")
				let outputPrevprop = try integers(
					expected, "\(outputPrefix).prevprop")
				let outputGroupID = try integers(
					expected, "\(outputPrefix).group_id")
				let outputWidth = try integers(expected, "\(outputPrefix).width")
				let outputHeight = try integers(expected, "\(outputPrefix).height")
				let outputOrder = try integers(
					expected, "\(outputPrefix).channel_order")
				let tokenCount = try integers(
					expected, "\(outputPrefix).token_count")
				let tokens = try integers(expected, "\(outputPrefix).tokens")
				let expectedCount = width[0] * height[0] * 3
				guard outputTreeKind == treeKind, outputPixels == totalPixels,
					outputBitdepth == bitdepth, outputPrevprop == prevprop,
					outputGroupID == groupID, outputWidth == width,
					outputHeight == height, outputOrder == order,
					tokenCount == [expectedCount],
					tokens.count == Int(expectedCount * 2),
					tokens.enumerated().allSatisfy({ index, value in
						index.isMultiple(of: 2)
							? (0...33).contains(value)
							: (0...Int64(UInt32.max)).contains(value)
					})
				else { throw SemanticDumpError.unsupportedEntropyFixture(name) }
			}
		} else if name == "modular_dc_wp_fixed_8192" {
			inputFields = [
				"input.modular.tree_kind", "input.modular.total_pixels",
				"input.modular.bitdepth", "input.modular.prevprop",
				"input.modular.context_offset", "input.modular.predictor",
				"input.modular.wp_tree_mode", "input.modular.dc_group_count",
				"input.modular.group0.width", "input.modular.group0.height",
				"input.modular.group0.group_id",
				"input.modular.group0.channel_order",
				"input.modular.group0.channel0", "input.modular.group0.channel1",
				"input.modular.group0.channel2",
			]
			expectedFields = [
				"entropy.modular.bitdepth", "entropy.modular.channel_order",
				"entropy.modular.group_id", "entropy.modular.height",
				"entropy.modular.prevprop", "entropy.modular.token_count",
				"entropy.modular.tokens", "entropy.modular.total_pixels",
				"entropy.modular.tree_kind", "entropy.modular.tree_node_count",
				"entropy.modular.tree_nodes", "entropy.modular.tree_tokens",
				"entropy.modular.width",
			]
			let treeKind = try integers(input, "input.modular.tree_kind")
			let totalPixels = try integers(input, "input.modular.total_pixels")
			let bitdepth = try integers(input, "input.modular.bitdepth")
			let prevprop = try integers(input, "input.modular.prevprop")
			let contextOffset = try integers(input, "input.modular.context_offset")
			let predictor = try integers(input, "input.modular.predictor")
			let treeMode = try integers(input, "input.modular.wp_tree_mode")
			let groupCount = try integers(input, "input.modular.dc_group_count")
			let width = try integers(input, "input.modular.group0.width")
			let height = try integers(input, "input.modular.group0.height")
			let groupID = try integers(input, "input.modular.group0.group_id")
			let order = try integers(input, "input.modular.group0.channel_order")
			guard treeKind == [5], totalPixels == [8192], bitdepth == [8],
				prevprop == [0], contextOffset == [11], predictor == [6],
				treeMode == [1], groupCount == [1], width == [3], height == [2],
				groupID == [3], order == [1, 0, 2]
			else { throw SemanticDumpError.unsupportedEntropyFixture(name) }
			for channel in 0..<3 {
				let values = try integers(
					input, "input.modular.group0.channel\(channel)")
				guard values.count == 6,
					values.allSatisfy({
						Int64(Int16.min)...Int64(Int16.max) ~= $0
					})
				else { throw SemanticDumpError.unsupportedEntropyFixture(name) }
			}
			let tokenCount = try integers(expected, "entropy.modular.token_count")
			let tokens = try integers(expected, "entropy.modular.tokens")
			let nodeCount = try integers(expected, "entropy.modular.tree_node_count")
			let nodes = try integers(expected, "entropy.modular.tree_nodes")
			let treeTokens = try integers(expected, "entropy.modular.tree_tokens")
			guard
				try integers(expected, "entropy.modular.tree_kind") == treeKind,
				try integers(expected, "entropy.modular.total_pixels")
					== totalPixels,
				try integers(expected, "entropy.modular.bitdepth") == bitdepth,
				try integers(expected, "entropy.modular.prevprop") == prevprop,
				try integers(expected, "entropy.modular.group_id") == groupID,
				try integers(expected, "entropy.modular.width") == width,
				try integers(expected, "entropy.modular.height") == height,
				try integers(expected, "entropy.modular.channel_order") == order,
				tokenCount == [18], tokens.count == 36,
				nodeCount == [7], nodes.count == 49, treeTokens.count == 52,
				tokens.enumerated().allSatisfy({ index, value in
					index.isMultiple(of: 2)
						? (0...33).contains(value)
						: (0...Int64(UInt32.max)).contains(value)
				}),
				treeTokens.allSatisfy({ (0...Int64(UInt32.max)).contains($0) })
			else { throw SemanticDumpError.unsupportedEntropyFixture(name) }
		} else if name == "acmeta_channels_16x16"
			|| name == "acmeta_channels_24x24"
		{
			inputFields = [
				"input.ac_metadata.width", "input.ac_metadata.height",
				"input.ac_metadata.ytox", "input.ac_metadata.ytob",
				"input.ac_metadata.acs", "input.ac_metadata.raw_quant_field",
				"input.ac_metadata.epf",
			]
			expectedFields = [
				"entropy.ac_metadata.width", "entropy.ac_metadata.height",
				"entropy.ac_metadata.total_pixels",
				"entropy.ac_metadata.tree_node_count",
				"entropy.ac_metadata.tree_nodes",
				"entropy.ac_metadata.cfl_ytox.tokens",
				"entropy.ac_metadata.cfl_ytob.tokens",
				"entropy.ac_metadata.acs.tokens",
				"entropy.ac_metadata.quant_field.tokens",
				"entropy.ac_metadata.epf.tokens",
			]
			let width = try integers(input, "input.ac_metadata.width")
			let height = try integers(input, "input.ac_metadata.height")
			let expectedSize: Int64 = name == "acmeta_channels_16x16" ? 16 : 24
			guard width == [expectedSize], height == [expectedSize] else {
				throw SemanticDumpError.unsupportedEntropyFixture(name)
			}
			let blockCount = Int(width[0] * height[0])
			let mapCount = Int(((width[0] + 7) / 8) * ((height[0] + 7) / 8))
			let maps = [
				try integers(input, "input.ac_metadata.ytox"),
				try integers(input, "input.ac_metadata.ytob"),
			]
			let acs = try integers(input, "input.ac_metadata.acs")
			let qf = try integers(input, "input.ac_metadata.raw_quant_field")
			let epf = try integers(input, "input.ac_metadata.epf")
			guard maps.allSatisfy({ $0.count == mapCount }),
				maps.flatMap({ $0 }).allSatisfy({ (-128...127).contains($0) }),
				acs.count == blockCount, acs.allSatisfy({ $0 == 0 }),
				qf.count == blockCount, qf.allSatisfy({ (1...255).contains($0) }),
				epf.count == blockCount, epf.allSatisfy({ $0 == 4 })
			else { throw SemanticDumpError.unsupportedEntropyFixture(name) }
			let totalPixels = mapCount * 2 + blockCount * 3
			let outputNodeCount = try integers(
				expected, "entropy.ac_metadata.tree_node_count")
			let outputNodes = try integers(expected, "entropy.ac_metadata.tree_nodes")
			guard
				try integers(expected, "entropy.ac_metadata.width") == width,
				try integers(expected, "entropy.ac_metadata.height") == height,
				try integers(expected, "entropy.ac_metadata.total_pixels") == [
					Int64(totalPixels)
				],
				outputNodeCount == [totalPixels < 1024 ? 1 : 27],
				outputNodes.count == Int(outputNodeCount[0] * 7)
			else { throw SemanticDumpError.unsupportedEntropyFixture(name) }
			let channelFields = [
				("cfl_ytox", mapCount), ("cfl_ytob", mapCount),
				("acs", blockCount), ("quant_field", blockCount),
				("epf", blockCount),
			]
			for (channel, count) in channelFields {
				let tokens = try integers(
					expected, "entropy.ac_metadata.\(channel).tokens")
				guard tokens.count == count * 2,
					tokens.enumerated().allSatisfy({ index, value in
						index.isMultiple(of: 2)
							? (0...64).contains(value)
							: (0...Int64(UInt32.max)).contains(value)
					})
				else { throw SemanticDumpError.unsupportedEntropyFixture(name) }
			}
		} else if name == "tree_merged_multidc_2057x257" {
			inputFields = [
				"input.tree_merged.source_sha256", "input.tree_merged.crop_size",
				"input.tree_merged.effort", "input.tree_merged.distance_milli",
				"input.tree_merged.output_mode", "input.tree_merged.buffering",
			]
			expectedFields = [
				"entropy.tree_merged.group_count",
				"entropy.tree_merged.dc_group_count",
				"entropy.tree_merged.node_count", "entropy.tree_merged.nodes",
			]
			let sourceHash = try integers(input, "input.tree_merged.source_sha256")
			let cropSize = try integers(input, "input.tree_merged.crop_size")
			let effort = try integers(input, "input.tree_merged.effort")
			let distance = try integers(input, "input.tree_merged.distance_milli")
			let outputMode = try integers(input, "input.tree_merged.output_mode")
			let buffering = try integers(input, "input.tree_merged.buffering")
			let groups = try integers(expected, "entropy.tree_merged.group_count")
			let dcGroups = try integers(expected, "entropy.tree_merged.dc_group_count")
			let nodeCount = try integers(expected, "entropy.tree_merged.node_count")
			let nodes = try integers(expected, "entropy.tree_merged.nodes")
			guard
				sourceHash.count == 32,
				sourceHash.allSatisfy({ (0...255).contains($0) }),
				cropSize == [2057, 257], effort == [4], distance == [1000],
				outputMode == [2], buffering == [0], groups == [18],
				dcGroups == [2], nodeCount == [95], nodes.count == 95 * 7,
				Array(nodes.prefix(7)) == [1, 4, 1, 2, 0, 0, 1],
				stride(from: 0, to: nodes.count, by: 7).allSatisfy({ index in
					let node = Array(nodes[index..<(index + 7)])
					return node[0] >= -1 && node[6] > 0
						&& (node[0] == -1
							|| (node[2] > 0 && node[2] < nodeCount[0]
								&& node[3] > 0
								&& node[3] < nodeCount[0]))
				})
			else { throw SemanticDumpError.unsupportedEntropyFixture(name) }
		} else if name.hasPrefix("tree_gradient_fixed_")
			|| name.hasPrefix("tree_wp_fixed_")
			|| name.hasPrefix("tree_acmeta_")
		{
			inputFields = [
				"input.tree.kind", "input.tree.total_pixels", "input.tree.bitdepth",
				"input.tree.prevprop", "input.tree.dc_group_count",
				"input.tree.projection_root",
			]
			if name.hasPrefix("tree_acmeta_") {
				inputFields.insert("input.tree.channel_areas")
			}
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
			let channelAreas =
				name.hasPrefix("tree_acmeta_")
				? try integers(input, "input.tree.channel_areas") : []
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
				case "tree_wp_fixed_8192_dc1": (8192, 1)
				case "tree_wp_fixed_8193_dc2": (8193, 2)
				case "tree_acmeta_below_1024": (280, 1)
				case "tree_acmeta_above_1024": (1120, 1)
				default: nil
				}
			let expectedKind: Int64 =
				name.hasPrefix("tree_wp_fixed_")
				? 5 : (name.hasPrefix("tree_acmeta_") ? 4 : 6)
			let expectedAreas: [Int64] =
				name == "tree_acmeta_below_1024"
				? [4, 4, 16, 256]
				: (name == "tree_acmeta_above_1024" ? [16, 16, 64, 1024] : [])
			guard kind == [expectedKind], totalPixels.count == 1,
				caseConfig.map({ totalPixels[0] == $0.0 }) == true, bitdepth == [8],
				prevprop == [0], dcGroupCount.count == 1,
				(1...2).contains(dcGroupCount[0]),
				projectionRoot == (name.hasPrefix("tree_acmeta_") ? [1] : [2]),
				caseConfig.map({ totalPixels[0] == $0.0 && dcGroupCount[0] == $0.1 }
				)
					== true,
				channelAreas == expectedAreas,
				channelAreas.isEmpty || channelAreas.reduce(0, +) == totalPixels[0],
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
		} else if name == "coefficient_sampled_group_boundary" {
			inputFields = [
				"input.coefficient_sampling.blocks",
				"input.coefficient_sampling.speed_tier",
				"input.coefficient_sampling.zero_positions",
				"input.coefficient_sampling.first_exception",
			]
			expectedFields = [
				"entropy.coefficient_sampling.blocks",
				"entropy.coefficient_sampling.group_count",
				"entropy.coefficient_sampling.order",
				"entropy.coefficient_sampling.rejected_blocks",
				"entropy.coefficient_sampling.selected_blocks",
				"entropy.coefficient_sampling.selected_counts",
				"entropy.coefficient_sampling.zero_false",
				"entropy.coefficient_sampling.zero_true",
			]
			let blocks = try integers(input, "input.coefficient_sampling.blocks")
			let speed = try integers(input, "input.coefficient_sampling.speed_tier")
			let zeros = try integers(input, "input.coefficient_sampling.zero_positions")
			let exception = try integers(
				input, "input.coefficient_sampling.first_exception")
			let outputBlocks = try integers(
				expected, "entropy.coefficient_sampling.blocks")
			let groups = try integers(
				expected, "entropy.coefficient_sampling.group_count")
			let order = try integers(expected, "entropy.coefficient_sampling.order")
			let rejected = try integers(
				expected, "entropy.coefficient_sampling.rejected_blocks")
			let selected = try integers(
				expected, "entropy.coefficient_sampling.selected_blocks")
			let selectedCounts = try integers(
				expected, "entropy.coefficient_sampling.selected_counts")
			let zeroFalse = try integers(
				expected, "entropy.coefficient_sampling.zero_false")
			let zeroTrue = try integers(
				expected, "entropy.coefficient_sampling.zero_true")
			guard blocks == [33, 32] else {
				throw SemanticDumpError.unsupportedEntropyFixture(name)
			}
			let groupCount = ((blocks[0] + 31) / 32) * ((blocks[1] + 31) / 32)
			guard speed == [6], zeros == [1, 8],
				exception == [0, 0, 8], outputBlocks == blocks,
				groups == [groupCount], order.count == 64,
				Set(order) == Set((0..<64).map(Int64.init)),
				rejected == [512], selected == [544], selectedCounts == [544, 543],
				zeroTrue == [3261], zeroFalse == [101187],
				selected[0] + rejected[0] == blocks[0] * blocks[1],
				zeroTrue[0] + zeroFalse[0] == selected[0] * 3 * 64,
				zeroTrue[0] == 3 * (selectedCounts[0] + selectedCounts[1])
			else { throw SemanticDumpError.unsupportedEntropyFixture(name) }
		} else if name == "coefficient_natural_dct8" {
			inputFields = ["input.coefficient_natural.strategy"]
			expectedFields = ["entropy.coefficient_natural.order"]
			let strategy = try integers(input, "input.coefficient_natural.strategy")
			let order = try integers(expected, "entropy.coefficient_natural.order")
			guard strategy == [0], order.count == 64,
				Set(order) == Set((0..<64).map(Int64.init))
			else { throw SemanticDumpError.unsupportedEntropyFixture(name) }
		} else if name == "stream_shared_ans" || name == "stream_shared_prefix" {
			inputFields = Set(
				[
					"input.streams.context_map", "input.streams.lengths",
					"input.streams.tokens",
				]
					+ (name == "stream_shared_ans"
						? [
							"input.streams.log_alpha_size",
							"input.streams.frequencies",
						] : []))
			expectedFields = [
				"entropy.streams.bit_counts", "entropy.streams.bytes",
				"entropy.streams.code_bit_count", "entropy.streams.code_bytes",
				"entropy.streams.code_kind", "entropy.streams.count",
				"entropy.streams.lengths", "entropy.streams.tokens",
				"entropy.streams.transmitted_context_count",
			]
			let contextMap = try integers(input, "input.streams.context_map")
			let lengths = try integers(input, "input.streams.lengths")
			let tokens = try integers(input, "input.streams.tokens")
			let codeKind = try integers(expected, "entropy.streams.code_kind")
			let contextCount = try integers(
				expected, "entropy.streams.transmitted_context_count")
			let outputLengths = try integers(expected, "entropy.streams.lengths")
			let outputTokens = try integers(expected, "entropy.streams.tokens")
			let codeBits = try integers(expected, "entropy.streams.code_bit_count")
			let codeBytes = try integers(expected, "entropy.streams.code_bytes")
			let bitCounts = try integers(expected, "entropy.streams.bit_counts")
			let streamBytes = try integers(expected, "entropy.streams.bytes")
			guard lengths == [8, 8], tokens.count == 32 else {
				throw SemanticDumpError.unsupportedEntropyFixture(name)
			}
			var tokenRecords: [Int64] = []
			var tokenOffset = 0
			for (index, length) in lengths.enumerated() {
				tokenRecords.append(contentsOf: [Int64(index), length])
				let valueCount = Int(length) * 2
				guard valueCount <= tokens.count - tokenOffset else {
					throw SemanticDumpError.unsupportedEntropyFixture(name)
				}
				tokenRecords.append(
					contentsOf: tokens[tokenOffset..<(tokenOffset + valueCount)]
				)
				tokenOffset += valueCount
			}
			let codeByteCount =
				codeBits.count == 1 && codeBits[0] >= 0
				? codeBits[0] / 8 + (codeBits[0].isMultiple(of: 8) ? 0 : 1) : -1
			let streamByteCount = bitCounts.reduce(Int64(0)) { sum, value in
				value >= 0
					? sum + value / 8 + (value.isMultiple(of: 8) ? 0 : 1) : -1
			}
			let validCodeInput: Bool
			if name == "stream_shared_ans" {
				let logAlpha = try integers(input, "input.streams.log_alpha_size")
				let frequencies = try integers(input, "input.streams.frequencies")
				validCodeInput =
					logAlpha == [6] && frequencies.count == 2
					&& checkedSum(
						frequencies, limit: Int64(ANSConstants.tabSize))
						== Int64(ANSConstants.tabSize)
			} else {
				validCodeInput = true
			}
			guard contextMap == [0, 0, 0, 0], validCodeInput,
				tokens.enumerated().allSatisfy({ index, value in
					index.isMultiple(of: 2)
						? value == 0 : (0...1).contains(value)
				}), tokenOffset == tokens.count,
				codeKind == [name == "stream_shared_ans" ? 1 : 0],
				contextCount == [4], outputLengths == lengths,
				outputTokens == tokenRecords, codeBits.count == 1,
				codeByteCount >= 0,
				codeBytes.count == Int(codeByteCount),
				bitCounts == (name == "stream_shared_ans" ? [32, 32] : [8, 8]),
				streamBytes.count == streamByteCount
			else { throw SemanticDumpError.unsupportedEntropyFixture(name) }
		} else if name.hasPrefix("coefficient_sort_") {
			guard
				["coefficient_sort_bounded", "coefficient_sort_boundary"].contains(
					name)
			else { throw SemanticDumpError.unsupportedEntropyFixture(name) }
			var requiredInputFields: Set<String> = [
				"input.coefficient_order.blocks", "input.coefficient_order.counts",
			]
			var requiredExpectedFields: Set<String> = [
				"entropy.coefficient_order.counts",
				"entropy.coefficient_order.reference_order",
			]
			if name == "coefficient_sort_boundary" {
				requiredInputFields.formUnion([
					"input.coefficient_sampling.blocks",
					"input.coefficient_sampling.speed_tier",
					"input.coefficient_sampling.zero_positions",
					"input.coefficient_sampling.first_exception",
				])
				requiredExpectedFields.formUnion([
					"entropy.coefficient_order.sampled_blocks",
					"entropy.coefficient_order.sampled_counts",
					"entropy.coefficient_order.sampled_order",
				])
			}
			inputFields = requiredInputFields
			expectedFields = requiredExpectedFields
			let blocks = try integers(input, "input.coefficient_order.blocks")
			let counts = try integers(input, "input.coefficient_order.counts")
			let sampleDimensions =
				name == "coefficient_sort_boundary"
				? try integers(input, "input.coefficient_sampling.blocks")
				: nil
			let sampleSpeed =
				name == "coefficient_sort_boundary"
				? try integers(input, "input.coefficient_sampling.speed_tier") : nil
			let sampleZeros =
				name == "coefficient_sort_boundary"
				? try integers(input, "input.coefficient_sampling.zero_positions")
				: nil
			let sampleException =
				name == "coefficient_sort_boundary"
				? try integers(input, "input.coefficient_sampling.first_exception")
				: nil
			let outputCounts = try integers(
				expected, "entropy.coefficient_order.counts")
			let order = try integers(
				expected, "entropy.coefficient_order.reference_order")
			let maximum: Int64 =
				name == "coefficient_sort_boundary"
				? 4_194_312 : (1 << 22) - 1
			guard counts.count == 64, counts.allSatisfy({ (0...maximum).contains($0) }),
				blocks == [max(1, counts.max() ?? 0)], outputCounts == counts,
				order.count == 64, Set(order) == Set((0..<64).map(Int64.init))
			else { throw SemanticDumpError.unsupportedEntropyFixture(name) }
			if name == "coefficient_sort_bounded" {
				guard
					[7, 8, 15, 16, 23, 24, 31, 32, maximum].allSatisfy(
						{ counts.contains($0) })
				else { throw SemanticDumpError.unsupportedEntropyFixture(name) }
			} else if name == "coefficient_sort_boundary" {
				let observedBlocks = try integers(
					expected, "entropy.coefficient_order.sampled_blocks")
				let observedCounts = try integers(
					expected, "entropy.coefficient_order.sampled_counts")
				let sampledOrder = try integers(
					expected, "entropy.coefficient_order.sampled_order")
				guard counts[1] == 4_194_312, counts[8] == 4_194_311,
					sampleDimensions == [8_392_231, 1], sampleSpeed == [6],
					sampleZeros == [1, 8], sampleException == [0, 0, 8],
					order.suffix(2) == [1, 8],
					observedBlocks == [4_194_312],
					observedCounts == [4_194_312, 4_194_311],
					sampledOrder == order
				else { throw SemanticDumpError.unsupportedEntropyFixture(name) }
			}
		} else if name == "hybrid_uint_4_2_0" {
			inputFields = ["input.uint.config", "input.uint.values"]
			expectedFields = [
				"entropy.uint.tokens", "entropy.uint.bit_counts",
				"entropy.uint.bits",
			]
			let config = try integers(input, "input.uint.config")
			let values = try integers(input, "input.uint.values")
			let tokens = try integers(expected, "entropy.uint.tokens")
			let bitCounts = try integers(expected, "entropy.uint.bit_counts")
			let bits = try integers(expected, "entropy.uint.bits")
			guard config == [4, 2, 0], !values.isEmpty,
				values.count == tokens.count, values.count == bitCounts.count,
				values.count == bits.count,
				values.allSatisfy({ (0...Int64(UInt32.max)).contains($0) }),
				tokens.allSatisfy({ (0...Int64(UInt32.max)).contains($0) }),
				bitCounts.allSatisfy({ (0...32).contains($0) }),
				bits.allSatisfy({ (0...Int64(UInt32.max)).contains($0) })
			else { throw SemanticDumpError.unsupportedEntropyFixture(name) }
		} else if name == "pack_signed_full_reference" {
			inputFields = ["input.signed.values"]
			expectedFields = ["entropy.signed.values"]
			let values = try integers(input, "input.signed.values")
			let packed = try integers(expected, "entropy.signed.values")
			guard !values.isEmpty, values.count == packed.count,
				values.allSatisfy({ Int64(Int32.min)...Int64(Int32.max) ~= $0 }),
				packed.allSatisfy({ (0...Int64(UInt32.max)).contains($0) })
			else { throw SemanticDumpError.unsupportedEntropyFixture(name) }
		} else if name == "huffman_tree_full_reference" {
			inputFields = [
				"input.huffman.tree_limit", "input.huffman.lengths",
				"input.huffman.counts",
			]
			expectedFields = [
				"entropy.huffman.lengths", "entropy.huffman.depths",
			]
			let limit = try integers(input, "input.huffman.tree_limit")
			let lengths = try integers(input, "input.huffman.lengths")
			let counts = try integers(input, "input.huffman.counts")
			let outputLengths = try integers(
				expected, "entropy.huffman.lengths")
			let depths = try integers(expected, "entropy.huffman.depths")
			guard limit == [15], !lengths.isEmpty, lengths.count <= 16,
				lengths.allSatisfy({ (1...256).contains($0) }),
				checkedSum(lengths, limit: Int64.max) == Int64(counts.count),
				counts.allSatisfy({ (0...Int64(UInt32.max)).contains($0) }),
				outputLengths == lengths, depths.count == counts.count
			else { throw SemanticDumpError.unsupportedEntropyFixture(name) }
			var offset = 0
			for length in lengths {
				let end = offset + Int(length)
				let histogram = counts[offset..<end]
				let tree = depths[offset..<end]
				let active = histogram.filter { $0 > 0 }.count
				guard active > 0, active <= (1 << Int(limit[0])),
					histogram.indices.allSatisfy({ index in
						histogram[index] == 0
							? tree[index] == 0
							: (1...limit[0]).contains(tree[index])
					})
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
