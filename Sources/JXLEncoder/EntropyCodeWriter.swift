//
//  EntropyCodeWriter.swift
//  JXLEncoder
//
//  Port of `WriteContextMap` and `WriteEntropyCode` from libjxl-tiny's
//  encoder/enc_entropy_code.cc.
//
//  An entropy code is transmitted as its context map followed by its prefix
//  codes. The context map is itself entropy coded, with a code built from the
//  map's own symbol statistics.
//

enum EntropyCodeWriter {
	static func writeTokens(
		_ tokens: [LZ77.EncodedToken], code: EntropyCode, writer: inout BitWriter
	) {
		let lengthSymbolOffset = code.lz77?.minSymbol ?? 0
		if let tables = code.ansInfoTables {
			ANSTokenWriter.write(
				contextMapTokens: tokens, contextMap: code.contextMap,
				infoTables: tables,
				uintConfigurations: code.uintConfigurations
					?? [HybridUintConfiguration](
						repeating: HybridUintConfiguration(
							splitExponent: 4, msbInToken: 2,
							lsbInToken: 0), count: tables.count),
				lengthSymbolOffset: lengthSymbolOffset, writer: &writer)
			return
		}
		for encoded in tokens {
			let token = encoded.token
			let histogram = Int(code.contextMap[Int(token.context)])
			let configuration =
				encoded.isLength
				? LZ77.lengthConfiguration
				: code.uintConfigurations?[histogram]
					?? HybridUintConfiguration(
						splitExponent: 4, msbInToken: 2, lsbInToken: 0)
			let result = configuration.encode(token.value)
			let symbol = Int(
				result.symbol + (encoded.isLength ? lengthSymbolOffset : 0))
			let prefix = code.prefixCodes[histogram]
			let depth = prefix.isDegenerate ? 0 : Int(prefix.depths[symbol])
			let bits = prefix.isDegenerate ? 0 : UInt64(prefix.bits[symbol])
			writer.write(depth, bits)
			writer.write(Int(result.bitCount), UInt64(result.bits))
		}
	}

	static func writeTokens(_ tokens: [Token], code: EntropyCode, writer: inout BitWriter) {
		writeTokens(
			tokens.map { LZ77.EncodedToken(token: $0, isLength: false) }, code: code,
			writer: &writer)
	}

	static func writeContextMap(_ code: EntropyCode, writer: inout BitWriter) {
		// The decoder reads a map only for more than one context.
		guard code.transmittedContextCount > 1 else { return }

		// A re-clustered code composes with the map it was built from, so the
		// decoder still sees an entry per original context.
		let entries: [UInt8] =
			if let original = code.originalContextMap {
				original.map { code.contextMap[Int($0)] }
			} else {
				code.contextMap
			}
		let numHistograms =
			code.ansHistograms?.count
			?? code.ansInfoTables?.count ?? code.prefixCodeCount
		writeContextMapEntries(
			entries, numHistograms: numHistograms, writer: &writer)
	}

	static func writeContextMapEntries(
		_ entries: [UInt8], numHistograms: Int, writer: inout BitWriter
	) {
		ContextMapEncoding.write(
			ContextMapEncoding.prepare(entries, numHistograms: numHistograms),
			to: &writer)
	}

	static func write(_ code: EntropyCode, writer: inout BitWriter) {
		writeLZ77Header(code.lz77, writer: &writer)
		writeHistograms(code, writer: &writer)
	}

	/// Everything after the LZ77 header: context map, coder choice, uint
	/// configurations and per-histogram codes.
	static func writeHistograms(_ code: EntropyCode, writer: inout BitWriter) {
		writeContextMap(code, writer: &writer)
		let numHistograms =
			code.ansHistograms?.count
			?? code.ansInfoTables?.count ?? code.prefixCodeCount
		let configurations =
			code.uintConfigurations
			?? [HybridUintConfiguration](
				repeating: HybridUintConfiguration(
					splitExponent: 4, msbInToken: 2, lsbInToken: 0),
				count: numHistograms)
		if let histograms = code.ansHistograms {
			writer.write(1, 0)  // use_prefix_code = false
			writer.write(2, UInt64(code.logAlphabetSize - 5))
			PrefixCodeWriter.writeUintConfigs(
				configurations, logAlphaSize: code.logAlphabetSize,
				writer: &writer)
			for histogram in histograms {
				histogram.write(to: &writer)
			}
		} else if let ansInfoTables = code.ansInfoTables {
			writer.write(1, 0)  // use_prefix_code = false
			writer.write(2, UInt64(code.logAlphabetSize - 5))
			PrefixCodeWriter.writeUintConfigs(
				configurations, logAlphaSize: code.logAlphabetSize,
				writer: &writer)
			for table in ansInfoTables {
				ANSHistogramWriter.write(counts: table.map(\.freq), writer: &writer)
			}
		} else {
			writer.write(1, 1)  // use_prefix_code
			PrefixCodeWriter.writePrefixCodes(
				code.prefixCodes, uintConfigurations: code.uintConfigurations,
				writer: &writer)
		}
	}
}

struct HybridUintConfiguration: Equatable, Sendable {
	let splitExponent: Int
	let msbInToken: Int
	let lsbInToken: Int

	func encode(_ value: UInt32) -> (symbol: UInt32, bitCount: UInt32, bits: UInt32) {
		precondition((0...31).contains(splitExponent))
		precondition(msbInToken >= 0 && lsbInToken >= 0)
		precondition(msbInToken + lsbInToken <= splitExponent)
		let splitToken = UInt32(1) << splitExponent
		guard value >= splitToken else { return (value, 0, 0) }

		let exponent = 31 - value.leadingZeroBitCount
		let mantissa = value - (UInt32(1) << exponent)
		let bitCount = exponent - msbInToken - lsbInToken
		let msb = mantissa >> (exponent - msbInToken)
		let lsbMask = (UInt32(1) << lsbInToken) - 1
		let symbol =
			splitToken
			+ (UInt32(exponent - splitExponent) << (msbInToken + lsbInToken))
			+ (msb << lsbInToken)
			+ (mantissa & lsbMask)
		let extraMask = (UInt32(1) << bitCount) - 1
		let bits = (value >> lsbInToken) & extraMask
		return (symbol, UInt32(bitCount), bits)
	}
}

/// The `HistogramParams` (enc_ans_params.h) fields this encoder's callers set;
/// clustering is always `kBest`, the only value they use.
struct HistogramParameters: Sendable {
	enum UintMethod: Equatable, Sendable {
		/// `kContextMap`: the fixed (2, 0, 1) configuration.
		case contextMap
		/// `kBest`: per-histogram search over the candidate configurations,
		/// capped below min(256, LZ77 min_symbol) (enc_ans.cc:732-895).
		case best
	}

	var uintMethod: UintMethod = .best
	var lz77Method: LZ77.Method = .rle
	/// Prefix codes regardless of cost (`force_huffman`), as the coded ICC
	/// requires (enc_ans.cc:1170).
	var forcesPrefixCodes = false

	/// `min_symbol` 224 normally, 512 under forced prefix codes
	/// (enc_ans.cc:1090).
	var lz77MinSymbol: UInt32 { forcesPrefixCodes ? 512 : 224 }
}

extension EntropyCodeWriter {
	/// A token stream after LZ77 with the code that writes it.
	struct Prepared {
		let tokens: [LZ77.EncodedToken]
		/// Carries the LZ77 parameters, nil when LZ77 is off.
		let code: EntropyCode
		/// Header plus token bits, for callers that pick between encodings.
		let estimatedCost: Int
	}

	/// LZ77, `kBest` clustering, uint configurations and the prefix-or-ANS
	/// choice for `contextCount` contexts, so that writing the result is what a
	/// decoder reads back as `tokens`. Ports `BuildAndEncodeHistograms`
	/// (enc_ans.cc:1060-1180) and `ChooseUintConfigs` (enc_ans.cc:732-895).
	static func prepare(
		_ tokens: [Token], contextCount: Int, parameters: HistogramParameters
	) -> Prepared {
		let lz77 = LZ77.apply(tokens, contextCount: contextCount, parameters: parameters)
		let lengthSymbolOffset = lz77.parameters?.minSymbol ?? 0
		let defaultConfiguration =
			parameters.uintMethod == .contextMap
			? HybridUintConfiguration(splitExponent: 2, msbInToken: 0, lsbInToken: 1)
			: HybridUintConfiguration(splitExponent: 4, msbInToken: 2, lsbInToken: 0)
		func symbol(_ encoded: LZ77.EncodedToken, _ configuration: HybridUintConfiguration)
			-> UInt32
		{
			encoded.isLength
				? LZ77.lengthConfiguration.encode(encoded.token.value).symbol
					+ lengthSymbolOffset
				: configuration.encode(encoded.token.value).symbol
		}
		var histograms = [Histogram](
			repeating: Histogram(),
			count: contextCount + (lz77.parameters == nil ? 0 : 1))
		for encoded in lz77.tokens {
			histograms[Int(encoded.token.context)].add(
				symbol(encoded, defaultConfiguration))
		}
		for index in histograms.indices { histograms[index].computeBitCost() }
		let usesPrefixCode =
			parameters.forcesPrefixCodes
			|| shouldUsePrefixCode(
				tokenCount: lz77.tokens.count, histograms: histograms)
		let (clusters, contextMap) = HistogramCluster.clusterBest(histograms)
		var configurations = [HybridUintConfiguration](
			repeating: defaultConfiguration, count: clusters.count)
		var logAlphabetSize =
			usesPrefixCode
			? PrefixCodeWriter.prefixMaxBits : (lz77.parameters == nil ? 7 : 8)
		histograms = clusters
		if parameters.uintMethod == .best {
			let symbolLimit = min(256, lz77.parameters?.minSymbol ?? 256)
			for cluster in clusters.indices {
				let values = lz77.tokens.filter {
					!$0.isLength
						&& Int(contextMap[Int($0.token.context)]) == cluster
				}
				(configurations[cluster], histograms[cluster]) = bestConfiguration(
					values, symbolLimit: symbolLimit)
			}
			for encoded in lz77.tokens where encoded.isLength {
				histograms[Int(contextMap[Int(encoded.token.context)])].add(
					symbol(encoded, defaultConfiguration))
			}
			let maximumSymbol =
				histograms.compactMap {
					$0.counts.lastIndex(where: { $0 != 0 })
				}.max() ?? 0
			logAlphabetSize = 5
			while maximumSymbol >= 1 << logAlphabetSize { logAlphabetSize += 1 }
			if usesPrefixCode {
				logAlphabetSize = PrefixCodeWriter.prefixMaxBits
			} else {
				precondition(logAlphabetSize <= 8)
			}
		}
		let prefixCodes = HistogramCluster.buildPrefixCodes(histograms)
		var code =
			usesPrefixCode
			? EntropyCode(
				contextMap: contextMap, prefixCodes: prefixCodes,
				uintConfigurations: configurations, logAlphabetSize: logAlphabetSize
			)
			: EntropyCode(
				contextMap: contextMap, prefixCodes: prefixCodes,
				ansHistograms: histograms.map {
					ANSEncodingHistogram.computeBest(
						counts: $0.counts, strategy: .precise)
				}, uintConfigurations: configurations,
				logAlphabetSize: logAlphabetSize)
		code.lz77 = lz77.parameters

		var header = BitWriter()
		writeLZ77Header(code.lz77, writer: &header)
		header.write(1, usesPrefixCode ? 1 : 0)
		var estimatedCost = 0
		if usesPrefixCode {
			PrefixCodeWriter.writePrefixCodes(
				prefixCodes, uintConfigurations: configurations, writer: &header)
			for (histogram, prefix) in zip(histograms, prefixCodes)
			where !prefix.isDegenerate {
				for (symbol, count) in histogram.counts.enumerated() {
					estimatedCost += Int(count) * Int(prefix.depths[symbol])
				}
			}
		} else {
			header.write(2, UInt64(logAlphabetSize - 5))
			PrefixCodeWriter.writeUintConfigs(
				configurations, logAlphaSize: logAlphabetSize, writer: &header)
			for histogram in code.ansHistograms ?? [] {
				estimatedCost += Int(histogram.cost.rounded(.up))
			}
		}
		return Prepared(
			tokens: lz77.tokens, code: code,
			estimatedCost: header.bitsWritten + estimatedCost)
	}

	/// The `kBest` candidate with the lowest ANS population cost plus extra and
	/// signalling bits whose largest symbol stays below `symbolLimit`
	/// (enc_ans.cc:771-863).
	private static func bestConfiguration(
		_ values: [LZ77.EncodedToken], symbolLimit: UInt32
	) -> (HybridUintConfiguration, Histogram) {
		var best = (
			cost: Float.greatestFiniteMagnitude,
			configuration: bestCandidates[0], histogram: Histogram()
		)
		for configuration in bestCandidates {
			var histogram = Histogram()
			var extraBits = 0
			var maximumSymbol: UInt32 = 0
			for encoded in values {
				let result = configuration.encode(encoded.token.value)
				maximumSymbol = max(
					maximumSymbol,
					result.symbol | ((1 << configuration.lsbInToken) - 1))
				extraBits += Int(result.bitCount)
				histogram.add(result.symbol)
			}
			guard maximumSymbol < symbolLimit else { continue }
			let cost =
				ANSEncodingHistogram.computeBest(
					counts: histogram.counts, strategy: .fast
				).cost
				+ Float(extraBits)
				+ Float(ceilLog2Nonzero(configuration.splitExponent + 1))
				+ Float(
					ceilLog2Nonzero(
						configuration.splitExponent
							- configuration.msbInToken + 1))
			if cost < best.cost { best = (cost, configuration, histogram) }
		}
		return (best.configuration, best.histogram)
	}

	private static let bestCandidates = [
		(4, 2, 0), (4, 1, 0), (4, 2, 1), (4, 2, 2), (4, 1, 2),
		(5, 2, 0), (5, 1, 0), (5, 2, 1), (5, 2, 2), (5, 1, 2),
		(3, 2, 0), (3, 1, 0), (3, 2, 1), (3, 1, 2),
		(4, 1, 3), (5, 1, 4), (5, 2, 3), (6, 1, 5), (6, 2, 4), (6, 0, 0),
		(0, 0, 0), (2, 0, 1), (7, 0, 0), (8, 0, 0), (9, 0, 0),
		(10, 0, 0), (11, 0, 0), (12, 0, 0),
	].map { HybridUintConfiguration(splitExponent: $0.0, msbInToken: $0.1, lsbInToken: $0.2) }

	/// `use_prefix_code` short of `force_huffman`: under 100 tokens, or every
	/// context below 1e-5 bits of entropy (enc_ans.cc:1150-1163).
	static func shouldUsePrefixCode(tokenCount: Int, histograms: [Histogram]) -> Bool {
		tokenCount < 100 || histograms.allSatisfy { $0.bitCost < 1e-5 }
	}

	/// `LZ77Params` (dec_ans.cc:304-315) and the length configuration.
	static func writeLZ77Header(_ lz77: LZ77.Parameters?, writer: inout BitWriter) {
		writer.write(1, lz77 == nil ? 0 : 1)
		guard let lz77 else { return }
		writeU32(
			lz77.minSymbol, [(224, 0), (512, 0), (4096, 0), (8, 15)], writer: &writer)
		writeU32(LZ77.minLength, [(3, 0), (4, 0), (5, 2), (9, 8)], writer: &writer)
		PrefixCodeWriter.writeUintConfigs(
			[LZ77.lengthConfiguration], logAlphaSize: 8, writer: &writer)
	}

	/// A header `U32` field given its four (offset, extra bits) distributions,
	/// a direct value having 0 extra bits: the first with the fewest extra bits
	/// that holds `value` (fields.cc:454-489, enc_fields.cc:110-127).
	private static func writeU32(
		_ value: UInt32, _ distributions: [(offset: UInt32, bitCount: Int)],
		writer: inout BitWriter
	) {
		let (selector, distribution) = distributions.enumerated()
			.filter {
				value >= $0.element.offset
					&& UInt64(value - $0.element.offset) < UInt64(1)
						<< $0.element.bitCount
			}
			.min { $0.element.bitCount < $1.element.bitCount }!
		writer.write(2, UInt64(selector))
		writer.write(distribution.bitCount, UInt64(value - distribution.offset))
	}

	/// The code, then the tokens.
	static func write(_ prepared: Prepared, writer: inout BitWriter) {
		write(prepared.code, writer: &writer)
		writeTokens(prepared.tokens, code: prepared.code, writer: &writer)
	}
}

enum ContextMapEncoding {
	enum Representation: Equatable {
		case simple(entryBits: Int)
		case raw
		case moveToFront
	}

	struct Prepared {
		let entries: [UInt8]
		let numHistograms: Int
		let transformedEntries: [UInt8]
		let raw: EntropyCodeWriter.Prepared?
		let moveToFront: EntropyCodeWriter.Prepared?
		let representation: Representation
	}

	static func prepare(_ entries: [UInt8], numHistograms: Int) -> Prepared {
		precondition(!entries.isEmpty)
		precondition((1...256).contains(numHistograms))
		precondition(entries.allSatisfy { Int($0) < numHistograms })
		let entryBits = ceilLog2Nonzero(numHistograms)
		var mtfOrder = Array(0...Int(entries.max() ?? 0)).map(UInt8.init)
		let transformedEntries = entries.map { entry -> UInt8 in
			let index = mtfOrder.firstIndex(of: entry)!
			mtfOrder.remove(at: index)
			mtfOrder.insert(entry, at: 0)
			return UInt8(index)
		}
		if numHistograms == 1 {
			return Prepared(
				entries: entries, numHistograms: numHistograms,
				transformedEntries: transformedEntries, raw: nil,
				moveToFront: nil, representation: .simple(entryBits: 0))
		}
		func prepare(_ entries: [UInt8]) -> EntropyCodeWriter.Prepared {
			EntropyCodeWriter.prepare(
				entries.map { Token(context: 0, value: UInt32($0)) },
				contextCount: 1,
				parameters: HistogramParameters(uintMethod: .contextMap))
		}
		let raw = prepare(entries)
		let moveToFront = prepare(transformedEntries)
		let simpleCost = entryBits * entries.count
		let representation: Representation
		if entryBits < 4 && simpleCost < raw.estimatedCost
			&& simpleCost < moveToFront.estimatedCost
		{
			representation = .simple(entryBits: entryBits)
		} else if moveToFront.estimatedCost < raw.estimatedCost {
			representation = .moveToFront
		} else {
			representation = .raw
		}
		return Prepared(
			entries: entries, numHistograms: numHistograms,
			transformedEntries: transformedEntries, raw: raw,
			moveToFront: moveToFront, representation: representation)
	}

	static func write(_ prepared: Prepared, to writer: inout BitWriter) {
		if prepared.numHistograms == 1 {
			writer.write(1, 1)
			writer.write(2, 0)
			return
		}
		switch prepared.representation {
		case .simple(let entryBits):
			writer.write(1, 1)
			writer.write(2, UInt64(entryBits))
			for entry in prepared.entries { writer.write(entryBits, UInt64(entry)) }
		case .raw, .moveToFront:
			writer.write(1, 0)
			let useMTF: Bool
			let entropy: EntropyCodeWriter.Prepared
			switch prepared.representation {
			case .raw:
				useMTF = false
				entropy = prepared.raw!
			case .moveToFront:
				useMTF = true
				entropy = prepared.moveToFront!
			case .simple:
				preconditionFailure("handled above")
			}
			writer.write(1, useMTF ? 1 : 0)
			EntropyCodeWriter.write(entropy, writer: &writer)
		}
	}
}
