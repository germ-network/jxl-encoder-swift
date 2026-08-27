//
//  Encoder.swift
//  JXLEncoder
//
//  Top level: ports `EncodeFrame` and `EncodeFile` from libjxl-tiny's
//  encoder/enc_frame.cc and encoder/enc_file.cc.
//
//  Sections are laid out as DC global, one per DC group, AC global, one per AC
//  group. DC groups are 2048 px and AC groups 256 px, so a DC group holds up to
//  8x8 AC groups.
//

/// An image ready to encode: 8-bit sRGB samples, interleaved.
public struct ImageBuffer: Sendable {
	public let width: Int
	public let height: Int
	/// Row-major, `channels` samples per pixel.
	public let samples: [UInt8]
	/// 3 or 4. A fourth channel is stride only — the encoder ignores it, so
	/// alpha must be flattened before reaching the core (the shim's job).
	public let channels: Int

	public init(width: Int, height: Int, samples: [UInt8], channels: Int = 3) throws {
		guard width > 0, height > 0 else { throw EncoderError.emptyImage }
		guard channels == 3 || channels == 4 else {
			throw EncoderError.unsupportedChannelCount(channels)
		}
		// Overflow here means the dimensions are absurd, not that the count is
		// merely wrong — and a throwing initializer must not trap.
		let (pixels, overflowA) = width.multipliedReportingOverflow(by: height)
		let (expected, overflowB) = pixels.multipliedReportingOverflow(by: channels)
		guard !overflowA, !overflowB else {
			throw EncoderError.imageTooLarge(width: width, height: height)
		}
		guard samples.count == expected else {
			throw EncoderError.pixelCountMismatch(
				expected: expected, actual: samples.count)
		}
		self.width = width
		self.height = height
		self.samples = samples
		self.channels = channels
	}
}

public enum Encoder {
	/// Converts 8-bit sRGB samples to the linear light the transform expects.
	static func linearize(_ image: ImageBuffer) -> [Float] {
		let count = image.width * image.height
		var linear = [Float](repeating: 0, count: count * 3)
		for i in 0..<count {
			for c in 0..<3 {
				linear[i * 3 + c] = SRGBTransfer.linearize(
					image.samples[i * image.channels + c])
			}
		}
		return linear
	}

	/// One AC group's output: its own section, plus the per-block state the DC
	/// group it belongs to has to collect.
	struct ACGroupOutput: Sendable {
		let groupX: Int
		let groupY: Int
		let widthInBlocks: Int
		let heightInBlocks: Int
		let section: SectionWriter
		let quantDC: [[Int16]]
		let quantField: [UInt8]
	}

	/// One AC group's quantized coefficients, ahead of tokenization —
	/// tokenizing needs the frame-global coefficient order (`CoeffOrder`),
	/// which in turn needs every group's coefficients counted first.
	struct ACGroupCompute: Sendable {
		let groupX: Int
		let groupY: Int
		let widthInBlocks: Int
		let heightInBlocks: Int
		/// Per channel, flat and block-major — `ACGroupEncoder.computeGroup`'s
		/// output, passed straight through to `tokenizeGroup`.
		let coefficients: [[Int32]]
		let quantDC: [[Int16]]
		let quantField: [UInt8]
	}

	/// Computes one AC group's coefficients: colour transform, adaptive quant,
	/// forward DCT and quantization — everything except tokenization.
	///
	/// This is where nearly all the per-pixel cost sits, and it reads nothing but
	/// `linear` and the geometry — groups never see each other. Separating it
	/// from assembly is what lets them run concurrently.
	static func computeACGroup(
		linear: [Float],
		dim: ImageDim,
		groupX imageGX: Int,
		groupY imageGY: Int,
		params: DistanceParams
	) -> ACGroupCompute {
		let groupRect = dim.pixelRect(
			ix: imageGX, iy: imageGY, dim: Geometry.groupDim)
		let groupDim = ImageDim(
			width: groupRect.width, height: groupRect.height)

		// The quant field is computed stripe by stripe over the group.
		var quantField = [UInt8](
			repeating: 1,
			count: groupDim.widthInBlocks * groupDim.heightInBlocks)
		var xybPlanes = [[Float]](
			repeating: [Float](
				repeating: 0,
				count: groupDim.widthInBlocks * Geometry.blockDim
					* groupDim.heightInBlocks
					* Geometry.blockDim),
			count: 3)
		let paddedWidth = groupDim.widthInBlocks * Geometry.blockDim

		for ty in 0..<groupDim.heightInTiles {
			let stripeRect = Rect(
				x0: groupRect.x0,
				y0: groupRect.y0 + ty * Geometry.tileDim,
				maxWidth: Geometry.groupDim,
				maxHeight: Geometry.tileDim,
				xEnd: dim.width, yEnd: dim.height)
			let padded = PlaneBuffer.copyAndPad(
				source: linear, sourceWidth: dim.width,
				rect: stripeRect)
			let xyb = AdaptiveQuantPipeline.toXYB(padded)

			// Keep the group's XYB so the AC pass sees the same values.
			let rowOffset =
				ty * Geometry.tileDimInBlocks * Geometry.blockDim
			for c in 0..<3 {
				for y in 0..<padded.height {
					let destRow = (rowOffset + y) * paddedWidth
					guard
						destRow + padded.width
							<= xybPlanes[c].count
					else {
						continue
					}
					for x in 0..<padded.width {
						xybPlanes[c][destRow + x] =
							xyb.planes[c][
								y * padded.width + x
							]
					}
				}
			}

			let tilesAcross = Geometry.divCeil(
				padded.width, Geometry.tileDim)
			for tx in 0..<tilesAcross {
				let tileRect = Rect(
					x0: tx * Geometry.tileDimInBlocks, y0: 0,
					maxWidth: Geometry.tileDimInBlocks,
					maxHeight: Geometry.tileDimInBlocks,
					xEnd: padded.width / Geometry.blockDim,
					yEnd: padded.height / Geometry.blockDim)
				let aqMap = AdaptiveQuant.computeTile(
					stripe: xyb, rect: tileRect,
					distance: params.distance)
				let raw = AdaptiveQuant.rawQuantField(
					aqMap: aqMap,
					inverseScale: params.inverseScale)
				for y in 0..<tileRect.height {
					let by = ty * Geometry.tileDimInBlocks + y
					guard by < groupDim.heightInBlocks else {
						continue
					}
					for x in 0..<tileRect.width {
						let bx = tileRect.x0 + x
						guard bx < groupDim.widthInBlocks
						else { continue }
						quantField[
							by * groupDim.widthInBlocks
								+ bx] =
							raw[y * tileRect.width + x]
					}
				}
			}
		}

		let groupXYB = PaddedStripe(
			width: paddedWidth,
			height: groupDim.heightInBlocks * Geometry.blockDim,
			planes: xybPlanes)
		var groupDC = [[Int16]](
			repeating: [Int16](
				repeating: 0,
				count: groupDim.widthInBlocks
					* groupDim.heightInBlocks),
			count: 3)

		let coefficients = ACGroupEncoder.computeGroup(
			xyb: groupXYB,
			widthInBlocks: groupDim.widthInBlocks,
			heightInBlocks: groupDim.heightInBlocks,
			quantField: quantField,
			scale: params.scale,
			scaleDC: params.scaleDC,
			xQuantMatrixScale: params.xQuantMatrixScale,
			quantDC: &groupDC)

		return ACGroupCompute(
			groupX: imageGX, groupY: imageGY,
			widthInBlocks: groupDim.widthInBlocks,
			heightInBlocks: groupDim.heightInBlocks,
			coefficients: coefficients, quantDC: groupDC, quantField: quantField)
	}

	/// Tokenizes one already-computed AC group using the frame-global
	/// coefficient order.
	static func tokenizeACGroup(
		_ compute: ACGroupCompute, order: [[Int]], mode: SectionWriter.Mode
	) -> ACGroupOutput {
		var writer = SectionWriter(mode: mode)
		ACGroupEncoder.tokenizeGroup(
			coefficients: compute.coefficients,
			widthInBlocks: compute.widthInBlocks,
			heightInBlocks: compute.heightInBlocks,
			subsampling: .none,
			order: order,
			writer: &writer)
		return ACGroupOutput(
			groupX: compute.groupX, groupY: compute.groupY,
			widthInBlocks: compute.widthInBlocks,
			heightInBlocks: compute.heightInBlocks,
			section: writer, quantDC: compute.quantDC, quantField: compute.quantField)
	}

	/// Reduces every group's coefficients into the frame-global zero
	/// statistics `CoeffOrder` computes the transmitted order from.
	static func computeCoeffOrder(
		_ computes: [ACGroupCompute], dim: ImageDim
	) -> CoeffOrder.Result {
		var counts = [CoeffOrder.ZeroCounts](repeating: CoeffOrder.ZeroCounts(), count: 3)
		for compute in computes {
			for c in 0..<3 { counts[c].addAll(compute.coefficients[c]) }
		}
		return CoeffOrder.compute(
			counts: counts, widthInBlocks: dim.widthInBlocks,
			heightInBlocks: dim.heightInBlocks)
	}

	/// Folds finished AC groups into their DC groups and writes the DC sections.
	///
	/// Kept apart from the computation so the sequential and concurrent drivers
	/// share it exactly and cannot drift.
	static func assemble(
		outputs: [ACGroupOutput], dim: ImageDim, sections: inout [SectionWriter]
	) {
		var dcData: [DCGroupData] = (0..<dim.dcGroupCount).map { i in
			let rect = dim.pixelRect(
				ix: i % dim.widthInDCGroups, iy: i / dim.widthInDCGroups,
				dim: Geometry.dcGroupDim)
			let groupDim = ImageDim(width: rect.width, height: rect.height)
			return DCGroupData(
				widthInBlocks: groupDim.widthInBlocks,
				heightInBlocks: groupDim.heightInBlocks)
		}

		for output in outputs {
			sections[
				2 + dim.dcGroupCount + output.groupY * dim.widthInGroups
					+ output.groupX] = output.section

			// A DC group spans kBlockDim AC groups on each axis.
			let dcGroupX = output.groupX / Geometry.blockDim
			let dcGroupY = output.groupY / Geometry.blockDim
			let index = dcGroupY * dim.widthInDCGroups + dcGroupX
			let blockX0 =
				(output.groupX - dcGroupX * Geometry.blockDim)
				* Geometry.groupDimInBlocks
			let blockY0 =
				(output.groupY - dcGroupY * Geometry.blockDim)
				* Geometry.groupDimInBlocks

			for by in 0..<output.heightInBlocks {
				for bx in 0..<output.widthInBlocks {
					let target =
						(blockY0 + by) * dcData[index].widthInBlocks
						+ blockX0 + bx
					guard target < dcData[index].rawQuantField.count else {
						continue
					}
					dcData[index].rawQuantField[target] =
						output.quantField[by * output.widthInBlocks + bx]
					for c in 0..<3 {
						dcData[index].quantDC[c][target] =
							output.quantDC[c][
								by * output.widthInBlocks + bx]
					}
				}
			}
		}

		for i in 0..<dim.dcGroupCount {
			DCGroupEncoder.write(data: dcData[i], writer: &sections[1 + i])
		}
	}

	static func encodeFrame(
		linear: [Float], width: Int, height: Int, params: DistanceParams,
		optimizeCodes: Bool = true,
		writer: inout BitWriter
	) throws {
		let dim = ImageDim(width: width, height: height)
		var dcCode = EntropyCode.staticDC
		var acCode = EntropyCode.staticAC

		// Staging defers entropy coding until the image's own statistics are
		// known. The static tables ship in full on every file otherwise, which
		// dominates small images.
		let mode: SectionWriter.Mode =
			optimizeCodes ? .staging(dcCode) : .direct(dcCode)
		var sections = [SectionWriter](
			repeating: SectionWriter(mode: mode),
			count: 2 + dim.dcGroupCount + dim.groupCount)
		let acRange = (2 + dim.dcGroupCount)..<(2 + dim.dcGroupCount + dim.groupCount)
		if optimizeCodes {
			for i in acRange { sections[i] = SectionWriter(mode: .staging(acCode)) }
		} else {
			for i in acRange { sections[i] = SectionWriter(mode: .direct(acCode)) }
		}

		var computes: [ACGroupCompute] = []
		computes.reserveCapacity(dim.groupCount)
		for index in 0..<dim.groupCount {
			computes.append(
				computeACGroup(
					linear: linear, dim: dim,
					groupX: index % dim.widthInGroups,
					groupY: index / dim.widthInGroups,
					params: params))
		}
		// No meaning without per-image code optimisation to carry it — the
		// static-table path keeps the fixed zig-zag order, unchanged.
		let coeffOrder: CoeffOrder.Result =
			optimizeCodes ? computeCoeffOrder(computes, dim: dim) : .identity

		let acMode: SectionWriter.Mode =
			optimizeCodes ? .staging(acCode) : .direct(acCode)
		var outputs: [ACGroupOutput] = []
		outputs.reserveCapacity(dim.groupCount)
		// Drains rather than iterates: each group's coefficients are only
		// needed once, and a frame's worth of them is large enough to be
		// worth releasing as tokenization consumes them.
		while !computes.isEmpty {
			let compute = computes.removeLast()
			outputs.append(
				tokenizeACGroup(compute, order: coeffOrder.orders, mode: acMode))
		}
		assemble(outputs: outputs, dim: dim, sections: &sections)

		if optimizeCodes {
			let dcRange = 1..<(1 + dim.dcGroupCount)
			dcCode = SectionOptimizer.optimize(
				sections: &sections, range: dcRange, baseCode: dcCode)
			acCode = SectionOptimizer.optimize(
				sections: &sections, range: acRange, baseCode: acCode,
				allowANS: true)
		}

		// The globals carry the codes, so they can only be written once the
		// codes are final.
		var dcGlobal = BitWriter()
		try FrameAssembly.writeDCGlobal(
			params: params, dcGroupCount: dim.dcGroupCount, code: dcCode,
			allowContextMapANS: optimizeCodes, writer: &dcGlobal)
		sections[0] = SectionWriter(prewritten: dcGlobal)

		var acGlobal = BitWriter()
		try FrameAssembly.writeACGlobal(
			groupCount: dim.groupCount, code: acCode, coeffOrder: coeffOrder,
			allowContextMapANS: optimizeCodes, writer: &acGlobal)
		sections[1 + dim.dcGroupCount] = SectionWriter(prewritten: acGlobal)

		FrameAssembly.writeFrameHeader(
			colorMode: .xyb(xQuantMatrixScale: params.xQuantMatrixScale),
			epfIterations: params.epfIterations,
			writer: &writer)
		FrameAssembly.combineSections(
			sections.map { $0.finished() }, writer: &writer)
	}

	/// Encodes an image as a bare JPEG XL codestream.
	///
	/// `distance` is a butteraugli target: lower is higher quality. Lossless is
	/// not supported by this VarDCT-only encoder.
	public static func encode(
		_ image: ImageBuffer,
		distance: Float,
		transferFunction: TransferFunction = .sRGB,
		optimizeCodes: Bool = true
	) throws -> [UInt8] {
		let params = try DistanceParams(distance: distance)
		let linear = linearize(image)

		var writer = BitWriter()
		try ImageHeader.write(
			width: image.width, height: image.height,
			transferFunction: transferFunction, to: &writer)
		try encodeFrame(
			linear: linear, width: image.width, height: image.height,
			params: params, optimizeCodes: optimizeCodes, writer: &writer)
		writer.zeroPadToByte()
		return writer.take()
	}
}

extension Encoder {
	/// Encodes with the AC groups computed concurrently.
	///
	/// Produces byte-identical output to `encode`: groups read only the shared
	/// linear image and their own geometry, and the assembly step keys off each
	/// group's coordinates rather than the order results arrive in. What changes
	/// is only how long it takes.
	///
	/// Worth using at full size and pointless below 256 px, where the image is a
	/// single group and there is nothing to overlap.
	public static func encodeConcurrently(
		_ image: ImageBuffer,
		distance: Float,
		transferFunction: TransferFunction = .sRGB,
		optimizeCodes: Bool = true
	) async throws -> [UInt8] {
		let params = try DistanceParams(distance: distance)
		let linear = linearize(image)
		let dim = ImageDim(width: image.width, height: image.height)

		var writer = BitWriter()
		try ImageHeader.write(
			width: image.width, height: image.height,
			transferFunction: transferFunction, to: &writer)

		var dcCode = EntropyCode.staticDC
		var acCode = EntropyCode.staticAC
		let dcMode: SectionWriter.Mode =
			optimizeCodes ? .staging(dcCode) : .direct(dcCode)
		let acMode: SectionWriter.Mode =
			optimizeCodes ? .staging(acCode) : .direct(acCode)

		var sections = [SectionWriter](
			repeating: SectionWriter(mode: dcMode),
			count: 2 + dim.dcGroupCount + dim.groupCount)

		var computes = await withTaskGroup(of: ACGroupCompute.self) { group in
			for index in 0..<dim.groupCount {
				group.addTask {
					computeACGroup(
						linear: linear, dim: dim,
						groupX: index % dim.widthInGroups,
						groupY: index / dim.widthInGroups,
						params: params)
				}
			}
			var collected: [ACGroupCompute] = []
			collected.reserveCapacity(dim.groupCount)
			for await compute in group { collected.append(compute) }
			return collected
		}
		// No meaning without per-image code optimisation to carry it — the
		// static-table path keeps the fixed zig-zag order, unchanged.
		let coeffOrder: CoeffOrder.Result =
			optimizeCodes ? computeCoeffOrder(computes, dim: dim) : .identity

		let outputs = await withTaskGroup(of: ACGroupOutput.self) { group in
			for compute in computes {
				group.addTask {
					tokenizeACGroup(
						compute, order: coeffOrder.orders, mode: acMode)
				}
			}
			var collected: [ACGroupOutput] = []
			collected.reserveCapacity(dim.groupCount)
			for await output in group { collected.append(output) }
			return collected
		}
		// Frees the frame's coefficients before assembly/optimisation rather
		// than leaving them reachable for the rest of the encode.
		computes = []
		assemble(outputs: outputs, dim: dim, sections: &sections)

		let acRange = (2 + dim.dcGroupCount)..<(2 + dim.dcGroupCount + dim.groupCount)
		if optimizeCodes {
			dcCode = SectionOptimizer.optimize(
				sections: &sections, range: 1..<(1 + dim.dcGroupCount),
				baseCode: dcCode)
			acCode = SectionOptimizer.optimize(
				sections: &sections, range: acRange, baseCode: acCode,
				allowANS: true)
		}

		var dcGlobal = BitWriter()
		try FrameAssembly.writeDCGlobal(
			params: params, dcGroupCount: dim.dcGroupCount, code: dcCode,
			allowContextMapANS: optimizeCodes, writer: &dcGlobal)
		sections[0] = SectionWriter(prewritten: dcGlobal)

		var acGlobal = BitWriter()
		try FrameAssembly.writeACGlobal(
			groupCount: dim.groupCount, code: acCode, coeffOrder: coeffOrder,
			allowContextMapANS: optimizeCodes, writer: &acGlobal)
		sections[1 + dim.dcGroupCount] = SectionWriter(prewritten: acGlobal)

		FrameAssembly.writeFrameHeader(
			colorMode: .xyb(xQuantMatrixScale: params.xQuantMatrixScale),
			epfIterations: params.epfIterations,
			writer: &writer)
		FrameAssembly.combineSections(
			sections.map { $0.finished() }, writer: &writer)
		writer.zeroPadToByte()
		return writer.take()
	}

	/// Re-codes a parsed JPEG as JPEG XL without an inverse DCT.
	///
	/// The coefficients cross over exactly as the JPEG stored them, so this is
	/// lossless with respect to the source: decoding the result gives the same
	/// pixels the JPEG would. What changes is the signalling — YCbCr instead of
	/// XYB, the JPEG's own quantization tables instead of the built-in ones — and
	/// the entropy layer, which is where the saving comes from.
	public static func encodeJPEG(
		_ transcode: JPEGTranscode,
		optimizeCodes: Bool = true
	) throws -> [UInt8] {
		var writer = BitWriter()
		try ImageHeader.write(
			width: transcode.width, height: transcode.height,
			transferFunction: .sRGB, xybEncoded: false, to: &writer)
		try encodeJPEGFrame(transcode, optimizeCodes: optimizeCodes, writer: &writer)
		writer.zeroPadToByte()
		return writer.take()
	}

	/// Returns the entropy codes it settled on, which is what the globals
	/// carry. Only the tests read them, to check the transmitted context maps
	/// against the decoder's rules.
	@discardableResult
	static func encodeJPEGFrame(
		_ transcode: JPEGTranscode,
		optimizeCodes: Bool,
		writer: inout BitWriter
	) throws -> (dc: EntropyCode, ac: EntropyCode) {
		// When chroma is subsampled the block grid rounds up to a whole MCU, so
		// the chroma planes divide evenly. A 37-pixel row is five blocks but six
		// at 4:2:2, which is also what the JPEG's own MCU grid holds — the two
		// agree by construction. Using the unpadded count writes short and
		// desynchronises the section.
		let alignment = (
			x: 1 << transcode.subsampling.maxHorizontalShift,
			y: 1 << transcode.subsampling.maxVerticalShift
		)
		let dim = ImageDim(
			width: transcode.width, height: transcode.height,
			blockAlignment: alignment)

		// The adaptive block context map has no meaning without per-image
		// optimisation to carry it — the static-table path keeps the fixed
		// formula `ACContext.blockContext` already computes, unchanged.
		let blockContextMap: JPEGBlockContextMap.Result? =
			optimizeCodes ? JPEGBlockContextMap.compute(transcode) : nil

		var dcCode = EntropyCode.staticDC
		// A wider raw context space than the static table's fixed 4
		// categories, sized to whatever this image's adaptive map actually
		// uses — `SectionOptimizer.optimize` reads only `contextCount`, so
		// the map/prefix-code values here are never read.
		var acCode: EntropyCode =
			if let blockContextMap {
				EntropyCode(
					contextMap: [UInt8](
						repeating: 0,
						count: blockContextMap.numContexts
							* (ACContext.nonZeroBuckets
								+ ACContext.zeroDensityCount)),
					prefixCodes: [])
			} else {
				.staticAC
			}

		let mode: SectionWriter.Mode =
			optimizeCodes ? .staging(dcCode) : .direct(dcCode)
		var sections = [SectionWriter](
			repeating: SectionWriter(mode: mode),
			count: 2 + dim.dcGroupCount + dim.groupCount)
		let acRange = (2 + dim.dcGroupCount)..<(2 + dim.dcGroupCount + dim.groupCount)
		for i in acRange {
			sections[i] = SectionWriter(
				mode: optimizeCodes ? .staging(acCode) : .direct(acCode))
		}

		// DC groups collect the DC image; the AC pass fills it in as it goes,
		// exactly as on the pixel path.
		var dcData: [DCGroupData] = (0..<dim.dcGroupCount).map { i in
			let rect = dim.pixelRect(
				ix: i % dim.widthInDCGroups, iy: i / dim.widthInDCGroups,
				dim: Geometry.dcGroupDim)
			let groupDim = ImageDim(
				width: rect.width, height: rect.height,
				blockAlignment: alignment)
			return DCGroupData(
				widthInBlocks: groupDim.widthInBlocks,
				heightInBlocks: groupDim.heightInBlocks,
				subsampling: transcode.subsampling)
		}

		// No meaning without per-image code optimisation to carry it — the
		// static-table path keeps the fixed zig-zag order, unchanged. Unlike
		// the pixel path, a JPEG's coefficients are already fully parsed
		// (`transcode`), so this only needs a read-only sweep, not a full
		// compute-then-tokenize split.
		var coeffOrder = CoeffOrder.Result.identity
		if optimizeCodes {
			var counts = [CoeffOrder.ZeroCounts](
				repeating: CoeffOrder.ZeroCounts(), count: 3)
			for gy in 0..<dim.heightInGroups {
				for gx in 0..<dim.widthInGroups {
					let rect = dim.pixelRect(
						ix: gx, iy: gy, dim: Geometry.groupDim)
					let groupDim = ImageDim(
						width: rect.width, height: rect.height,
						blockAlignment: alignment)
					ACGroupEncoder.countZerosJPEG(
						transcode: transcode,
						blockX0: gx * Geometry.groupDimInBlocks,
						blockY0: gy * Geometry.groupDimInBlocks,
						widthInBlocks: groupDim.widthInBlocks,
						heightInBlocks: groupDim.heightInBlocks,
						into: &counts)
				}
			}
			coeffOrder = CoeffOrder.compute(
				counts: counts, widthInBlocks: dim.widthInBlocks,
				heightInBlocks: dim.heightInBlocks)
		}

		for gy in 0..<dim.heightInGroups {
			for gx in 0..<dim.widthInGroups {
				let rect = dim.pixelRect(ix: gx, iy: gy, dim: Geometry.groupDim)
				let groupDim = ImageDim(
					width: rect.width, height: rect.height,
					blockAlignment: alignment)
				let acIndex = 2 + dim.dcGroupCount + gy * dim.widthInGroups + gx
				let blockX0 = gx * Geometry.groupDimInBlocks
				let blockY0 = gy * Geometry.groupDimInBlocks

				var groupDC = [[Int16]](
					repeating: [Int16](
						repeating: 0,
						count: groupDim.widthInBlocks
							* groupDim.heightInBlocks),
					count: 3)

				ACGroupEncoder.encodeJPEG(
					transcode: transcode,
					blockX0: blockX0, blockY0: blockY0,
					widthInBlocks: groupDim.widthInBlocks,
					heightInBlocks: groupDim.heightInBlocks,
					quantDC: &groupDC,
					blockContextMap: blockContextMap,
					order: coeffOrder.orders,
					writer: &sections[acIndex])

				// Fold the group's DC into whichever DC group covers it.
				let dcGroupX = blockX0 / (Geometry.dcGroupDim / Geometry.blockDim)
				let dcGroupY = blockY0 / (Geometry.dcGroupDim / Geometry.blockDim)
				let dcIndex = dcGroupY * dim.widthInDCGroups + dcGroupX
				let offsetX =
					blockX0 - dcGroupX
					* (Geometry.dcGroupDim / Geometry.blockDim)
				let offsetY =
					blockY0 - dcGroupY
					* (Geometry.dcGroupDim / Geometry.blockDim)
				// Each channel has its own subsampled grid, so this cannot share
				// one stride across channels: `groupDC[c]` was written by
				// `ACGroupEncoder.encodeJPEG` using that channel's own row width
				// (`channelWidths[c]` there), and `dcData[dcIndex].quantDC[c]` is
				// laid out using that DC group's own per-channel `planeWidths[c]`
				// — neither of which is `groupDim.widthInBlocks`, the AC group's
				// full-resolution width, except by coincidence when chroma is not
				// subsampled or a DC group holds exactly one AC group. Using the
				// full-resolution stride for every channel silently scrambled
				// subsampled chroma DC across any image wider than one AC group.
				for c in 0..<3 {
					let sourceWidth = transcode.subsampling.blocksAcross(
						channel: c,
						fullWidthInBlocks: groupDim.widthInBlocks)
					let sourceHeight = transcode.subsampling.blocksDown(
						channel: c,
						fullHeightInBlocks: groupDim.heightInBlocks)
					let destWidth = dcData[dcIndex].planeWidths[c]
					let destHeight = dcData[dcIndex].planeHeights[c]
					let destX0 = transcode.subsampling.subsampledX(
						channel: c, blockX: offsetX)
					let destY0 = transcode.subsampling.subsampledY(
						channel: c, blockY: offsetY)
					for by in 0..<sourceHeight {
						let destY = destY0 + by
						guard destY < destHeight else { continue }
						for bx in 0..<sourceWidth {
							let destX = destX0 + bx
							guard destX < destWidth else { continue }
							dcData[dcIndex].quantDC[c][
								destY * destWidth + destX] =
								groupDC[c][by * sourceWidth + bx]
						}
					}
				}
			}
		}

		for i in 0..<dim.dcGroupCount {
			DCGroupEncoder.write(data: dcData[i], writer: &sections[1 + i])
		}

		if optimizeCodes {
			dcCode = SectionOptimizer.optimize(
				sections: &sections, range: 1..<(1 + dim.dcGroupCount),
				baseCode: dcCode)
			acCode = SectionOptimizer.optimize(
				sections: &sections, range: acRange, baseCode: acCode,
				allowANS: true)
		}

		var dcGlobal = BitWriter()
		try FrameAssembly.writeDCGlobal(
			params: try DistanceParams(distance: 1.0),
			dcGroupCount: dim.dcGroupCount, code: dcCode,
			dcQuantization: (0..<3).map { transcode.dcQuantization(channel: $0) },
			globalScale: FrameAssembly.jpegGlobalScale,
			quantDC: 1,
			blockContextMap: blockContextMap,
			allowContextMapANS: optimizeCodes, writer: &dcGlobal)
		sections[0] = SectionWriter(prewritten: dcGlobal)

		var acGlobal = BitWriter()
		try FrameAssembly.writeACGlobal(
			groupCount: dim.groupCount, code: acCode,
			quantTables: (0..<3).map { transcode.quantTable(channel: $0) },
			coeffOrder: coeffOrder,
			allowContextMapANS: optimizeCodes, writer: &acGlobal)
		sections[1 + dim.dcGroupCount] = SectionWriter(prewritten: acGlobal)

		FrameAssembly.writeFrameHeader(
			colorMode: .ycbcr(subsampling: transcode.subsampling),
			epfIterations: 0,
			writer: &writer)
		FrameAssembly.combineSections(
			sections.map { $0.finished() }, writer: &writer)
		return (dcCode, acCode)
	}
}
