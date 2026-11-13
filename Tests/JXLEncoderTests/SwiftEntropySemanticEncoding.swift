@testable import JXLEncoder

enum SwiftEntropySemanticEncoding {
	private struct TreeNode {
		let property: Int
		let splitValue: Int32
		let left: Int
		let right: Int
		let predictor: Int
		let offset: Int64
		let multiplier: UInt32

		var fields: [Int64] {
			[
				Int64(property), Int64(splitValue), Int64(left), Int64(right),
				Int64(predictor), offset, Int64(multiplier),
			]
		}
	}

	private static func decodeTree(_ tokens: [Token]) -> ([[Int64]], [[Token]]) {
		var nodes: [TreeNode] = []
		var chunks: [[Token]] = []
		var index = 0
		var toDecode = 1
		var leafCount = 0
		while toDecode > 0 {
			toDecode -= 1
			let start = index
			let property = Int(tokens[index].value) - 1
			index += 1
			if property == -1 {
				let predictor = Int(tokens[index].value)
				let packedOffset = tokens[index + 1].value
				let offset = Int64(
					Int32(
						bitPattern: (packedOffset >> 1)
							^ (0 &- (packedOffset & 1))))
				let multiplierLog = Int(tokens[index + 2].value)
				let multiplier = (tokens[index + 3].value + 1) << multiplierLog
				index += 4
				nodes.append(
					TreeNode(
						property: -1, splitValue: 0, left: leafCount,
						right: 0,
						predictor: predictor, offset: offset,
						multiplier: multiplier))
				leafCount += 1
			} else {
				let packed = tokens[index].value
				let splitValue = Int32(
					bitPattern: (packed >> 1) ^ (0 &- (packed & 1)))
				index += 1
				nodes.append(
					TreeNode(
						property: property, splitValue: splitValue,
						left: nodes.count + toDecode + 1,
						right: nodes.count + toDecode + 2,
						predictor: 0, offset: 0, multiplier: 1))
				toDecode += 2
			}
			chunks.append(Array(tokens[start..<index]))
		}
		precondition(index == tokens.count)
		return (nodes.map(\.fields), chunks)
	}

	static func histogram(counts: [Int], logAlphaSize: Int) -> SemanticDump {
		precondition((5...8).contains(logAlphaSize))
		precondition(counts.count <= 256)
		precondition(((counts.count + 15) / 16) * 16 <= (1 << logAlphaSize))
		precondition(counts.allSatisfy { $0 >= 0 && $0 <= Int(UInt32.max) })
		precondition(counts.reduce(UInt64(0)) { $0 + UInt64($1) } <= UInt64(UInt32.max))
		let normalized = ANSHistogramNormalizer.normalize(counts.map(UInt32.init))
		let alphabetSize = ANSHistogramWriter.alphabetSize(for: normalized)
		let symbols =
			alphabetSize == 0
			? []
			: ANSInfoTable.build(
				distribution: normalized, alphabetSize: alphabetSize,
				logAlphaSize: logAlphaSize)
		var writer = BitWriter()
		ANSHistogramWriter.write(counts: normalized, writer: &writer)
		var dump = SemanticDump()
		dump.record(
			"entropy.histogram.normalized",
			.integers(Array(normalized.prefix(alphabetSize)).map(Int64.init)))
		let method = normalized.filter { $0 > 0 }.count <= 2 ? 1 : 2
		dump.record("entropy.histogram.serialized_method", .integers([Int64(method)]))
		dump.record(
			"entropy.histogram.serialized_shift",
			.integers([Int64(method == 1 ? -1 : ANSConstants.logTabSize - 1)]))
		dump.record("entropy.histogram.alphabet_size", .integers([Int64(alphabetSize)]))
		dump.record("entropy.histogram.log_alpha_size", .integers([Int64(logAlphaSize)]))
		dump.record("entropy.histogram.freqs", .integers(symbols.map { Int64($0.freq) }))
		dump.record(
			"entropy.histogram.reverse_map",
			.integers(symbols.flatMap { $0.reverseMap.map(Int64.init) }))
		dump.record("entropy.histogram.bit_count", .integers([Int64(writer.bitsWritten)]))
		dump.record("entropy.histogram.bytes", .integers(writer.bytes.map(Int64.init)))
		return dump
	}

	static func clusters(histograms: [Histogram], limit: Int? = nil) -> SemanticDump {
		if let limit { precondition(limit > 0) }
		let result =
			limit.map {
				HistogramCluster.cluster(histograms, limit: $0)
			} ?? HistogramCluster.cluster(histograms)
		var dump = SemanticDump()
		dump.record("entropy.clusters.map", .integers(result.contextMap.map(Int64.init)))
		dump.record("entropy.clusters.count", .integers([Int64(result.clusters.count)]))
		let lengths = result.clusters.map { cluster in
			(cluster.counts.lastIndex(where: { $0 > 0 }) ?? -1) + 1
		}
		dump.record(
			"entropy.clusters.alphabet_lengths",
			.integers(lengths.map(Int64.init)))
		dump.record(
			"entropy.clusters.total_counts",
			.integers(result.clusters.map { Int64($0.totalCount) }))
		dump.record(
			"entropy.clusters.histogram_counts",
			.integers(
				zip(result.clusters, lengths).flatMap { cluster, length in
					cluster.counts.prefix(length).map(Int64.init)
				}))
		dump.record(
			"entropy.clusters.input_total_count",
			.integers([Int64(histograms.reduce(0) { $0 + $1.totalCount })]))
		dump.record(
			"entropy.clusters.output_total_count",
			.integers([Int64(result.clusters.reduce(0) { $0 + $1.totalCount })]))
		return dump
	}

	static func contextMap(
		entries: [UInt8], numHistograms: Int, allowANS: Bool
	) throws -> SemanticDump {
		guard (1...255).contains(numHistograms),
			!entries.isEmpty, entries.count <= 1_000_000,
			entries.allSatisfy({ Int($0) < numHistograms })
		else {
			throw SemanticDumpError.unimplemented
		}
		var writer = BitWriter()
		EntropyCodeWriter.writeContextMapEntries(
			entries, allowANS: allowANS, writer: &writer)
		var dump = SemanticDump()
		dump.record("entropy.context_map.entries", .integers(entries.map(Int64.init)))
		dump.record("entropy.context_map.num_histograms", .integers([Int64(numHistograms)]))
		let simple = entries.max() == 0
		let usePrefix =
			simple
			? -1
			: (allowANS && entries.count >= SectionOptimizer.ansMinimumTokens ? 0 : 1)
		dump.record("entropy.context_map.simple", .integers([simple ? 1 : 0]))
		dump.record("entropy.context_map.entry_bits", .integers([simple ? 0 : -1]))
		dump.record("entropy.context_map.use_mtf", .integers([0]))
		dump.record("entropy.context_map.use_prefix_code", .integers([Int64(usePrefix)]))
		dump.record(
			"entropy.context_map.token_count",
			.integers([-1]))
		dump.record(
			"entropy.context_map.token_count_status",
			.integers([simple ? 0 : 3]))
		dump.record("entropy.context_map.bit_count", .integers([Int64(writer.bitsWritten)]))
		dump.record("entropy.context_map.bytes", .integers(writer.bytes.map(Int64.init)))
		return dump
	}

	static func tree(dcGroupCount: Int) -> SemanticDump {
		precondition(dcGroupCount > 0)
		var tokens = ContextTree.staticTokens
		tokens[1] = Token(
			context: tokens[1].context, value: packSigned(Int32(1 + dcGroupCount)))
		let (nodes, _) = decodeTree(tokens)
		let root = 2
		let fullTokens = tokens.flatMap { [Int64($0.context), Int64($0.value)] }
		let projected = projectedTree(fullTokens: fullTokens, root: root)
		var dump = SemanticDump()
		dump.record("entropy.tree.dc_group_count", .integers([Int64(dcGroupCount)]))
		for field in ["node_count", "nodes", "token_count", "tokens"] {
			if let value = projected.fields["entropy.tree.\(field)"] {
				dump.record("entropy.tree.\(field)", value)
			}
		}
		dump.record("entropy.tree.full_token_count", .integers([Int64(tokens.count)]))
		dump.record(
			"entropy.tree.full_tokens",
			.integers(tokens.flatMap { [Int64($0.context), Int64($0.value)] }))
		dump.record("entropy.tree.full_node_count", .integers([Int64(nodes.count)]))
		dump.record("entropy.tree.full_nodes", .integers(nodes.flatMap { $0 }))
		dump.record("entropy.tree.component_root", .integers([Int64(root)]))
		return dump
	}

	static func projectedTree(fullTokens: [Int64], root: Int) -> SemanticDump {
		precondition(fullTokens.count.isMultiple(of: 2))
		let tokens = stride(from: 0, to: fullTokens.count, by: 2).map {
			Token(context: UInt32(fullTokens[$0]), value: UInt32(fullTokens[$0 + 1]))
		}
		let (nodes, chunks) = decodeTree(tokens)
		precondition(nodes.indices.contains(root))
		var subtree = [root]
		var cursor = 0
		while cursor < subtree.count {
			let fields = nodes[subtree[cursor]]
			if fields[0] >= 0 {
				subtree.append(Int(fields[2]))
				subtree.append(Int(fields[3]))
			}
			cursor += 1
		}
		let rebase = Dictionary(uniqueKeysWithValues: subtree.enumerated().map { ($1, $0) })
		var leafCount = 0
		let projectedNodes = subtree.flatMap { original -> [Int64] in
			var fields = nodes[original]
			if fields[0] >= 0 {
				fields[2] = Int64(rebase[Int(fields[2])]!)
				fields[3] = Int64(rebase[Int(fields[3])]!)
			} else {
				fields[2] = Int64(leafCount)
				leafCount += 1
			}
			return fields
		}
		let projectedTokens = subtree.flatMap { chunks[$0] }.flatMap {
			[Int64($0.context), Int64($0.value)]
		}
		var dump = SemanticDump()
		dump.record("entropy.tree.node_count", .integers([Int64(subtree.count)]))
		dump.record("entropy.tree.nodes", .integers(projectedNodes))
		dump.record(
			"entropy.tree.token_count", .integers([Int64(projectedTokens.count / 2)]))
		dump.record("entropy.tree.tokens", .integers(projectedTokens))
		return dump
	}

	static func treeEntropy(
		dcGroupCount: Int, tokens override: [Token]? = nil,
		contextMapOverride: [UInt8]? = nil
	) -> SemanticDump {
		var tokens = override ?? ContextTree.staticTokens
		if override == nil {
			tokens[1] = Token(
				context: tokens[1].context,
				value: packSigned(Int32(1 + dcGroupCount)))
		}
		let histograms = HistogramCluster.buildHistograms(
			tokens: tokens, contextMap: nil, contextCount: ContextTree.treeContextCount)
		let optimizedCode = HistogramCluster.optimizeEntropyCode(
			tokens: tokens, contextCount: ContextTree.treeContextCount)
		let code =
			contextMapOverride.map {
				EntropyCode(contextMap: $0, prefixCodes: optimizedCode.prefixCodes)
			} ?? optimizedCode
		var codeWriter = BitWriter()
		EntropyCodeWriter.write(code, writer: &codeWriter)
		var streamWriter = BitWriter()
		EntropyCodeWriter.write(code, writer: &streamWriter)
		for token in tokens { streamWriter.write(token: token, code: code) }
		var fullWriter = BitWriter()
		fullWriter.write(1, 1)
		fullWriter.write(1, 0)
		EntropyCodeWriter.write(code, writer: &fullWriter)
		for token in tokens { fullWriter.write(token: token, code: code) }
		var dump = SemanticDump()
		dump.record(
			"entropy.tree_entropy.context_map",
			.integers(code.contextMap.map(Int64.init)))
		dump.record(
			"entropy.tree_entropy.histogram_counts",
			.integers(histograms.flatMap { $0.counts.map(Int64.init) }))
		dump.record(
			"entropy.tree_entropy.tokens",
			.integers(tokens.flatMap { [Int64($0.context), Int64($0.value)] }))
		dump.record(
			"entropy.tree_entropy.prefix_code_count",
			.integers([Int64(code.prefixCodes.count)]))
		dump.record(
			"entropy.tree_entropy.prefix_depths",
			.integers(code.prefixCodes.flatMap { $0.depths.map(Int64.init) }))
		dump.record(
			"entropy.tree_entropy.prefix_bits",
			.integers(code.prefixCodes.flatMap { $0.bits.map(Int64.init) }))
		dump.record("entropy.tree_entropy.use_prefix_code", .integers([1]))
		dump.record(
			"entropy.tree_entropy.code_bit_count",
			.integers([Int64(codeWriter.bitsWritten)]))
		dump.record(
			"entropy.tree_entropy.code_bytes",
			.integers(codeWriter.bytes.map(Int64.init)))
		dump.record(
			"entropy.tree_entropy.bit_count",
			.integers([Int64(streamWriter.bitsWritten)]))
		dump.record(
			"entropy.tree_entropy.bytes", .integers(streamWriter.bytes.map(Int64.init)))
		dump.record(
			"entropy.tree_entropy.stream_bit_count",
			.integers([Int64(streamWriter.bitsWritten)]))
		dump.record(
			"entropy.tree_entropy.stream_bytes",
			.integers(streamWriter.bytes.map(Int64.init)))
		dump.record(
			"entropy.tree_entropy.full_bit_count",
			.integers([Int64(fullWriter.bitsWritten)]))
		dump.record(
			"entropy.tree_entropy.full_bytes",
			.integers(fullWriter.bytes.map(Int64.init)))
		return dump
	}

	static func modularTokens(data: DCGroupData) -> SemanticDump {
		var section = SectionWriter(mode: .staging(.staticDC))
		DCGroupEncoder.writeDCTokens(data: data, writer: &section)
		let tokens = section.staged.compactMap { record -> Token? in
			guard case .token(let context, let value) = record else { return nil }
			return Token(context: context, value: value)
		}
		var dump = SemanticDump()
		dump.record("entropy.modular.token_count", .integers([Int64(tokens.count)]))
		dump.record(
			"entropy.modular.tokens",
			.integers(tokens.flatMap { [Int64($0.context), Int64($0.value)] }))
		return dump
	}

	static func acMetadataTokens(data: DCGroupData) -> SemanticDump {
		var section = SectionWriter(mode: .staging(.staticDC))
		DCGroupEncoder.writeACMetadataTokens(data: data, writer: &section)
		let tokens = section.staged.compactMap { record -> Token? in
			guard case .token(let context, let value) = record else { return nil }
			return Token(context: context, value: value)
		}
		var dump = SemanticDump()
		dump.record("entropy.ac_metadata.token_count", .integers([Int64(tokens.count)]))
		dump.record(
			"entropy.ac_metadata.tokens",
			.integers(tokens.flatMap { [Int64($0.context), Int64($0.value)] }))
		return dump
	}

	static func acTokens(group: Encoder.ACGroupCompute, order: [[Int]]) -> SemanticDump {
		let output = Encoder.tokenizeACGroup(group, order: order, mode: .staging(.staticAC))
		let tokens = output.section.staged.compactMap { record -> Token? in
			guard case .token(let context, let value) = record else { return nil }
			return Token(context: context, value: value)
		}
		var dump = SemanticDump()
		dump.record(
			"entropy.ac_tokens.context_count",
			.integers([Int64(ACContext.numBlockCategories)]))
		dump.record(
			"entropy.ac_tokens.contexts", .integers(tokens.map { Int64($0.context) }))
		dump.record("entropy.ac_tokens.token_count", .integers([Int64(tokens.count)]))
		dump.record("entropy.ac_tokens.values", .integers(tokens.map { Int64($0.value) }))
		return dump
	}

	static func tokenStreams(tokens: [[Token]], code: EntropyCode) -> SemanticDump {
		var lengths: [Int64] = []
		var records: [Int64] = []
		var bitCounts: [Int64] = []
		var bytes: [Int64] = []
		var codeWriter = BitWriter()
		codeWriter.write(1, 0)  // disabled LZ77 field in the transmitted code
		EntropyCodeWriter.write(code, allowContextMapANS: true, writer: &codeWriter)
		for (index, stream) in tokens.enumerated() {
			lengths.append(Int64(stream.count))
			records.append(contentsOf: [Int64(index), Int64(stream.count)])
			records.append(
				contentsOf: stream.flatMap { [Int64($0.context), Int64($0.value)] })
			var section = SectionWriter(mode: .staging(.staticAC))
			for token in stream { section.write(token: token) }
			section.flush(code: code)
			let writer = section.finished()
			bitCounts.append(Int64(writer.bitsWritten))
			bytes.append(contentsOf: writer.bytes.map(Int64.init))
		}
		var dump = SemanticDump()
		dump.record(
			"entropy.streams.transmitted_context_count",
			.integers([Int64(code.transmittedContextCount)]))
		dump.record(
			"entropy.streams.code_kind", .integers([code.ansInfoTables == nil ? 0 : 1]))
		dump.record(
			"entropy.streams.code_bit_count", .integers([Int64(codeWriter.bitsWritten)])
		)
		dump.record(
			"entropy.streams.code_bytes", .integers(codeWriter.bytes.map(Int64.init)))
		dump.record("entropy.streams.count", .integers([Int64(tokens.count)]))
		dump.record("entropy.streams.lengths", .integers(lengths))
		dump.record("entropy.streams.tokens", .integers(records))
		dump.record("entropy.streams.bit_counts", .integers(bitCounts))
		dump.record("entropy.streams.bytes", .integers(bytes))
		return dump
	}

	static func coefficientOrder(counts: [Int64]) -> SemanticDump {
		precondition(counts.count == DCT.blockSize && counts.allSatisfy { $0 >= 0 })
		let result = CoeffOrder.computeOrder(counts: counts)
		var dump = SemanticDump()
		dump.record("entropy.coefficient_order.counts", .integers(counts))
		dump.record(
			"entropy.coefficient_order.order", .integers(result.order.map(Int64.init)))
		dump.record(
			"entropy.coefficient_order.is_default",
			.integers([result.isDefault ? 1 : 0]))
		return dump
	}
}
