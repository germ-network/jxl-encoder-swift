@testable import JXLEncoder

enum SwiftEntropySemanticEncoding {
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
		guard numHistograms > 0,
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
		dump.record("entropy.context_map.bit_count", .integers([Int64(writer.bitsWritten)]))
		dump.record("entropy.context_map.bytes", .integers(writer.bytes.map(Int64.init)))
		return dump
	}

	static func tree(dcGroupCount: Int) -> SemanticDump {
		precondition(dcGroupCount > 0)
		var tokens = ContextTree.staticTokens
		tokens[1] = Token(
			context: tokens[1].context, value: packSigned(Int32(1 + dcGroupCount)))
		var dump = SemanticDump()
		dump.record("entropy.tree.dc_group_count", .integers([Int64(dcGroupCount)]))
		dump.record("entropy.tree.token_count", .integers([Int64(tokens.count)]))
		dump.record(
			"entropy.tree.tokens",
			.integers(tokens.flatMap { [Int64($0.context), Int64($0.value)] }))
		return dump
	}

	static func modularTokens(data: DCGroupData) -> SemanticDump {
		var section = SectionWriter(mode: .staging(.staticDC))
		DCGroupEncoder.write(data: data, writer: &section)
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

	static func acTokens(group: Encoder.ACGroupCompute, order: [[Int]]) -> SemanticDump {
		let output = Encoder.tokenizeACGroup(group, order: order, mode: .staging(.staticAC))
		let tokens = output.section.staged.compactMap { record -> Token? in
			guard case .token(let context, let value) = record else { return nil }
			return Token(context: context, value: value)
		}
		var dump = SemanticDump()
		dump.record("entropy.ac_tokens.group_x", .integers([Int64(group.groupX)]))
		dump.record("entropy.ac_tokens.group_y", .integers([Int64(group.groupY)]))
		dump.record("entropy.ac_tokens.count", .integers([Int64(tokens.count)]))
		dump.record(
			"entropy.ac_tokens.tokens",
			.integers(tokens.flatMap { [Int64($0.context), Int64($0.value)] }))
		return dump
	}

	static func tokenStreams(tokens: [[Token]], code: EntropyCode) -> SemanticDump {
		var lengths: [Int64] = []
		var records: [Int64] = []
		var bitCounts: [Int64] = []
		var bytes: [Int64] = []
		for (index, stream) in tokens.enumerated() {
			lengths.append(Int64(stream.count))
			records.append(contentsOf: [Int64(index), Int64(stream.count)])
			records.append(
				contentsOf: stream.flatMap { [Int64($0.context), Int64($0.value)] })
			var writer = BitWriter()
			if let tables = code.ansInfoTables {
				ANSTokenWriter.write(
					tokens: stream, contextMap: code.contextMap,
					infoTables: tables, writer: &writer)
			} else {
				for token in stream { writer.write(token: token, code: code) }
			}
			bitCounts.append(Int64(writer.bitsWritten))
			bytes.append(contentsOf: writer.bytes.map(Int64.init))
		}
		var dump = SemanticDump()
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

	static func frameLayout(codestream: [UInt8]) throws -> SemanticDump {
		throw SemanticDumpError.unimplemented
	}
}
