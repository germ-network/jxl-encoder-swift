//
//  EntropyDiagnostics.swift
//  JXLEncoder
//
//  Measurement hook for docs/gap-closure-plan.md: reports what the emitted
//  prefix codes spend on token symbols against the Shannon bound of the same
//  clustered histograms (extra bits and raw bits excluded — they cost the
//  same under any coder). The difference is what a fractional-bit coder
//  (ANS) could still recover without touching the context model.
//
//  Package-visible so the jxlencode measurement executable can subscribe;
//  never part of the library's public surface.
//

import RealModule

package enum EntropyDiagnostics {
	package struct Report: Sendable {
		/// Raw context space the clustering ran over — distinguishes the DC
		/// and AC reports of one encode.
		package let baseContexts: Int
		package let clusters: Int
		package let tokenCount: Int
		package let prefixSymbolBits: Int
		package let entropyBoundBits: Double
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
		clusters: [Histogram], codes: [PrefixCode], baseContexts: Int
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
						Int(histogram.counts[symbol])
						* Int(code.depths[symbol])
				}
			}
			boundBits += entropyBits(histogram)
		}
		return Report(
			baseContexts: baseContexts,
			clusters: clusters.count,
			tokenCount: tokens,
			prefixSymbolBits: prefixBits,
			entropyBoundBits: boundBits)
	}
}
