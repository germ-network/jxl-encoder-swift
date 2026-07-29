//
//  DCT.swift
//  JXLEncoder
//
//  Port of the 8x8 forward DCT from libjxl-tiny's encoder/enc_transforms-inl.h
//  (`ComputeScaledDCT<8, 8>`), plus the constants from encoder/dct_scales.h.
//
//  "Scaled" refers to the reference's own convention: each 1-D pass divides by
//  N in `StoreToBlockAndScale`, giving 1/64 over the two passes for an 8x8
//  block, and the remaining normalization is folded into the quant matrices.
//
//  The reference is a recursive butterfly decomposition operating on SIMD lanes
//  — its `SZ` lane count is the row width, so a scalar port walks the same
//  butterflies with an explicit inner loop over columns.
//

enum DCT {
	static let sqrt2: Float = 1.41421356237

	/// `1 / (2 * cos((i + 0.5) * pi / N))`
	static let wc8: [Float] = [
		0.509_795_579_104_159_2, 0.601_344_886_935_045_3,
		0.899_976_223_136_415_6, 2.562_915_447_741_505_5,
	]
	static let wc4: [Float] = [0.541_196_100_146_197, 1.306_562_964_876_376_4]

	static let blockDim = 8
	static let blockSize = 64

	/// In-place butterfly pass over `n` rows of `width` interleaved columns.
	/// Mirrors `DCT1DImpl<N, SZ>`, which processes a whole SIMD vector of
	/// columns per butterfly step.
	///
	/// Unscaled: the reference applies `1/N` in `StoreToBlockAndScale` once per
	/// full pass, not in the recursion, so `forward8x8` owns that step.
	static func dct1D(_ mem: inout [Float], offset: Int, n: Int, width: Int) {
		if n == 1 { return }
		if n == 2 {
			for j in 0..<width {
				let in1 = mem[offset + j]
				let in2 = mem[offset + width + j]
				mem[offset + j] = in1 + in2
				mem[offset + width + j] = in1 - in2
			}
			return
		}

		let half = n / 2
		var tmp = [Float](repeating: 0, count: n * width)

		// AddReverse / SubReverse: pair row i with row (n - 1 - i).
		for i in 0..<half {
			for j in 0..<width {
				let in1 = mem[offset + i * width + j]
				let in2 = mem[offset + (n - i - 1) * width + j]
				tmp[i * width + j] = in1 + in2
				tmp[(half + i) * width + j] = in1 - in2
			}
		}

		dct1D(&tmp, offset: 0, n: half, width: width)

		// Multiply: scale the odd half by the Wc constants.
		let multipliers = half == 4 ? wc8 : wc4
		for i in 0..<half {
			let mul = multipliers[i]
			for j in 0..<width {
				tmp[(half + i) * width + j] *= mul
			}
		}

		dct1D(&tmp, offset: half * width, n: half, width: width)

		// B: fold the odd half back, with sqrt(2) on the first row.
		for j in 0..<width {
			let in1 = tmp[half * width + j]
			let in2 = tmp[(half + 1) * width + j]
			tmp[half * width + j] = in2.addingProduct(in1, sqrt2)
		}
		for i in 1..<(half - 1) {
			for j in 0..<width {
				tmp[(half + i) * width + j] += tmp[(half + i + 1) * width + j]
			}
		}

		// InverseEvenOdd: even rows first, then odd.
		for i in 0..<half {
			for j in 0..<width {
				mem[offset + 2 * i * width + j] = tmp[i * width + j]
				mem[offset + (2 * i + 1) * width + j] = tmp[(half + i) * width + j]
			}
		}
	}

	static func transpose8(_ block: [Float]) -> [Float] {
		var out = [Float](repeating: 0, count: blockSize)
		for y in 0..<blockDim {
			for x in 0..<blockDim {
				out[x * blockDim + y] = block[y * blockDim + x]
			}
		}
		return out
	}

	/// Forward DCT of one 8x8 block read from `pixels` at (originX, originY).
	///
	/// Reproduces `ComputeScaledDCT<8, 8>`: DCT the columns, transpose, DCT
	/// again. With square blocks only one transpose occurs, so the output is
	/// transposed relative to a textbook 2D DCT — the reference's downstream
	/// code expects exactly this layout.
	static func forward8x8(
		pixels: [Float], stride: Int, originX: Int, originY: Int
	) -> [Float] {
		var block = [Float](repeating: 0, count: blockSize)
		for y in 0..<blockDim {
			for x in 0..<blockDim {
				block[y * blockDim + x] =
					pixels[(originY + y) * stride + originX + x]
			}
		}

		// 1/8 is a power of two, so applying it per pass is exact and matches
		// the reference's per-store scaling.
		let scale = 1.0 / Float(blockDim)

		dct1D(&block, offset: 0, n: blockDim, width: blockDim)
		for i in 0..<blockSize { block[i] *= scale }

		var transposed = transpose8(block)
		dct1D(&transposed, offset: 0, n: blockDim, width: blockDim)
		for i in 0..<blockSize { transposed[i] *= scale }
		return transposed
	}

	/// Forward DCT of every 8x8 block, emitted in block-raster order so block
	/// (bx, by) occupies 64 consecutive coefficients.
	static func forwardBlocks(plane: [Float], width: Int, height: Int) -> [Float] {
		precondition(
			width % blockDim == 0 && height % blockDim == 0,
			"image dimensions must be a multiple of \(blockDim)")
		let blocksX = width / blockDim
		let blocksY = height / blockDim
		var out = [Float](repeating: 0, count: width * height)
		for by in 0..<blocksY {
			for bx in 0..<blocksX {
				let block = forward8x8(
					pixels: plane, stride: width,
					originX: bx * blockDim, originY: by * blockDim)
				let base = (by * blocksX + bx) * blockSize
				for i in 0..<blockSize { out[base + i] = block[i] }
			}
		}
		return out
	}
}
