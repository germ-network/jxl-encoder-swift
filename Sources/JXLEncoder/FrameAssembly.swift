//
//  FrameAssembly.swift
//  JXLEncoder
//
//  Port of the frame-level writers and section assembly from libjxl-tiny's
//  encoder/enc_frame.cc: `WriteFrameHeader`, `WriteQuantScales`,
//  `WriteDCGlobal`, `WriteACGlobal`, `WriteTOC` and `CombineSections`.
//
//  A frame is a header followed by a table of contents and then independently
//  decodable sections: DC global, one per DC group, AC global, one per AC group.
//

enum FrameAssembly {
	/// How the frame's colour is coded, which decides three things in the frame
	/// header: whether a colour-transform bit appears at all, whether chroma
	/// subsampling follows it, and whether the quant-matrix scales are written.
	public enum ColorMode: Equatable, Sendable {
		/// XYB, the pixel path. The image header's `xyb_encoded` bit already says
		/// so, so the frame header carries no colour-transform field.
		case xyb(xQuantMatrixScale: UInt32)
		/// YCbCr, carrying a JPEG's own coefficients. The scales are XYB-only and
		/// must be left out, not written as their defaults.
		case ycbcr(subsampling: ChromaSubsampling)
	}

	static func writeFrameHeader(
		colorMode: ColorMode, epfIterations: UInt32, writer: inout BitWriter
	) {
		writer.write(1, 0)  // not all default
		writer.write(2, 0)  // regular frame
		writer.write(1, 0)  // vardct
		writer.write(2, 2)  // flags selector bits (17 .. 272)
		writer.write(8, 111)  // skip adaptive dc flag (128)

		// Only present when the image header said `xyb_encoded` is false: the
		// bit chooses YCbCr over none.
		if case .ycbcr(let subsampling) = colorMode {
			writer.write(1, 1)  // alternate: YCbCr
			subsampling.write(to: &writer)
		}

		writer.write(2, 0)  // no upsampling
		if case .xyb(let xQuantMatrixScale) = colorMode {
			writer.write(3, UInt64(xQuantMatrixScale))
			writer.write(3, 2)  // b_qm_scale
		}
		writer.write(2, 0)  // one pass
		writer.write(1, 0)  // no custom frame size or origin
		writer.write(2, 0)  // replace blend mode
		writer.write(1, 1)  // last frame
		writer.write(2, 0)  // no name

		if epfIterations == 2 {
			writer.write(1, 1)  // default loop filter
		} else {
			writer.write(1, 0)  // not default loop filter
			writer.write(1, 0)  // no gaborish
			writer.write(2, UInt64(epfIterations))
			if epfIterations > 0 {
				writer.write(1, 0)  // default epf sharpness
				writer.write(1, 0)  // default epf weights
				writer.write(1, 0)  // default epf sigma
			}
			writer.write(2, 0)  // no loop filter extensions
		}
		writer.write(2, 0)  // no frame header extensions
	}

	/// `kGlobalScaleDenom`. A transcode uses this with `quantDC = 1` so that
	/// `InvGlobalScale()` is exactly 1 and the quant field stays uniform — the
	/// JPEG's own tables carry all the quantization.
	static let jpegGlobalScale = 1 << 16

	/// Both scales use a selector plus a variable-width offset.
	static func writeQuantScales(
		globalScale: Int, quantDC: Int, writer: inout BitWriter
	) {
		if globalScale < 2049 {
			writer.write(2, 0)
			writer.write(11, UInt64(globalScale - 1))
		} else if globalScale < 4097 {
			writer.write(2, 1)
			writer.write(11, UInt64(globalScale - 2049))
		} else if globalScale < 8193 {
			writer.write(2, 2)
			writer.write(12, UInt64(globalScale - 4097))
		} else {
			writer.write(2, 3)
			writer.write(16, UInt64(globalScale - 8193))
		}

		if quantDC == 16 {
			writer.write(2, 0)
		} else if quantDC < 33 {
			writer.write(2, 1)
			writer.write(5, UInt64(quantDC - 1))
		} else if quantDC < 257 {
			writer.write(2, 2)
			writer.write(8, UInt64(quantDC - 1))
		} else {
			writer.write(2, 3)
			writer.write(16, UInt64(quantDC - 1))
		}
	}

	static func writeDCGlobal(
		params: DistanceParams,
		dcGroupCount: Int,
		code: EntropyCode,
		/// Per-channel DC quantization for a JPEG transcode, `255 * 8 / quant[0]`.
		/// Nil on the pixel path, which uses the built-in values.
		dcQuantization: [Float]? = nil,
		/// Overrides the distance-derived scales, which a transcode does not use.
		globalScale: Int? = nil,
		quantDC: Int? = nil,
		writer: inout BitWriter
	) throws {
		if let dcQuantization {
			// `DequantMatricesEncodeDC`: the flag, then three half floats scaled
			// by 128.
			//
			// What goes on the wire is the *reciprocal* of the step. `SetDCQuant`
			// stores `1 / dc[c]` and the encoder writes that, so passing the step
			// itself overflows the half-float range as soon as the JPEG's DC
			// divisor is small — a high-quality source, exactly where it matters.
			writer.write(1, 0)  // not default dequant dc
			for channel in 0..<3 {
				try Float16Coder.write(128 / dcQuantization[channel], to: &writer)
			}
		} else {
			writer.write(1, 1)  // default dequant dc
		}
		writeQuantScales(
			globalScale: globalScale ?? params.globalScale,
			quantDC: quantDC ?? params.quantDC, writer: &writer)
		writer.write(1, 0)  // non-default block context map
		writer.write(16, 0)  // no dc context, no quant field table

		// The compact block context map has no prefix codes of its own; only its
		// context map is transmitted.
		let blockContextCode = EntropyCode(
			contextMap: ACContext.compactBlockIndexMap, prefixCodes: [])
		EntropyCodeWriter.writeContextMap(blockContextCode, writer: &writer)

		if dcQuantization != nil {
			// The default colour correlation is `base_correlation_b = kYToBRatio`,
			// which is 1.0: the decoder adds a whole luma block to channel 2.
			// That is right for XYB, where B really does track Y, and wrong for
			// Cr — accepting the default leaves every coefficient correct and the
			// chroma reconstructed against the wrong reference.
			writer.write(1, 0)  // not default DC cmap
			writer.write(2, 0)  // colour factor: the default
			try Float16Coder.write(0, to: &writer)  // base correlation X
			try Float16Coder.write(0, to: &writer)  // base correlation B
			writer.write(8, 128)  // ytox_dc = 0, offset by -128
			writer.write(8, 128)  // ytob_dc = 0
		} else {
			writer.write(1, 1)  // default DC cmap
		}
		ContextTree.write(dcGroupCount: dcGroupCount, writer: &writer)
		writer.write(1, 0)  // no lz77
		EntropyCodeWriter.write(code, writer: &writer)
	}

	static func writeACGlobal(
		groupCount: Int, code: EntropyCode,
		/// A JPEG's own tables, already transposed. Nil on the pixel path, which
		/// signals the built-in ones.
		quantTables: [[UInt16]]? = nil,
		writer: inout BitWriter
	) throws {
		if let quantTables {
			try QuantMatrixWriter.writeCustom(tables: quantTables, writer: &writer)
		} else {
			writer.write(1, 1)  // all default quant matrices
		}
		let histogramBits = ceilLog2(groupCount)
		if histogramBits != 0 { writer.write(histogramBits, 0) }
		writer.write(2, 3)
		writer.write(13, 0)  // all default coefficient order
		writer.write(1, 0)  // no lz77
		EntropyCodeWriter.write(code, writer: &writer)
	}

	static func ceilLog2(_ n: Int) -> Int {
		n <= 1 ? 0 : (Int.bitWidth - (n - 1).leadingZeroBitCount)
	}

	/// Section sizes, so a decoder can seek to any section without parsing the
	/// ones before it.
	static func writeTOC(sections: [BitWriter], writer: inout BitWriter) {
		writer.write(1, 0)  // no permutation
		writer.zeroPadToByte()

		let widths = [10, 14, 22, 30]
		for section in sections {
			let size = Geometry.divCeil(section.bitsWritten, 8)
			var offset = 0
			for (selector, bits) in widths.enumerated() {
				if size < offset + (1 << bits) {
					writer.write(2, UInt64(selector))
					writer.write(bits, UInt64(size - offset))
					break
				}
				offset += (1 << bits)
			}
		}
		writer.zeroPadToByte()
	}

	/// Concatenates the sections behind their table of contents.
	///
	/// With a single AC group the format requires all four sections to be merged
	/// into one, so the TOC has a single entry.
	static func combineSections(_ sections: [BitWriter], writer: inout BitWriter) {
		var sections = sections
		if sections.count == 4 {
			var merged = sections[0]
			for i in 1..<4 { merged.append(sections[i]) }
			sections = [merged]
		}
		writeTOC(sections: sections, writer: &writer)
		writer.appendByteAligned(sections)
	}
}
