//
//  SectionWriter.swift
//  JXLEncoder
//
//  Lets a section be written either straight out with a fixed entropy code, or
//  staged so the code can be optimised for the image before anything is
//  emitted.
//
//  Optimising is worth a lot on small images: the static tables ship in full on
//  every file, roughly a 1 kB floor, which dominates a thumbnail. Per-image
//  codes drop the contexts the image never used.
//

/// One entry in a staged section: either a token to be entropy coded once the
/// code is known, or bits that bypass entropy coding.
enum StagedRecord: Sendable {
	/// The token's original context, unmapped — mapping through the base
	/// code's context map happens when the optimized code is built, so the
	/// full context space stays measurable until then.
	case token(context: UInt32, value: UInt32)
	/// `value` is declared before `count` on purpose: the 8-byte-aligned
	/// `UInt64` must come first for the case to pack into a 16-byte stride
	/// (`count` first leaves it at 24, the same as an `Int` count — a no-op).
	/// `count` is a bit width, always ≤ 64 here, so `UInt8` is ample.
	case rawBits(value: UInt64, count: UInt8)
}

public struct SectionWriter: Sendable {
	public enum Mode: Sendable {
		/// Emit immediately with a code fixed in advance.
		case direct(EntropyCode)
		/// Record, so a code can be built from the actual statistics. The
		/// associated code supplies the context map used while staging.
		case staging(EntropyCode)
	}

	var mode: Mode
	var writer = BitWriter()
	var staged: [StagedRecord] = []

	public init(mode: Mode) {
		self.mode = mode
	}

	/// Wraps bits produced elsewhere, for sections written directly rather than
	/// through the token path.
	init(prewritten: BitWriter) {
		mode = .direct(.staticAC)
		writer = prewritten
	}

	public var bitsWritten: Int { writer.bitsWritten }

	mutating func write(token: Token) {
		switch mode {
		case .direct(let code):
			writer.write(token: token, code: code)
		case .staging:
			staged.append(.token(context: token.context, value: token.value))
		}
	}

	/// Bits that are part of the section but not entropy coded — section
	/// headers and the like.
	mutating func writeRaw(_ count: Int, _ value: UInt64) {
		switch mode {
		case .direct:
			writer.write(count, value)
		case .staging:
			staged.append(.rawBits(value: value, count: UInt8(count)))
		}
	}

	/// Replays staged records through a finished code, whose context map must
	/// span the full context space the tokens were staged with.
	mutating func flush(code: EntropyCode) {
		guard case .staging = mode else { return }
		if let infoTables = code.ansInfoTables {
			flushANS(contextMap: code.contextMap, infoTables: infoTables)
		} else {
			for record in staged {
				switch record {
				case .token(let context, let value):
					writer.write(
						token: Token(context: context, value: value),
						code: code)
				case .rawBits(let value, let count):
					writer.write(Int(count), value)
				}
			}
		}
		staged = []
		mode = .direct(code)
	}

	/// ANS requires the whole token stream up front (it encodes in reverse),
	/// unlike the prefix path's one-token-at-a-time replay above — so this
	/// only holds for a section whose `staged` records are all tokens.
	/// `SectionOptimizer` only calls it for AC sections, which are: DC
	/// sections interleave raw header bits with tokens
	/// (`DCGroupEncoder.write`), which ANS cannot split mid-stream.
	private mutating func flushANS(contextMap: [UInt8], infoTables: [[ANSEncSymbolInfo]]) {
		var tokens: [Token] = []
		tokens.reserveCapacity(staged.count)
		for record in staged {
			switch record {
			case .token(let context, let value):
				tokens.append(Token(context: context, value: value))
			case .rawBits:
				preconditionFailure("ANS sections must not interleave raw bits")
			}
		}
		ANSTokenWriter.write(
			tokens: tokens, contextMap: contextMap, infoTables: infoTables,
			writer: &writer)
	}

	public func finished() -> BitWriter { writer }
}

enum SectionOptimizer {
	static func modularCode(
		tokenStreams: [[Token]], contextCount: Int, extraDCPrecision: UInt8
	) -> EntropyCode {
		precondition(contextCount > 0)
		let tokens = tokenStreams.flatMap { $0 }
		let defaultConfiguration = HybridUintConfiguration(
			splitExponent: 4, msbInToken: 2, lsbInToken: 0)
		func histograms(_ configurations: [HybridUintConfiguration]) -> [Histogram] {
			var result = [Histogram](repeating: Histogram(), count: contextCount)
			for token in tokens {
				let symbol = configurations[Int(token.context)].encode(token.value)
					.symbol
				precondition(symbol < 256)
				result[Int(token.context)].add(symbol)
			}
			return result
		}

		let source = histograms(
			[HybridUintConfiguration](
				repeating: defaultConfiguration, count: contextCount))
		let usePrefix = usesPrefixCode(
			originalHistograms: source, totalTokens: tokens.count)
		let (initialClusters, symbols) = HistogramCluster.fastCluster(
			source, maxHistograms: Self.clustersLimit)
		let initial = HistogramCluster.reindex(symbols: symbols, clusters: initialClusters)
		let defaultCandidates = [
			defaultConfiguration,
			HybridUintConfiguration(splitExponent: 4, msbInToken: 1, lsbInToken: 2),
			HybridUintConfiguration(splitExponent: 0, msbInToken: 0, lsbInToken: 0),
			HybridUintConfiguration(splitExponent: 2, msbInToken: 0, lsbInToken: 1),
		]
		let candidates = extraDCPrecision == 0 ? [defaultConfiguration] : defaultCandidates
		let alphaForSignaling = ANSConstants.logAlphaSize
		var configurations = [HybridUintConfiguration](
			repeating: defaultConfiguration, count: initial.clusters.count)
		for histogramIndex in initial.clusters.indices where extraDCPrecision != 0 {
			var bestCost = Float.greatestFiniteMagnitude
			for candidate in candidates {
				var counts = Histogram()
				var extraBitCost: Float = 0
				var valid = true
				for token in tokens
				where Int(initial.contextMap[Int(token.context)]) == histogramIndex
				{
					let encoded = candidate.encode(token.value)
					guard encoded.symbol < 256 else {
						valid = false
						break
					}
					counts.add(encoded.symbol)
					extraBitCost += Float(encoded.bitCount)
				}
				guard valid else { continue }
				var configWriter = BitWriter()
				PrefixCodeWriter.writeUintConfigs(
					[candidate], logAlphaSize: alphaForSignaling,
					writer: &configWriter)
				let cost =
					ANSEncodingHistogram.computeBest(
						counts: counts.counts, strategy: .fast
					).cost
					+ extraBitCost + Float(configWriter.bitsWritten)
				if cost < bestCost {
					bestCost = cost
					configurations[histogramIndex] = candidate
				}
			}
		}
		let contextConfigurations = initial.contextMap.map { configurations[Int($0)] }
		let sourceByContext = histograms(contextConfigurations)
		let finalHistograms = initial.contextMap.indices.reduce(
			[Histogram](repeating: Histogram(), count: configurations.count)
		) { current, context in
			var updated = current
			updated[Int(initial.contextMap[context])].add(sourceByContext[context])
			return updated
		}
		let result = (clusters: finalHistograms, contextMap: initial.contextMap)
		var maxSymbol: UInt32 = 0
		for token in tokens {
			let histogram = Int(result.contextMap[Int(token.context)])
			maxSymbol = max(
				maxSymbol, configurations[histogram].encode(token.value).symbol)
		}
		let logAlpha =
			usePrefix
			? PrefixCodeWriter.prefixMaxBits
			: (extraDCPrecision == 0
				? 7
				: min(8, max(5, ceilLog2Nonzero(Int(maxSymbol) + 1))))
		let ansHistograms: [ANSEncodingHistogram]? =
			usePrefix
			? nil
			: result.clusters.map {
				ANSEncodingHistogram.computeBest(
					counts: $0.counts, strategy: .approximate)
			}
		let prefixCodes = HistogramCluster.buildPrefixCodes(result.clusters)
		let selectedConfigurations = extraDCPrecision == 0 ? nil : configurations
		var code: EntropyCode
		if let ansHistograms {
			code = EntropyCode(
				contextMap: result.contextMap, prefixCodes: prefixCodes,
				ansHistograms: ansHistograms,
				uintConfigurations: selectedConfigurations,
				logAlphabetSize: logAlpha)
		} else {
			code = EntropyCode(
				contextMap: result.contextMap, prefixCodes: prefixCodes,
				uintConfigurations: selectedConfigurations,
				logAlphabetSize: logAlpha)
		}
		return code
	}

	/// libjxl's cluster limit (`kClustersLimit`, enc_context_map.h). Tiny's
	/// static tables pre-bucket the raw context space down to as few as 8
	/// entries before optimisation ever runs; clustering at the reference's
	/// own limit, directly over the tokens' original contexts, is rung 1's
	/// single largest recovered gap — see docs/gap-closure-plan.md Phase A/B.
	static let clustersLimit = 128

	/// Builds a code from every staged token across a set of sections, then
	/// replays them through it.
	///
	/// Clusters the *full* raw context space the tokens were staged with, not
	/// the base code's static buckets — the base code only supplied that
	/// space's size and is otherwise unused here. Contexts the image never
	/// used collapse away, which is most of them on a thumbnail, and contexts
	/// tiny's static tables would have pre-merged stay separable until the
	/// image's own statistics say otherwise.
	/// libjxl keeps prefix coding for short sections and when every original
	/// context has entropy below 1e-5.
	static let ansMinimumTokens = 100

	static func usesPrefixCode(
		originalHistograms: [Histogram], totalTokens: Int
	) -> Bool {
		guard totalTokens >= ansMinimumTokens else { return true }
		return originalHistograms.allSatisfy { original in
			var histogram = original
			histogram.computeBitCost()
			return histogram.bitCost < 1e-5
		}
	}

	static func optimize(
		sections: inout [SectionWriter],
		range: Range<Int>,
		baseCode: EntropyCode,
		/// Only ever true for the AC groups' entropy code — DC sections
		/// interleave raw header bits with tokens (`DCGroupEncoder.write`),
		/// which ANS cannot split mid-stream; see `SectionWriter.flushANS`.
		allowANS: Bool = false
	) -> EntropyCode {
		var histograms = [Histogram](
			repeating: Histogram(), count: baseCode.contextCount)
		var totalTokens = 0
		var hasRawBits = false

		for index in range {
			for record in sections[index].staged {
				switch record {
				case .token(let context, let value):
					totalTokens += 1
					let (symbol, _, _) = UintCoder.encode(value)
					histograms[Int(context)].add(symbol)
				case .rawBits:
					hasRawBits = true
				}
			}
		}

		let (clusters, contextMap) = HistogramCluster.cluster(
			histograms, limit: clustersLimit)
		let usePrefixCode = usesPrefixCode(
			originalHistograms: histograms, totalTokens: totalTokens)

		// `allowANS` alone isn't the real invariant — `flushANS` can only
		// replay a section that staged nothing but tokens, so that's derived
		// from what was actually staged rather than trusted from the caller.
		let ansHistograms: [ANSEncodingHistogram]? =
			allowANS && !hasRawBits && !usePrefixCode
			? clusters.map { histogram in
				ANSEncodingHistogram.computeBest(
					counts: histogram.counts, strategy: .approximate)
			} : nil
		// Building the real Huffman trees is wasted work whenever ANS is
		// selected — `EntropyCode`'s own prefixCodes go unused for encoding
		// in that case — except diagnostics still need them to measure
		// prefix-coded bits against the Shannon bound.
		let prefixCodes: [PrefixCode] =
			ansHistograms == nil || EntropyDiagnostics.sink != nil
			? HistogramCluster.buildPrefixCodes(clusters) : []

		// `contextMap` already spans the full raw context space — no base-code
		// composition needed, unlike the pre-bucketed approach this replaced.
		let optimized: EntropyCode
		if let ansHistograms {
			optimized = EntropyCode(
				contextMap: contextMap, prefixCodes: prefixCodes,
				ansHistograms: ansHistograms)
		} else {
			optimized = EntropyCode(
				contextMap: contextMap, prefixCodes: prefixCodes)
		}

		if let sink = EntropyDiagnostics.sink {
			sink(
				EntropyDiagnostics.report(
					clusters: clusters, codes: prefixCodes,
					baseContexts: baseCode.contextCount))
		}

		for index in range {
			sections[index].flush(code: optimized)
		}
		return optimized
	}
}
