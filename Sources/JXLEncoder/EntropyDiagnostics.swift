//
//  EntropyDiagnostics.swift
//  JXLEncoder
//
//  Measurement hook for docs/gap-closure-plan.md Phase A: splits the entropy
//  layer's cost into what the emitted prefix codes spend versus the Shannon
//  bound of the same clustered histograms. The difference is what a
//  fractional-bit coder (ANS) could recover without touching the context
//  model; the remainder of any gap to the reference is modeling, not coding.
//
//  Package-visible so the jxlencode measurement executable can subscribe;
//  never part of the library's public surface.
//

import RealModule

package enum EntropyDiagnostics {
	package struct Report: Sendable {
		/// Context count of the base code the section was staged under —
		/// distinguishes the DC and AC reports of one encode.
		package let baseContexts: Int
		package let clusters: Int
		package let tokenCount: Int
		/// Bits the emitted prefix codes spend on token symbols (extra bits and
		/// raw bits excluded — they cost the same under any coder).
		package let prefixSymbolBits: Int
		/// Shannon bound of the same symbols under the same clustering.
		package let entropyBoundBits: Double
		/// Shannon bound when the full context space is clustered directly,
		/// rather than within the base code's buckets — what richer context
		/// modeling could reach with the same tokens.
		package let fullContextClusters: Int
		package let fullContextBoundBits: Double
	}

	/// Diagnostic only: set before a single sequential encode, read inside it.
	package nonisolated(unsafe) static var sink: (@Sendable (Report) -> Void)?

	static func entropyBits(_ histogram: Histogram) -> Double {
		guard histogram.totalCount > 0 else { return 0 }
		let total = Double(histogram.totalCount)
		var bits = 0.0
		for count in histogram.counts where count > 0 {
			bits -= Double(count) * Double.log2(Double(count) / total)
		}
		return bits
	}

	static func report(
		clusters: [Histogram], codes: [PrefixCode], baseContexts: Int,
		fullContextClusters: [Histogram]
	) -> Report {
		var prefixBits = 0
		var boundBits = 0.0
		var tokens = 0
		for (index, histogram) in clusters.enumerated() {
			guard histogram.totalCount > 0 else { continue }
			tokens += histogram.totalCount
			let code = codes[index]
			if !code.isDegenerate {
				for symbol in 0..<histogram.counts.count {
					prefixBits +=
						Int(histogram.counts[symbol]) * Int(code.depths[symbol])
				}
			}
			boundBits += entropyBits(histogram)
		}
		return Report(
			baseContexts: baseContexts,
			clusters: clusters.count,
			tokenCount: tokens,
			prefixSymbolBits: prefixBits,
			entropyBoundBits: boundBits,
			fullContextClusters: fullContextClusters.count,
			fullContextBoundBits: fullContextClusters.reduce(0.0) {
				$0 + entropyBits($1)
			})
	}
}
