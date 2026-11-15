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
	/// `allowANS` only ever applies to the context-map sub-encoding this
	/// writes, never to `code`'s own main token stream (`code.ansInfoTables`
	/// decides that independently, below) — see `writeContextMapEntries`.
	static func writeContextMap(
		_ code: EntropyCode, allowANS: Bool = false, writer: inout BitWriter
	) {
		guard code.transmittedContextCount != 0 else { return }

		// A re-clustered code composes with the map it was built from, so the
		// decoder still sees an entry per original context.
		let entries: [UInt8] =
			if let original = code.originalContextMap {
				original.map { code.contextMap[Int($0)] }
			} else {
				code.contextMap
			}
		writeContextMapEntries(entries, allowANS: allowANS, writer: &writer)
	}

	/// Writes an array of small integers as an entropy-coded context map —
	/// shared by an entropy code's own map above and, from
	/// `JPEGBlockContextMap`, the JPEG-transcode AC block-context map,
	/// exactly as full libjxl's `EncodeContextMap` serves both callers. Port
	/// of `EncodeContextMap` (enc_context_map.cc) minus the move-to-front
	/// choice, a pure size optimisation not yet ported.
	///
	/// `allowANS` must stay `false` for any caller whose context map has to
	/// stay byte-exact against libjxl-tiny's own (ANS-less) reference —
	/// `.staticAC`/`.staticDC`'s 1980/45-entry maps route through here too,
	/// and size alone can't tell those apart from a genuinely large, dynamic,
	/// ANS-eligible map (the optimised AC code's context map is the same
	/// 1980-entry raw space, just re-clustered).
	static func writeContextMapEntries(
		_ entries: [UInt8], allowANS: Bool = false, writer: inout BitWriter
	) {
		guard !entries.isEmpty else { return }

		// When every entry is the same the map carries no information. This is
		// the common case for a re-clustered code on a small image, and it
		// collapses the map to three bits.
		if entries.max() == 0 {
			writer.write(3, 1)  // simple code, 0 bits per entry
			return
		}
		writer.write(3, 0)  // no simple code, no move-to-front, no lz77

		let tokens = entries.map { Token(context: 0, value: UInt32($0)) }

		if allowANS && entries.count >= SectionOptimizer.ansMinimumTokens {
			let histogram = HistogramCluster.buildHistograms(
				tokens: tokens, contextMap: [0], contextCount: 1)[0]
			let selected = ANSEncodingHistogram.computeBest(
				counts: histogram.counts, strategy: .precise)
			let infoTable = ANSInfoTable.build(
				distribution: selected.normalizedCounts,
				alphabetSize: selected.alphabetSize,
				logAlphaSize: ANSConstants.logAlphaSize)
			writer.write(1, 0)  // use_prefix_code = false
			writer.write(2, UInt64(ANSConstants.logAlphaSize - 5))
			PrefixCodeWriter.writeUintConfigs(
				count: 1, logAlphaSize: ANSConstants.logAlphaSize, writer: &writer)
			selected.write(to: &writer)
			ANSTokenWriter.write(
				tokens: tokens, contextMap: [0], infoTables: [infoTable],
				writer: &writer)
			return
		}

		let mapCode = HistogramCluster.optimizePrefixCodes(
			tokens: tokens, contextMap: [0], prefixCodeCount: 1)
		writer.write(1, 1)  // use_prefix_code
		PrefixCodeWriter.writePrefixCodes(mapCode.prefixCodes, writer: &writer)
		for token in tokens {
			writer.write(token: token, code: mapCode)
		}
	}

	static func write(
		_ code: EntropyCode, allowContextMapANS: Bool = false, writer: inout BitWriter
	) {
		writeContextMap(code, allowANS: allowContextMapANS, writer: &writer)
		if let histograms = code.ansHistograms {
			writer.write(1, 0)  // use_prefix_code = false
			writer.write(2, UInt64(ANSConstants.logAlphaSize - 5))
			PrefixCodeWriter.writeUintConfigs(
				count: histograms.count, logAlphaSize: ANSConstants.logAlphaSize,
				writer: &writer)
			for histogram in histograms {
				histogram.write(to: &writer)
			}
		} else if let ansInfoTables = code.ansInfoTables {
			writer.write(1, 0)  // use_prefix_code = false
			writer.write(2, UInt64(ANSConstants.logAlphaSize - 5))
			PrefixCodeWriter.writeUintConfigs(
				count: ansInfoTables.count, logAlphaSize: ANSConstants.logAlphaSize,
				writer: &writer)
			for table in ansInfoTables {
				ANSHistogramWriter.write(counts: table.map(\.freq), writer: &writer)
			}
		} else {
			writer.write(1, 1)  // use_prefix_code
			PrefixCodeWriter.writePrefixCodes(code.prefixCodes, writer: &writer)
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

			let symbol = dataConfig.encode(UInt32(entries[index])).symbol
			var repeatedCost: Float = 0
			for _ in 0..<repeatCount {
				repeatedCost += symbolCosts[Int(symbol)]
				repeatedCost += Float(
					dataConfig.encode(UInt32(entries[index])).bitCount)
			}
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

		guard bitDecrease > Float(entries.count) * 0.2 + 16 else {
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
		let usesPrefixCode =
			runLength.tokens.count < 100
			|| costHistograms.allSatisfy {
				$0.totalCount == 0 || $0.bitCost / Float($0.totalCount) < 1e-5
			}
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
			for (histogram, code) in zip(histograms, prefixCodes) {
				let alphabetSize = max(
					1,
					(histogram.counts.lastIndex(where: { $0 != 0 }) ?? -1) + 1)
				PrefixCodeWriter.storeVarLenUInt16(
					alphabetSize - 1, writer: &costWriter)
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
						* Int(code.depths[symbol])
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
			for (histogram, code) in zip(prepared.histograms, prepared.prefixCodes) {
				let alphabetSize = max(
					1,
					(histogram.counts.lastIndex(where: { $0 != 0 }) ?? -1) + 1)
				PrefixCodeWriter.storeVarLenUInt16(
					alphabetSize - 1, writer: &writer)
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
				writer.write(Int(code.depths[symbol]), UInt64(code.bits[symbol]))
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
