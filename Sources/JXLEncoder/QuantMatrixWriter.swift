//
//  QuantMatrixWriter.swift
//  JXLEncoder
//
//  Transmits a JPEG's own quantization tables, which a transcode must carry
//  because the coefficients were quantized with them. libjxl-tiny always
//  signals the built-in tables, so this has no counterpart there; the format is
//  `DequantMatricesEncode` and `EncodeQuantTable` from libjxl.
//
//  The table does not ride as a plain array. `kQuantModeRAW` sends a half-float
//  denominator and then an 8x8x3 image through the modular sub-bitstream, so
//  this reuses the tree and entropy machinery the DC groups already use.
//

enum QuantMatrixWriter {
	/// Quant table slots the format defines. All but the first are signalled as
	/// library defaults; only DCT8 carries the JPEG's table.
	static let tableCount = 17
	/// `kLog2NumQuantModes`.
	static let modeBits = 3
	static let modeLibrary: UInt64 = 0
	static let modeRAW: UInt64 = 6

	/// `qtable_den` for an unshifted RAW table. The decoder rebuilds each weight
	/// as `1 / (den * qtable[i])`, so this is what turns a JPEG divisor back into
	/// the 255 x 8 scale JXL works in.
	static let denominator: Float = 1.0 / (8 * 255)

	/// A modular tree of one split and two identical leaves, in pre-order.
	///
	/// A single leaf would be the obvious choice and is rejected: its property
	/// context would carry one symbol, and `DecodeTree` refuses a degenerate
	/// property code as an "infinite tree", since a code that can only produce
	/// an inner node never terminates. Splitting once puts two distinct symbols
	/// in that context — the split's property and the leaves' zero — at a cost
	/// of a handful of bits.
	///
	/// The split is on property 0 against a value no channel index reaches, so
	/// every pixel lands in the same leaf and the two behave as one. Both leaves
	/// predict Zero, sending each value as itself: the table is 64 entries, too
	/// few for a predictor to pay for itself.
	static let leafTree: [Token] = [
		// Inner node: property 0, split value 0.
		Token(context: 1, value: 1),
		Token(context: 0, value: packSigned(0)),
		// Two leaves: property -1, predictor Zero, no offset, multiplier 1.
		Token(context: 1, value: 0),
		Token(context: 2, value: 0),
		Token(context: 3, value: 0),
		Token(context: 4, value: 0),
		Token(context: 5, value: 0),
		Token(context: 1, value: 0),
		Token(context: 2, value: 0),
		Token(context: 3, value: 0),
		Token(context: 4, value: 0),
		Token(context: 5, value: 0),
	]

	/// Writes the quant matrices for a JPEG transcode.
	///
	/// Every slot has to be written once anything is non-default — the format has
	/// no way to say "table 0 only" — so the other sixteen go out as library
	/// entries. Those cost three bits each: the predefined index is written in
	/// zero bits, there being only one predefined table.
	static func writeCustom(
		tables: [[UInt16]], writer: inout BitWriter
	) throws {
		writer.write(1, 0)  // not all default

		// Slot 0 is DCT8, the only strategy this encoder emits.
		writer.write(modeBits, modeRAW)
		try Float16Coder.write(denominator, to: &writer)
		writeTableStream(tables: tables, writer: &writer)

		for _ in 1..<tableCount {
			writer.write(modeBits, modeLibrary)
		}
	}

	/// The 8x8x3 modular image carrying the table.
	static func writeTableStream(tables: [[UInt16]], writer: inout BitWriter) {
		// Group header: a local tree rather than the frame's global one, so this
		// stream stands alone. Bits are use_global_tree, weighted-predictor
		// defaults, then the transform count.
		writer.write(4, 2)

		let treeCode = HistogramCluster.optimizeEntropyCode(
			tokens: leafTree, contextCount: ContextTree.treeContextCount)
		// No "has tree" bit here: inside a group stream `DecodeTree` is entered
		// directly, and that flag belongs to the global-tree path the DC groups
		// use. Writing it desynchronises everything after.
		writer.write(1, 0)  // no lz77
		EntropyCodeWriter.write(treeCode, writer: &writer)
		for token in leafTree { writer.write(token: token, code: treeCode) }

		// The decoder sizes the data histograms as (tree.size() + 1) / 2, and a
		// three-node tree gives two. Both leaves behave alike, so only the first
		// context is ever used; the second still has to be transmitted.
		var tokens: [Token] = []
		tokens.reserveCapacity(3 * 64)
		for channel in 0..<3 {
			for index in 0..<64 {
				tokens.append(
					Token(
						context: 0,
						value: packSigned(Int32(tables[channel][index]))))
			}
		}
		let dataCode = HistogramCluster.optimizeEntropyCode(
			tokens: tokens, contextCount: 2)
		writer.write(1, 0)  // no lz77
		EntropyCodeWriter.write(dataCode, writer: &writer)
		for token in tokens { writer.write(token: token, code: dataCode) }
	}
}
