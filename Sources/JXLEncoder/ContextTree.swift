//
//  ContextTree.swift
//  JXLEncoder
//
//  Port of `WriteContextTree` and its static token stream from libjxl-tiny's
//  encoder/enc_frame.cc.
//
//  The modular sub-bitstream (DC image and control fields) is decoded through a
//  context tree. This port emits the reference's fixed tree, with one token
//  patched to carry the DC group count, and codes it with a freshly built
//  entropy code — the tree's own token statistics, not the static coefficient
//  tables.
//

enum ContextTree {
	/// Contexts in the tree's own token stream.
	static let treeContextCount = 6

	private static func t(_ context: UInt32, _ value: UInt32) -> Token {
		Token(context: context, value: value)
	}

	/// The reference's fixed context tree, as a token stream.
	static let staticTokens: [Token] = [
		t(1, 2), t(0, 4), t(1, 1), t(0, 2), t(1, 10), t(0, 0),
		t(1, 1), t(0, 4), t(1, 1), t(0, 0), t(1, 10), t(0, 94),
		t(1, 10), t(0, 61), t(1, 0), t(2, 0), t(3, 0), t(4, 0),
		t(5, 0), t(1, 3), t(0, 0), t(1, 0), t(2, 5), t(3, 0),
		t(4, 0), t(5, 0), t(1, 0), t(2, 5), t(3, 0), t(4, 0),
		t(5, 0), t(1, 10), t(0, 382), t(1, 10), t(0, 22), t(1, 10),
		t(0, 13), t(1, 10), t(0, 253), t(1, 8), t(0, 10), t(1, 8),
		t(0, 10), t(1, 10), t(0, 784), t(1, 10), t(0, 190), t(1, 10),
		t(0, 46), t(1, 10), t(0, 10), t(1, 10), t(0, 5), t(1, 10),
		t(0, 29), t(1, 10), t(0, 125), t(1, 10), t(0, 509), t(1, 8),
		t(0, 22), t(1, 8), t(0, 6), t(1, 8), t(0, 22), t(1, 8),
		t(0, 6), t(1, 10), t(0, 1000), t(1, 10), t(0, 510), t(1, 10),
		t(0, 254), t(1, 10), t(0, 126), t(1, 10), t(0, 62), t(1, 10),
		t(0, 30), t(1, 10), t(0, 14), t(1, 10), t(0, 6), t(1, 10),
		t(0, 1), t(1, 10), t(0, 7), t(1, 10), t(0, 21), t(1, 10),
		t(0, 45), t(1, 10), t(0, 93), t(1, 10), t(0, 189), t(1, 10),
		t(0, 381), t(1, 10), t(0, 783), t(1, 0), t(2, 1), t(3, 0),
		t(4, 0), t(5, 0), t(1, 0), t(2, 1), t(3, 0), t(4, 0),
		t(5, 0), t(1, 0), t(2, 1), t(3, 0), t(4, 0), t(5, 0),
		t(1, 0), t(2, 1), t(3, 0), t(4, 0), t(5, 0), t(1, 0),
		t(2, 0), t(3, 0), t(4, 0), t(5, 0), t(1, 0), t(2, 0),
		t(3, 0), t(4, 0), t(5, 0), t(1, 0), t(2, 0), t(3, 0),
		t(4, 0), t(5, 0), t(1, 0), t(2, 0), t(3, 0), t(4, 0),
		t(5, 0), t(1, 0), t(2, 5), t(3, 0), t(4, 0), t(5, 0),
		t(1, 0), t(2, 5), t(3, 0), t(4, 0), t(5, 0), t(1, 0),
		t(2, 5), t(3, 0), t(4, 0), t(5, 0), t(1, 0), t(2, 5),
		t(3, 0), t(4, 0), t(5, 0), t(1, 0), t(2, 5), t(3, 0),
		t(4, 0), t(5, 0), t(1, 0), t(2, 5), t(3, 0), t(4, 0),
		t(5, 0), t(1, 0), t(2, 5), t(3, 0), t(4, 0), t(5, 0),
		t(1, 0), t(2, 5), t(3, 0), t(4, 0), t(5, 0), t(1, 0),
		t(2, 5), t(3, 0), t(4, 0), t(5, 0), t(1, 0), t(2, 5),
		t(3, 0), t(4, 0), t(5, 0), t(1, 0), t(2, 5), t(3, 0),
		t(4, 0), t(5, 0), t(1, 0), t(2, 5), t(3, 0), t(4, 0),
		t(5, 0), t(1, 0), t(2, 5), t(3, 0), t(4, 0), t(5, 0),
		t(1, 0), t(2, 5), t(3, 0), t(4, 0), t(5, 0), t(1, 0),
		t(2, 5), t(3, 0), t(4, 0), t(5, 0), t(1, 10), t(0, 2),
		t(1, 0), t(2, 5), t(3, 0), t(4, 0), t(5, 0), t(1, 0),
		t(2, 5), t(3, 0), t(4, 0), t(5, 0), t(1, 0), t(2, 5),
		t(3, 0), t(4, 0), t(5, 0), t(1, 0), t(2, 5), t(3, 0),
		t(4, 0), t(5, 0), t(1, 0), t(2, 5), t(3, 0), t(4, 0),
		t(5, 0), t(1, 0), t(2, 5), t(3, 0), t(4, 0), t(5, 0),
		t(1, 0), t(2, 5), t(3, 0), t(4, 0), t(5, 0), t(1, 0),
		t(2, 5), t(3, 0), t(4, 0), t(5, 0), t(1, 0), t(2, 5),
		t(3, 0), t(4, 0), t(5, 0), t(1, 0), t(2, 5), t(3, 0),
		t(4, 0), t(5, 0), t(1, 0), t(2, 5), t(3, 0), t(4, 0),
		t(5, 0), t(1, 0), t(2, 5), t(3, 0), t(4, 0), t(5, 0),
		t(1, 0), t(2, 5), t(3, 0), t(4, 0), t(5, 0), t(1, 0),
		t(2, 5), t(3, 0), t(4, 0), t(5, 0), t(1, 0), t(2, 5),
		t(3, 0), t(4, 0), t(5, 0), t(1, 10), t(0, 999), t(1, 0),
		t(2, 5), t(3, 0), t(4, 0), t(5, 0), t(1, 0), t(2, 5),
		t(3, 0), t(4, 0), t(5, 0), t(1, 0), t(2, 5), t(3, 0),
		t(4, 0), t(5, 0), t(1, 0), t(2, 5), t(3, 0), t(4, 0),
		t(5, 0),
	]

	/// Emits the tree. `tokens[1]` encodes how many DC groups follow, so the
	/// stream is patched rather than fully static.
	static func write(dcGroupCount: Int, writer: inout BitWriter) {
		var tokens = staticTokens
		tokens[1] = Token(
			context: tokens[1].context, value: packSigned(Int32(1 + dcGroupCount)))

		let code = HistogramCluster.optimizeEntropyCode(
			tokens: tokens, contextCount: treeContextCount)

		writer.write(1, 1)  // not an empty tree
		writer.write(1, 0)  // no lz77
		EntropyCodeWriter.write(code, writer: &writer)
		for token in tokens {
			writer.write(token: token, code: code)
		}
	}
}
