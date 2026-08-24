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
	case rawBits(count: Int, value: UInt64)
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
			staged.append(.rawBits(count: count, value: value))
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
						token: Token(context: context, value: value), code: code)
				case .rawBits(let count, let value):
					writer.write(count, value)
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
			tokens: tokens, contextMap: contextMap, infoTables: infoTables, writer: &writer)
	}

	public func finished() -> BitWriter { writer }
}

enum SectionOptimizer {
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
	/// Real libjxl's own `total_tokens < 100` threshold (enc_ans.cc) for
	/// preferring prefix coding: ANS's histogram-signaling overhead isn't
	/// worth it below this, so small sections and small images are
	/// unaffected by ANS being available at all.
	static let ansMinimumTokens = 100

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

		// `allowANS` alone isn't the real invariant — `flushANS` can only
		// replay a section that staged nothing but tokens, so that's derived
		// from what was actually staged rather than trusted from the caller.
		let ansInfoTables: [[ANSEncSymbolInfo]]? =
			allowANS && !hasRawBits && totalTokens >= ansMinimumTokens
			? clusters.map { histogram in
				let counts = ANSHistogramNormalizer.normalize(histogram.counts)
				let alphabetSize = ANSHistogramWriter.alphabetSize(for: counts)
				return ANSInfoTable.build(
					distribution: counts, alphabetSize: alphabetSize,
					logAlphaSize: ANSConstants.logAlphaSize)
			} : nil

		// Building the real Huffman trees is wasted work whenever ANS is
		// selected — `EntropyCode`'s own prefixCodes go unused for encoding
		// in that case — except diagnostics still need them to measure
		// prefix-coded bits against the Shannon bound.
		let prefixCodes: [PrefixCode] =
			ansInfoTables == nil || EntropyDiagnostics.sink != nil
			? HistogramCluster.buildPrefixCodes(clusters) : []

		// `contextMap` already spans the full raw context space — no base-code
		// composition needed, unlike the pre-bucketed approach this replaced.
		let optimized = EntropyCode(
			contextMap: contextMap,
			prefixCodes: prefixCodes,
			ansInfoTables: ansInfoTables)

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
