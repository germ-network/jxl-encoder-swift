//
//  JPEGBlockContextMap.swift
//  JXLEncoder
//
//  Port of the JPEG-transcode path's adaptive AC block-context assignment,
//  from full libjxl's `ComputeJPEGTranscodingData` (enc_frame.cc),
//  `BlockCtxMap::Context` (ac_context.h), and `EncodeBlockCtxMap` /
//  `EncodeContextMap` (enc_context_map.cc). libjxl-tiny has no JPEG path and
//  no adaptive block context map at all — this has no tiny counterpart; see
//  docs/gap-closure-plan.md.
//
//  Buckets each block by its own luma DC value against per-image thresholds,
//  so AC token contexts split brighter/darker regions instead of sharing one
//  context per channel. Chroma carries no thresholds of its own — every
//  channel's context at a given block position reads the same luma-derived
//  bucket (confirmed at the source: `row_qdc[bx]` is indexed by the
//  full-resolution position, not each channel's own subsampled one), and
//  only the destination *slot* in the context map differs by channel.
//

public enum JPEGBlockContextMap {
	/// AC-strategy-order buckets the wire format reserves regardless of which
	/// orders a frame actually uses (`kNumOrders`, coeff_order_fwd.h). JPEG
	/// transcode only ever emits DCT8 (order 0), so only the first
	/// `numDCContexts` entries of each channel's slot are ever read — the
	/// rest is transmitted padding, not unused code.
	static let numOrders = 13

	/// `Context()`'s channel-to-slot permutation (ac_context.h): luma (1)
	/// takes slot 0, channel 0 takes slot 1, channel 2 keeps slot 2.
	static func slot(forChannel channel: Int) -> Int {
		channel < 2 ? channel ^ 1 : 2
	}

	public struct Result: Sendable {
		/// Ascending luma DC-value thresholds; 1 to 7 of them.
		let thresholds: [Int]
		var numDCContexts: Int { thresholds.count + 1 }
		/// Size `3 * numOrders * numDCContexts`, order-0 slots populated,
		/// the rest left at zero — dead weight the decoder still expects.
		let contextMap: [UInt8]
		let numContexts: Int

		/// How many thresholds a raw luma DC value exceeds (`compressed_dc.cc`'s
		/// `bucket_y` loop — strict `>`, matching encode and decode).
		func bucket(dc: Int32) -> Int {
			var count = 0
			for t in thresholds where dc > Int32(t) { count += 1 }
			return count
		}

		/// The AC block category for one channel at a block whose luma DC
		/// already resolved to `dcBucket`.
		func category(channel: Int, dcBucket: Int) -> Int {
			let base =
				JPEGBlockContextMap.slot(forChannel: channel) * JPEGBlockContextMap.numOrders
				* numDCContexts
			return Int(contextMap[base + dcBucket])
		}
	}

	/// Places 1 to 7 luma DC-value thresholds from a histogram of raw DC
	/// values offset by 1024 (index `j` represents value `j - 1024`, clamped
	/// at the top), so results are directly comparable to hand-computed
	/// cases without a `JPEGTranscode` fixture. Pure port of the threshold
	/// loop in `ComputeJPEGTranscodingData` (enc_frame.cc).
	static func computeThresholds(counts: [Int], total rawTotal: Int, qtSum rawQTSum: Int) -> [Int]
	{
		// Matches `total_dc[c] = 1` for a channel with nothing coded.
		let total = max(rawTotal, 1)
		let numThresholds = min(
			max(
				FrameAssembly.ceilLog2(total) - FrameAssembly.ceilLog2(max(rawQTSum, 1)) - 7,
				1),
			7)

		var result: [Int] = []
		var cumulative = 0
		var cut = total / (numThresholds + 1)
		for j in 0..<counts.count {
			cumulative += counts[j]
			if cumulative > cut {
				result.append(j - 1025)
				cut = total * (result.count + 1) / (numThresholds + 1)
			}
		}
		return result
	}

	/// Computes the thresholds and the composed context map for one
	/// transcode. Luma-only histogram; chroma derives from it at write time
	/// (`compute`'s `ctxMap` construction), never carries its own thresholds.
	static func compute(_ transcode: JPEGTranscode) -> Result {
		let luma = 1
		let width = transcode.blocksPerLine(channel: luma)
		let height = transcode.blocksPerColumn(channel: luma)

		var counts = [Int](repeating: 0, count: 2048)
		var total = 0
		for y in 0..<height {
			for x in 0..<width {
				let dc = Int(transcode.dc(channel: luma, x: x, y: y))
				counts[min(dc + 1024, 2047)] += 1
				total += 1
			}
		}

		let qt = transcode.quantTable(channel: luma)
		let qtSum = Int(qt[1]) + Int(qt[2]) + Int(qt[3]) + Int(qt[4]) + Int(qt[5])
		let thresholds = computeThresholds(counts: counts, total: total, qtSum: qtSum)

		let numDCContexts = thresholds.count + 1
		var contextMap = [UInt8](repeating: 0, count: 3 * numOrders * numDCContexts)
		let lumaBase = slot(forChannel: luma) * numOrders * numDCContexts
		for i in 0..<numDCContexts {
			contextMap[lumaBase + i] = UInt8(i)
		}
		let chromaChannels = [0, 2]
		if transcode.isGrayscale {
			for c in chromaChannels {
				let base = slot(forChannel: c) * numOrders * numDCContexts
				for i in 0..<numDCContexts { contextMap[base + i] = UInt8(numDCContexts) }
			}
		} else {
			// The two chroma slots use different offsets — not interchangeable —
			// matching `ComputeJPEGTranscodingData`'s two literal formulas.
			let firstChromaBase = slot(forChannel: chromaChannels[0]) * numOrders * numDCContexts
			let secondChromaBase = slot(forChannel: chromaChannels[1]) * numOrders * numDCContexts
			for i in 0..<numDCContexts {
				contextMap[firstChromaBase + i] = UInt8(numDCContexts + i / 2)
				contextMap[secondChromaBase + i] =
					UInt8(numDCContexts + (numDCContexts - 1) / 2 + 1 + i / 2)
			}
		}
		let numContexts = Int(contextMap.max() ?? 0) + 1

		return Result(thresholds: thresholds, contextMap: contextMap, numContexts: numContexts)
	}

	/// Port of `kDCThresholdDist` (entropy_coder.h): the 4-way selector code
	/// DC thresholds are written with. `kQFThresholdDist` has no counterpart
	/// here — qf_thresholds is always empty for a JPEG transcode.
	enum ThresholdCoder {
		static func write(_ value: UInt32, writer: inout BitWriter) {
			let (selector, bits, offset): (UInt64, Int, UInt32) =
				switch value {
				case 0..<16: (0, 4, 0)
				case 16..<272: (1, 8, 16)
				case 272..<65808: (2, 16, 272)
				default: (3, 32, 65808)
				}
			writer.write(2, selector)
			writer.write(bits, UInt64(value - offset))
		}
	}

	/// Port of `EncodeBlockCtxMap` (enc_context_map.cc), minus the "this is
	/// exactly the format's built-in default map" shortcut: a JPEG transcode
	/// always signals an adaptive map here, so that branch never applies.
	static func write(_ result: Result, writer: inout BitWriter) {
		writer.write(1, 0)  // not the default map
		for channel in 0..<3 {
			// Only luma carries thresholds; chroma transmits an empty list.
			let thresholds = channel == 1 ? result.thresholds : []
			writer.write(4, UInt64(thresholds.count))
			for t in thresholds {
				ThresholdCoder.write(packSigned(Int32(t)), writer: &writer)
			}
		}
		writer.write(4, 0)  // qf_thresholds: always empty for a transcode
		EntropyCodeWriter.writeContextMapEntries(result.contextMap, writer: &writer)
	}
}

/// Parallel to `ACContext`'s two composition formulas, parameterised by the
/// category count instead of assuming the fixed `numBlockCategories`.
/// `ACContext` itself is untouched, so the pixel path and the JPEG
/// static-table path keep their exact, already-gated behaviour.
enum AdaptiveACContext {
	static func nonZeroContext(nonZeros: Int, blockCategory: Int, numCategories: Int) -> Int {
		let bucket = nonZeros < 8 ? nonZeros : (nonZeros >= 64 ? 36 : 4 + nonZeros / 2)
		return bucket * numCategories + blockCategory
	}

	static func zeroDensityContextsOffset(blockCategory: Int, numCategories: Int) -> Int {
		numCategories * ACContext.nonZeroBuckets + ACContext.zeroDensityCount * blockCategory
	}
}
