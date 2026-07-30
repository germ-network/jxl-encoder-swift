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
enum StagedRecord {
	/// `context` is already mapped through the base code's context map, so it
	/// indexes a prefix code rather than the full context space.
	case token(mappedContext: UInt8, value: UInt32)
	case rawBits(count: Int, value: UInt64)
}

public struct SectionWriter {
	public enum Mode {
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
		case .staging(let base):
			staged.append(
				.token(
					mappedContext: base.contextMap[Int(token.context)],
					value: token.value))
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

	/// Replays staged records through a finished code. Contexts were already
	/// mapped when staged, so the replay code's map must be the identity over
	/// the staged range.
	mutating func flush(code: EntropyCode) {
		guard case .staging = mode else { return }
		for record in staged {
			switch record {
			case .token(let mappedContext, let value):
				writer.write(
					token: Token(context: UInt32(mappedContext), value: value),
					code: code)
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
	/// Builds a code from every staged token across a set of sections, then
	/// replays them through it.
	///
	/// Re-optimisation happens *within* the base code's grouping: staged
	/// contexts already index one of its prefix codes, so this reclusters those
	/// buckets rather than the full context space. Buckets the image never used
	/// collapse away, which is most of them on a thumbnail.
	static func optimize(
		sections: inout [SectionWriter],
		range: Range<Int>,
		baseCode: EntropyCode
	) -> EntropyCode {
		var histograms = [Histogram](
			repeating: Histogram(), count: baseCode.prefixCodeCount)

		for index in range {
			for record in sections[index].staged {
				guard case .token(let mappedContext, let value) = record else {
					continue
				}
				let (symbol, _, _) = UintCoder.encode(value)
				histograms[Int(mappedContext)].add(symbol)
			}
		}

		let (clusters, contextMap) = HistogramCluster.cluster(histograms)
		// The decoder needs a map over the original context space, so the two
		// maps compose when the code is written out.
		let optimized = EntropyCode(
			contextMap: contextMap,
			prefixCodes: HistogramCluster.buildPrefixCodes(clusters),
			originalContextMap: baseCode.contextMap)

		for index in range {
			sections[index].flush(code: optimized)
		}
		return optimized
	}
}
