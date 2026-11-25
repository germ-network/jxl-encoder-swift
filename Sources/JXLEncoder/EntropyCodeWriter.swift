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
		_ tokens: [ContextMapEntropy.EncodedToken], code: EntropyCode,
		lengthConfiguration: HybridUintConfiguration, lengthSymbolOffset: UInt32,
		writer: inout BitWriter
	) {
		if let tables = code.ansInfoTables {
			ANSTokenWriter.write(
				contextMapTokens: tokens, contextMap: code.contextMap,
				infoTables: tables,
				uintConfigurations: code.uintConfigurations
					?? [HybridUintConfiguration](
						repeating: HybridUintConfiguration(
							splitExponent: 4, msbInToken: 2,
							lsbInToken: 0), count: tables.count),
				lengthConfiguration: lengthConfiguration,
				lengthSymbolOffset: lengthSymbolOffset, writer: &writer)
			return
		}
		for encoded in tokens {
			let token = encoded.token
			let histogram = Int(code.contextMap[Int(token.context)])
			let configuration =
				encoded.isLength
				? lengthConfiguration
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
			tokens.map {
				ContextMapEntropy.EncodedToken(token: $0, isLength: false)
			}, code: code,
			lengthConfiguration: HybridUintConfiguration(
				splitExponent: 0, msbInToken: 0, lsbInToken: 0),
			lengthSymbolOffset: 0, writer: &writer)
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

enum ContextMapEntropy {
	static func runLengthEncode(_ tokens: [Token], contextCount: Int) -> RunLengthResult {
		precondition(
			contextCount > 0 && tokens.allSatisfy { Int($0.context) < contextCount })
		let dataConfiguration = HybridUintConfiguration(
			splitExponent: 4, msbInToken: 2, lsbInToken: 0)
		var histograms = [Histogram](repeating: Histogram(), count: contextCount)
		for token in tokens {
			histograms[Int(token.context)].add(
				dataConfiguration.encode(token.value).symbol)
		}
		let symbolCosts = histograms.map { histogram -> [Float] in
			let inverseTotal = 1.0 / (Float(histogram.totalCount) + 1e-8)
			return histogram.counts.map { count in
				if count > 0 && Int(count) != histogram.totalCount {
					return -FastMath.log2(Float(count) * inverseTotal)
				}
				return count == 0 ? 12 : 0
			}
		}
		var cumulative = [Float](repeating: 0, count: tokens.count + 1)
		for index in tokens.indices {
			let encoded = dataConfiguration.encode(tokens[index].value)
			cumulative[index + 1] =
				symbolCosts[Int(tokens[index].context)][Int(encoded.symbol)]
				+ Float(encoded.bitCount) + cumulative[index]
		}
		var transformed: [EncodedToken] = []
		transformed.reserveCapacity(tokens.count)
		var bitDecrease: Float = 0
		var index = 0
		while index < tokens.count {
			var repeatCount = 0
			if index > 0 {
				while index + repeatCount < tokens.count,
					tokens[index + repeatCount].value == tokens[index - 1].value
				{
					repeatCount += 1
				}
			}
			if repeatCount == 0 {
				transformed.append(
					EncodedToken(token: tokens[index], isLength: false))
				index += 1
				continue
			}
			let repeatedCost = cumulative[index + repeatCount] - cumulative[index]
			let encodedLength = repeatCount - 3
			let lengthCost =
				repeatCount >= 3
				? Float(ceilLog2Nonzero(encodedLength + 1) + 1) : 0
			if repeatCount < 3 || repeatedCost <= lengthCost {
				for token in tokens[index..<(index + repeatCount)] {
					transformed.append(
						EncodedToken(token: token, isLength: false))
				}
				index += repeatCount
				continue
			}
			transformed.append(
				EncodedToken(
					token: Token(
						context: tokens[index].context,
						value: UInt32(encodedLength)),
					isLength: true))
			transformed.append(
				EncodedToken(
					token: Token(context: UInt32(contextCount), value: 0),
					isLength: false))
			bitDecrease += repeatedCost - lengthCost
			index += repeatCount
		}
		guard Double(bitDecrease) > Double(tokens.count) * 0.2 + 16 else {
			return RunLengthResult(
				enabled: false,
				tokens: tokens.map { EncodedToken(token: $0, isLength: false) })
		}
		return RunLengthResult(enabled: true, tokens: transformed)
	}

	struct EncodedToken: Equatable, Sendable {
		let token: Token
		let isLength: Bool
	}

	struct RunLengthResult {
		let enabled: Bool
		let tokens: [EncodedToken]
	}

	struct Prepared {
		let runLength: RunLengthResult
		let contextMap: [UInt8]
		let histograms: [Histogram]
		let uintConfigurations: [HybridUintConfiguration]
		let usesPrefixCode: Bool
		let logAlphabetSize: Int
		let prefixCodes: [PrefixCode]
		let ansHistograms: [ANSEncodingHistogram]
		let estimatedCost: Int
	}

	static func runLengthEncode(_ entries: [UInt8]) -> RunLengthResult {
		let dataConfig = HybridUintConfiguration(
			splitExponent: 4, msbInToken: 2, lsbInToken: 0)
		let minLength = 3
		var histogram = Histogram()
		for entry in entries {
			histogram.add(dataConfig.encode(UInt32(entry)).symbol)
		}
		var symbolCosts = [Float](repeating: 0, count: histogram.counts.count)
		let inverseTotal = 1.0 / Float(max(histogram.totalCount, 1))
		for index in histogram.counts.indices {
			let count = histogram.counts[index]
			if count > 0 && Int(count) != histogram.totalCount {
				symbolCosts[index] = -FastMath.log2(Float(count) * inverseTotal)
			} else if count == 0 {
				symbolCosts[index] = 12
			}
		}
		var cumulativeBitCosts = [Float](repeating: 0, count: entries.count + 1)
		for index in entries.indices {
			let encoded = dataConfig.encode(UInt32(entries[index]))
			cumulativeBitCosts[index + 1] =
				symbolCosts[Int(encoded.symbol)] + Float(encoded.bitCount)
				+ cumulativeBitCosts[index]
		}

		var transformed: [EncodedToken] = []
		transformed.reserveCapacity(entries.count)
		var bitDecrease: Float = 0
		var index = 0
		while index < entries.count {
			var repeatCount = 0
			if index > 0 {
				while index + repeatCount < entries.count,
					entries[index + repeatCount] == entries[index - 1]
				{
					repeatCount += 1
				}
			}
			if repeatCount == 0 {
				transformed.append(
					EncodedToken(
						token: Token(
							context: 0, value: UInt32(entries[index])),
						isLength: false))
				index += 1
				continue
			}

			let repeatedCost =
				cumulativeBitCosts[index + repeatCount] - cumulativeBitCosts[index]
			let encodedLength = repeatCount - minLength
			let lengthCost =
				repeatCount >= minLength
				? Float(ceilLog2Nonzero(encodedLength + 1) + 1) : 0
			if repeatCount < minLength || repeatedCost <= lengthCost {
				for offset in 0..<repeatCount {
					transformed.append(
						EncodedToken(
							token: Token(
								context: 0,
								value: UInt32(
									entries[index + offset])),
							isLength: false))
				}
				index += repeatCount
				continue
			}

			transformed.append(
				EncodedToken(
					token: Token(context: 0, value: UInt32(encodedLength)),
					isLength: true))
			transformed.append(
				EncodedToken(token: Token(context: 1, value: 0), isLength: false))
			bitDecrease += repeatedCost - lengthCost
			index += repeatCount
		}

		guard Double(bitDecrease) > Double(entries.count) * 0.2 + 16 else {
			return RunLengthResult(
				enabled: false,
				tokens: entries.map {
					EncodedToken(
						token: Token(context: 0, value: UInt32($0)),
						isLength: false)
				})
		}
		return RunLengthResult(enabled: true, tokens: transformed)
	}

	static func cluster(_ histograms: [Histogram]) -> (
		histograms: [Histogram], contextMap: [UInt8]
	) {
		precondition((1...2).contains(histograms.count))
		if histograms.count == 1 {
			return (histograms, [0])
		}
		var (clusters, symbols) = HistogramCluster.fastCluster(
			histograms, maxHistograms: histograms.count)
		if clusters.count == 2 {
			let firstCost = ANSEncodingHistogram.computeBest(
				counts: clusters[0].counts, strategy: .fast
			).cost
			let secondCost = ANSEncodingHistogram.computeBest(
				counts: clusters[1].counts, strategy: .fast
			).cost
			var combined = clusters[0]
			combined.add(clusters[1])
			let mergedCost = ANSEncodingHistogram.computeBest(
				counts: combined.counts, strategy: .fast
			).cost
			if mergedCost < firstCost + secondCost {
				clusters = [combined]
				symbols = [0, 0]
			}
		}
		let result = HistogramCluster.reindex(symbols: symbols, clusters: clusters)
		return (result.clusters, result.contextMap)
	}

	static func prepare(_ entries: [UInt8]) -> Prepared {
		precondition(!entries.isEmpty)
		let runLength = runLengthEncode(entries)
		let contextCount = runLength.enabled ? 2 : 1
		var sourceHistograms = [Histogram](
			repeating: Histogram(), count: contextCount)
		let dataConfiguration = HybridUintConfiguration(
			splitExponent: 2, msbInToken: 0, lsbInToken: 1)
		let lengthConfiguration = HybridUintConfiguration(
			splitExponent: 0, msbInToken: 0, lsbInToken: 0)
		let minLengthSymbol: UInt32 = 224
		for encoded in runLength.tokens {
			let configuration =
				encoded.isLength ? lengthConfiguration : dataConfiguration
			let symbol = configuration.encode(encoded.token.value).symbol
			let histogramSymbol = symbol + (encoded.isLength ? minLengthSymbol : 0)
			sourceHistograms[Int(encoded.token.context)].add(histogramSymbol)
		}
		var costHistograms = sourceHistograms
		for index in costHistograms.indices { costHistograms[index].computeBitCost() }
		let (histograms, contextMap) = cluster(sourceHistograms)
		let usesPrefixCode = shouldUsePrefixCode(
			tokenCount: runLength.tokens.count, histograms: costHistograms)
		let logAlphabetSize =
			usesPrefixCode
			? PrefixCodeWriter.prefixMaxBits
			: (runLength.enabled ? 8 : 7)
		let uintConfigurations = [HybridUintConfiguration](
			repeating: dataConfiguration, count: histograms.count)
		let prefixCodes = HistogramCluster.buildPrefixCodes(histograms)
		let ansHistograms = histograms.map {
			ANSEncodingHistogram.computeBest(counts: $0.counts, strategy: .precise)
		}

		var costWriter = BitWriter()
		costWriter.write(1, runLength.enabled ? 1 : 0)
		if runLength.enabled {
			costWriter.write(2, 0)
			costWriter.write(2, 0)
			PrefixCodeWriter.writeUintConfigs(
				[lengthConfiguration], logAlphaSize: 8, writer: &costWriter)
		}
		costWriter.write(1, usesPrefixCode ? 1 : 0)
		if !usesPrefixCode { costWriter.write(2, UInt64(logAlphabetSize - 5)) }
		PrefixCodeWriter.writeUintConfigs(
			uintConfigurations, logAlphaSize: logAlphabetSize, writer: &costWriter)
		if usesPrefixCode {
			for histogram in histograms {
				let alphabetSize = max(
					1,
					(histogram.counts.lastIndex(where: { $0 != 0 }) ?? -1) + 1)
				PrefixCodeWriter.storeVarLenUInt16(
					alphabetSize - 1, writer: &costWriter)
			}
			for (histogram, code) in zip(histograms, prefixCodes) {
				let alphabetSize = max(
					1,
					(histogram.counts.lastIndex(where: { $0 != 0 }) ?? -1) + 1)
				if alphabetSize > 1 {
					PrefixCodeWriter.writePrefixCode(code, writer: &costWriter)
				}
			}
		}
		var estimatedCost = costWriter.bitsWritten
		if usesPrefixCode {
			for (histogram, code) in zip(histograms, prefixCodes) {
				for symbol in histogram.counts.indices {
					estimatedCost +=
						Int(histogram.counts[symbol])
						* (code.isDegenerate ? 0 : Int(code.depths[symbol]))
				}
			}
		} else {
			for histogram in ansHistograms {
				estimatedCost += Int(histogram.cost.rounded(.up))
			}
		}
		return Prepared(
			runLength: runLength, contextMap: contextMap,
			histograms: histograms, uintConfigurations: uintConfigurations,
			usesPrefixCode: usesPrefixCode, logAlphabetSize: logAlphabetSize,
			prefixCodes: prefixCodes, ansHistograms: ansHistograms,
			estimatedCost: estimatedCost)
	}

	static func shouldUsePrefixCode(tokenCount: Int, histograms: [Histogram]) -> Bool {
		tokenCount < 100 || histograms.allSatisfy { $0.bitCost < 1e-5 }
	}

	static func write(_ prepared: Prepared, to writer: inout BitWriter) {
		writer.write(1, prepared.runLength.enabled ? 1 : 0)
		if prepared.runLength.enabled {
			writer.write(2, 0)
			writer.write(2, 0)
			PrefixCodeWriter.writeUintConfigs(
				[
					HybridUintConfiguration(
						splitExponent: 0, msbInToken: 0, lsbInToken: 0)
				],
				logAlphaSize: 8, writer: &writer)
		}
		if prepared.runLength.enabled {
			ContextMapEncoding.write(
				ContextMapEncoding.prepare(
					prepared.contextMap,
					numHistograms: prepared.histograms.count),
				to: &writer)
		}
		writer.write(1, prepared.usesPrefixCode ? 1 : 0)
		if !prepared.usesPrefixCode {
			writer.write(2, UInt64(prepared.logAlphabetSize - 5))
		}
		PrefixCodeWriter.writeUintConfigs(
			prepared.uintConfigurations, logAlphaSize: prepared.logAlphabetSize,
			writer: &writer)
		if prepared.usesPrefixCode {
			for histogram in prepared.histograms {
				let alphabetSize = max(
					1,
					(histogram.counts.lastIndex(where: { $0 != 0 }) ?? -1) + 1)
				PrefixCodeWriter.storeVarLenUInt16(
					alphabetSize - 1, writer: &writer)
			}
			for (histogram, code) in zip(prepared.histograms, prepared.prefixCodes) {
				let alphabetSize = max(
					1,
					(histogram.counts.lastIndex(where: { $0 != 0 }) ?? -1) + 1)
				if alphabetSize > 1 {
					PrefixCodeWriter.writePrefixCode(code, writer: &writer)
				}
			}
			for encoded in prepared.runLength.tokens {
				let histogram = Int(prepared.contextMap[Int(encoded.token.context)])
				let configuration =
					encoded.isLength
					? HybridUintConfiguration(
						splitExponent: 0, msbInToken: 0, lsbInToken: 0)
					: prepared.uintConfigurations[histogram]
				let (baseSymbol, bitCount, bits) = configuration.encode(
					encoded.token.value)
				let symbol = Int(baseSymbol + (encoded.isLength ? 224 : 0))
				let code = prepared.prefixCodes[histogram]
				let depth = code.isDegenerate ? 0 : Int(code.depths[symbol])
				let symbolBits = code.isDegenerate ? 0 : UInt64(code.bits[symbol])
				writer.write(depth, symbolBits)
				writer.write(Int(bitCount), UInt64(bits))
			}
		} else {
			for histogram in prepared.ansHistograms { histogram.write(to: &writer) }
			let tables = prepared.ansHistograms.map { ans in
				ANSInfoTable.build(
					distribution: ans.normalizedCounts,
					alphabetSize: ans.alphabetSize,
					logAlphaSize: prepared.logAlphabetSize)
			}
			ANSTokenWriter.write(
				contextMapTokens: prepared.runLength.tokens,
				contextMap: prepared.contextMap, infoTables: tables,
				uintConfigurations: prepared.uintConfigurations,
				lengthConfiguration: HybridUintConfiguration(
					splitExponent: 0, msbInToken: 0, lsbInToken: 0),
				lengthSymbolOffset: 224, writer: &writer)
		}
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
	/// choice for `contextCount` contexts, so that `write(_:writer:)` followed
	/// by `writeTokens(_:code:writer:)` is what a decoder reads back as
	/// `tokens`. Ports `BuildAndEncodeHistograms` (enc_ans.cc:1060-1180).
	static func prepare(
		_ tokens: [Token], contextCount: Int, parameters: HistogramParameters
	) -> Prepared {
		fatalError("unimplemented")
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
		let raw: ContextMapEntropy.Prepared?
		let moveToFront: ContextMapEntropy.Prepared?
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
		let raw = ContextMapEntropy.prepare(entries)
		let moveToFront = ContextMapEntropy.prepare(transformedEntries)
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
			let entropy: ContextMapEntropy.Prepared
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
			ContextMapEntropy.write(entropy, to: &writer)
		}
	}
}
