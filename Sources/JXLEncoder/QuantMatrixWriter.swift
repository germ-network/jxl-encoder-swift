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

	/// A modular tree of one leaf: no split, predictor Zero, no offset or
	/// multiplier. Contexts 1 through 5 are property+1, predictor, offset,
	/// multiplier log and multiplier bits — property 0 meaning "leaf".
	///
	/// Zero prediction sends each value as itself. For 64 entries that costs
	/// less than a predictor would save, and it keeps the tree trivially valid.
	static let leafTree: [Token] = [
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
		writer.write(1, 1)  // not an empty tree
		writer.write(1, 0)  // no lz77
		EntropyCodeWriter.write(treeCode, writer: &writer)
		for token in leafTree { writer.write(token: token, code: treeCode) }

		// One leaf means one context: the decoder sizes the histograms as
		// (tree.size() + 1) / 2.
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
			tokens: tokens, contextCount: 1)
		writer.write(1, 0)  // no lz77
		EntropyCodeWriter.write(dataCode, writer: &writer)
		for token in tokens { writer.write(token: token, code: dataCode) }
	}
}
