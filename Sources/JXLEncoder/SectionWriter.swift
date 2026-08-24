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
		for record in staged {
			switch record {
			case .token(let context, let value):
				writer.write(
					token: Token(context: context, value: value), code: code)
			case .rawBits(let count, let value):
				writer.write(count, value)
			}
		}
		staged = []
		mode = .direct(code)
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
	static func optimize(
		sections: inout [SectionWriter],
		range: Range<Int>,
		baseCode: EntropyCode
	) -> EntropyCode {
		var histograms = [Histogram](
			repeating: Histogram(), count: baseCode.contextCount)

		for index in range {
			for record in sections[index].staged {
				guard case .token(let context, let value) = record else {
					continue
				}
				let (symbol, _, _) = UintCoder.encode(value)
				histograms[Int(context)].add(symbol)
			}
		}

		let (clusters, contextMap) = HistogramCluster.cluster(
			histograms, limit: clustersLimit)
		// `contextMap` already spans the full raw context space — no base-code
		// composition needed, unlike the pre-bucketed approach this replaced.
		let optimized = EntropyCode(
			contextMap: contextMap,
			prefixCodes: HistogramCluster.buildPrefixCodes(clusters))

		if let sink = EntropyDiagnostics.sink {
			sink(
				EntropyDiagnostics.report(
					clusters: clusters, codes: optimized.prefixCodes,
					baseContexts: baseCode.contextCount))
		}

		for index in range {
			sections[index].flush(code: optimized)
		}
		return optimized
	}
}
