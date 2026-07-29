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

	private static func T(_ context: UInt32, _ value: UInt32) -> Token {
		Token(context: context, value: value)
	}

	/// The reference's fixed context tree, as a token stream.
	static let staticTokens: [Token] = [
		T(1, 2), T(0, 4), T(1, 1), T(0, 2), T(1, 10), T(0, 0),
		T(1, 1), T(0, 4), T(1, 1), T(0, 0), T(1, 10), T(0, 94),
		T(1, 10), T(0, 61), T(1, 0), T(2, 0), T(3, 0), T(4, 0),
		T(5, 0), T(1, 3), T(0, 0), T(1, 0), T(2, 5), T(3, 0),
		T(4, 0), T(5, 0), T(1, 0), T(2, 5), T(3, 0), T(4, 0),
		T(5, 0), T(1, 10), T(0, 382), T(1, 10), T(0, 22), T(1, 10),
		T(0, 13), T(1, 10), T(0, 253), T(1, 8), T(0, 10), T(1, 8),
		T(0, 10), T(1, 10), T(0, 784), T(1, 10), T(0, 190), T(1, 10),
		T(0, 46), T(1, 10), T(0, 10), T(1, 10), T(0, 5), T(1, 10),
		T(0, 29), T(1, 10), T(0, 125), T(1, 10), T(0, 509), T(1, 8),
		T(0, 22), T(1, 8), T(0, 6), T(1, 8), T(0, 22), T(1, 8),
		T(0, 6), T(1, 10), T(0, 1000), T(1, 10), T(0, 510), T(1, 10),
		T(0, 254), T(1, 10), T(0, 126), T(1, 10), T(0, 62), T(1, 10),
		T(0, 30), T(1, 10), T(0, 14), T(1, 10), T(0, 6), T(1, 10),
		T(0, 1), T(1, 10), T(0, 7), T(1, 10), T(0, 21), T(1, 10),
		T(0, 45), T(1, 10), T(0, 93), T(1, 10), T(0, 189), T(1, 10),
		T(0, 381), T(1, 10), T(0, 783), T(1, 0), T(2, 1), T(3, 0),
		T(4, 0), T(5, 0), T(1, 0), T(2, 1), T(3, 0), T(4, 0),
		T(5, 0), T(1, 0), T(2, 1), T(3, 0), T(4, 0), T(5, 0),
		T(1, 0), T(2, 1), T(3, 0), T(4, 0), T(5, 0), T(1, 0),
		T(2, 0), T(3, 0), T(4, 0), T(5, 0), T(1, 0), T(2, 0),
		T(3, 0), T(4, 0), T(5, 0), T(1, 0), T(2, 0), T(3, 0),
		T(4, 0), T(5, 0), T(1, 0), T(2, 0), T(3, 0), T(4, 0),
		T(5, 0), T(1, 0), T(2, 5), T(3, 0), T(4, 0), T(5, 0),
		T(1, 0), T(2, 5), T(3, 0), T(4, 0), T(5, 0), T(1, 0),
		T(2, 5), T(3, 0), T(4, 0), T(5, 0), T(1, 0), T(2, 5),
		T(3, 0), T(4, 0), T(5, 0), T(1, 0), T(2, 5), T(3, 0),
		T(4, 0), T(5, 0), T(1, 0), T(2, 5), T(3, 0), T(4, 0),
		T(5, 0), T(1, 0), T(2, 5), T(3, 0), T(4, 0), T(5, 0),
		T(1, 0), T(2, 5), T(3, 0), T(4, 0), T(5, 0), T(1, 0),
		T(2, 5), T(3, 0), T(4, 0), T(5, 0), T(1, 0), T(2, 5),
		T(3, 0), T(4, 0), T(5, 0), T(1, 0), T(2, 5), T(3, 0),
		T(4, 0), T(5, 0), T(1, 0), T(2, 5), T(3, 0), T(4, 0),
		T(5, 0), T(1, 0), T(2, 5), T(3, 0), T(4, 0), T(5, 0),
		T(1, 0), T(2, 5), T(3, 0), T(4, 0), T(5, 0), T(1, 0),
		T(2, 5), T(3, 0), T(4, 0), T(5, 0), T(1, 10), T(0, 2),
		T(1, 0), T(2, 5), T(3, 0), T(4, 0), T(5, 0), T(1, 0),
		T(2, 5), T(3, 0), T(4, 0), T(5, 0), T(1, 0), T(2, 5),
		T(3, 0), T(4, 0), T(5, 0), T(1, 0), T(2, 5), T(3, 0),
		T(4, 0), T(5, 0), T(1, 0), T(2, 5), T(3, 0), T(4, 0),
		T(5, 0), T(1, 0), T(2, 5), T(3, 0), T(4, 0), T(5, 0),
		T(1, 0), T(2, 5), T(3, 0), T(4, 0), T(5, 0), T(1, 0),
		T(2, 5), T(3, 0), T(4, 0), T(5, 0), T(1, 0), T(2, 5),
		T(3, 0), T(4, 0), T(5, 0), T(1, 0), T(2, 5), T(3, 0),
		T(4, 0), T(5, 0), T(1, 0), T(2, 5), T(3, 0), T(4, 0),
		T(5, 0), T(1, 0), T(2, 5), T(3, 0), T(4, 0), T(5, 0),
		T(1, 0), T(2, 5), T(3, 0), T(4, 0), T(5, 0), T(1, 0),
		T(2, 5), T(3, 0), T(4, 0), T(5, 0), T(1, 0), T(2, 5),
		T(3, 0), T(4, 0), T(5, 0), T(1, 10), T(0, 999), T(1, 0),
		T(2, 5), T(3, 0), T(4, 0), T(5, 0), T(1, 0), T(2, 5),
		T(3, 0), T(4, 0), T(5, 0), T(1, 0), T(2, 5), T(3, 0),
		T(4, 0), T(5, 0), T(1, 0), T(2, 5), T(3, 0), T(4, 0),
		T(5, 0),
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
