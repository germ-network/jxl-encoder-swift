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
		guard code.contextCount != 0 else { return }

		// When every context shares one code the map carries no information.
		if code.contextMap.max() == 0 {
			writer.write(3, 1)  // simple code, 0 bits per entry
			return
		}
		writer.write(3, 0)  // no simple code, no move-to-front, no lz77

		let tokens = code.contextMap.map { Token(context: 0, value: UInt32($0)) }
		let mapCode = HistogramCluster.optimizePrefixCodes(
			tokens: tokens, contextMap: [0], prefixCodeCount: 1)

		PrefixCodeWriter.writePrefixCodes(mapCode.prefixCodes, writer: &writer)
		for token in tokens {
			writer.write(token: token, code: mapCode)
		}
	}

	static func write(_ code: EntropyCode, writer: inout BitWriter) {
		writeContextMap(code, writer: &writer)
		PrefixCodeWriter.writePrefixCodes(code.prefixCodes, writer: &writer)
	}
}
