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
	static func writeContextMap(_ code: EntropyCode, writer: inout BitWriter) {
		guard code.transmittedContextCount != 0 else { return }

		// A re-clustered code composes with the map it was built from, so the
		// decoder still sees an entry per original context.
		let entries: [UInt8] =
			if let original = code.originalContextMap {
				original.map { code.contextMap[Int($0)] }
			} else {
				code.contextMap
			}
		writeContextMapEntries(entries, writer: &writer)
	}

	/// Writes an array of small integers as an entropy-coded context map —
	/// shared by an entropy code's own map above and, from
	/// `JPEGBlockContextMap`, the JPEG-transcode AC block-context map,
	/// exactly as full libjxl's `EncodeContextMap` serves both callers. Port
	/// of `EncodeContextMap` (enc_context_map.cc) minus the move-to-front
	/// choice, a pure size optimisation not yet ported.
	static func writeContextMapEntries(_ entries: [UInt8], writer: inout BitWriter) {
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
		let mapCode = HistogramCluster.optimizePrefixCodes(
			tokens: tokens, contextMap: [0], prefixCodeCount: 1)

		// A context-map array is always small enough that real libjxl's own
		// token-count threshold would pick prefix coding anyway — this
		// sub-encoding never carries ANS, only the caller's main token
		// stream (below) might.
		writer.write(1, 1)  // use_prefix_code
		PrefixCodeWriter.writePrefixCodes(mapCode.prefixCodes, writer: &writer)
		for token in tokens {
			writer.write(token: token, code: mapCode)
		}
	}

	static func write(_ code: EntropyCode, writer: inout BitWriter) {
		writeContextMap(code, writer: &writer)
		if let ansInfoTables = code.ansInfoTables {
			writer.write(1, 0)  // use_prefix_code = false
			writer.write(2, UInt64(ANSConstants.logAlphaSize - 5))
			PrefixCodeWriter.writeUintConfigs(count: ansInfoTables.count, writer: &writer)
			for table in ansInfoTables {
				ANSHistogramWriter.write(counts: table.map(\.freq), writer: &writer)
			}
		} else {
			writer.write(1, 1)  // use_prefix_code
			PrefixCodeWriter.writePrefixCodes(code.prefixCodes, writer: &writer)
		}
	}
}
