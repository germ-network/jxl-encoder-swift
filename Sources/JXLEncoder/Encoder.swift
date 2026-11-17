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
	/// A stripe source that linearizes 8-bit samples one rect at a time, so the
	/// whole-image linear plane is never materialised. Captures only the
	/// image's samples, stride and width — all value types — so it is safe to
	/// share across the concurrent path's group tasks.
	static func linearizingStripeSource(
		_ image: ImageBuffer
	) -> @Sendable (Rect) -> PaddedStripe {
		let samples = image.samples
		let channels = image.channels
		let width = image.width
		return { rect in
			PlaneBuffer.copyAndPadLinearizing(
				source: samples, sourceWidth: width, channels: channels, rect: rect)
		}
	}

	/// One AC group's output: its own section, plus the per-block state the DC
	/// group it belongs to has to collect.
	struct ACGroupOutput: Sendable {
		let groupX: Int
		let groupY: Int
		let widthInBlocks: Int
		let heightInBlocks: Int
		let section: SectionWriter
		let rawDC: [[Float]]
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
		let rawDC: [[Float]]
		let quantField: [UInt8]
	}

	/// Computes one AC group's coefficients: forward DCT and quantization.
	///
	/// This is where nearly all the per-pixel cost sits, and it reads only its
	/// XYB source and geometry — groups never see each other. Separating it
	/// from assembly is what lets them run concurrently.
	///
	/// `xybAt` returns globally prepared XYB stripes, so group edges never become
	/// independent filter boundaries.
	static func computeACGroup(
		xybAt: @Sendable (Rect) -> PaddedStripe,
		dim: ImageDim,
		groupX imageGX: Int,
		groupY imageGY: Int,
		params: DistanceParams
	) -> ACGroupCompute {
		let groupRect = dim.pixelRect(
			ix: imageGX, iy: imageGY, dim: Geometry.groupDim)
		let groupDim = ImageDim(
			width: groupRect.width, height: groupRect.height)

		// `-e 4`'s quant field is uniform — the same value for every block,
		// not a per-tile computation. See docs/gap-closure-plan.md, "Quant
		// calibration."
		let quantField = [UInt8](
			repeating: params.uniformQuant,
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
			let padded = xybAt(stripeRect)

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
							padded.planes[c][
								y * padded.width + x
							]
					}
				}
			}
		}

		let groupXYB = PaddedStripe(
			width: paddedWidth,
			height: groupDim.heightInBlocks * Geometry.blockDim,
			planes: xybPlanes)
		var rawDC = [[Float]](
			repeating: [Float](
				repeating: 0,
				count: groupDim.widthInBlocks * groupDim.heightInBlocks),
			count: 3)

		let coefficients = ACGroupEncoder.computeGroup(
			xyb: groupXYB,
			widthInBlocks: groupDim.widthInBlocks,
			heightInBlocks: groupDim.heightInBlocks,
			quantField: quantField,
			scale: params.scale,
			xQuantMatrixScale: params.xQuantMatrixScale,
			rawDC: &rawDC)

		return ACGroupCompute(
			groupX: imageGX, groupY: imageGY,
			widthInBlocks: groupDim.widthInBlocks,
			heightInBlocks: groupDim.heightInBlocks,
			coefficients: coefficients, rawDC: rawDC, quantField: quantField)
	}

	/// Tokenizes one already-computed AC group using the frame-global
	/// coefficient order.
	static func tokenizeACGroup(
		_ compute: ACGroupCompute, order: [[Int]], mode: SectionWriter.Mode,
		blockContextMap: JPEGBlockContextMap.Result? = nil
	) -> ACGroupOutput {
		var writer = SectionWriter(mode: mode)
		if let blockContextMap {
			ACGroupEncoder.tokenizeGroup(
				coefficients: compute.coefficients,
				widthInBlocks: compute.widthInBlocks,
				heightInBlocks: compute.heightInBlocks,
				subsampling: .none,
				order: order,
				blockContextMap: blockContextMap,
				rawQuantField: compute.quantField,
				writer: &writer)
		} else {
			ACGroupEncoder.tokenizeGroup(
				coefficients: compute.coefficients,
				widthInBlocks: compute.widthInBlocks,
				heightInBlocks: compute.heightInBlocks,
				subsampling: .none,
				order: order,
				writer: &writer)
		}
		return ACGroupOutput(
			groupX: compute.groupX, groupY: compute.groupY,
			widthInBlocks: compute.widthInBlocks,
			heightInBlocks: compute.heightInBlocks,
			section: writer, rawDC: compute.rawDC, quantField: compute.quantField)
	}

	/// Reduces every group's coefficients into the frame-global zero
	/// statistics `CoeffOrder` computes the transmitted order from.
	static func computeCoeffOrder(
		_ computes: [ACGroupCompute], dim: ImageDim
	) -> CoeffOrder.Result {
		var counts = [CoeffOrder.ZeroCounts](repeating: CoeffOrder.ZeroCounts(), count: 3)
		var sampler = CoeffOrder.Sampler()
		for compute in computes.sorted(by: {
			$0.groupY == $1.groupY
				? $0.groupX < $1.groupX
				: $0.groupY < $1.groupY
		}) {
			CoeffOrder.accumulateGroup(
				compute.coefficients, widthInBlocks: compute.widthInBlocks,
				heightInBlocks: compute.heightInBlocks,
				sampler: &sampler, counts: &counts)
		}
		return CoeffOrder.compute(
			counts: counts, widthInBlocks: dim.widthInBlocks,
			heightInBlocks: dim.heightInBlocks)
	}

	static func computeBlockContextMap(
		_ computes: [ACGroupCompute], params: DistanceParams
	) -> JPEGBlockContextMap.Result {
		var quantCounts = [Int](repeating: 0, count: 256)
		for compute in computes {
			for quant in compute.quantField { quantCounts[Int(quant) - 1] += 1 }
		}
		return PixelBlockEntropyModel.compute(quantCounts: quantCounts, params: params)
	}

	/// Folds finished AC groups into their DC groups and writes the DC sections.
	///
	/// Kept apart from the computation so the sequential and concurrent drivers
	/// share it exactly and cannot drift.
	static func assemble(
		outputs: [ACGroupOutput], dim: ImageDim, params: DistanceParams,
		optimizeCodes: Bool, sections: inout [SectionWriter]
	) throws -> [DCGroupData] {
		var dcData: [DCGroupData] = (0..<dim.dcGroupCount).map { i in
			let rect = dim.pixelRect(
				ix: i % dim.widthInDCGroups, iy: i / dim.widthInDCGroups,
				dim: Geometry.dcGroupDim)
			let groupDim = ImageDim(width: rect.width, height: rect.height)
			return DCGroupData(
				widthInBlocks: groupDim.widthInBlocks,
				heightInBlocks: groupDim.heightInBlocks)
		}
		var rawDCByGroup = dcData.map { data in
			(0..<3).map { _ in
				[Float](
					repeating: 0,
					count: data.widthInBlocks * data.heightInBlocks)
			}
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
						rawDCByGroup[index][c][target] =
							output.rawDC[c][
								by * output.widthInBlocks + bx]
					}
				}
			}
		}

		for i in 0..<dim.dcGroupCount {
			try DCGroupEncoder.preparePixel(
				rawDC: rawDCByGroup[i], globalScale: params.globalScale,
				quantDC: params.quantDC,
				data: &dcData[i])
			if !optimizeCodes {
				DCGroupEncoder.write(data: dcData[i], writer: &sections[1 + i])
			}
		}
		return dcData
	}

	static func encodeFrame(
		pixelFrame: PixelFrameInput,
		params: DistanceParams,
		optimizeCodes: Bool = true,
		writer: inout BitWriter
	) throws {
		let dim = pixelFrame.dim
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
					xybAt: pixelFrame.xybAt, dim: dim,
					groupX: index % dim.widthInGroups,
					groupY: index / dim.widthInGroups,
					params: params))
		}
		// No meaning without per-image code optimisation to carry it — the
		// static-table path keeps the fixed zig-zag order, unchanged.
		let coeffOrder: CoeffOrder.Result =
			optimizeCodes ? computeCoeffOrder(computes, dim: dim) : .identity
		let blockContextMap =
			optimizeCodes ? computeBlockContextMap(computes, params: params) : nil
		if let blockContextMap {
			acCode = EntropyCode(
				contextMap: [UInt8](
					repeating: 0,
					count: blockContextMap.numContexts
						* (ACContext.nonZeroBuckets
							+ ACContext.zeroDensityCount)),
				prefixCodes: [])
		}

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
				tokenizeACGroup(
					compute, order: coeffOrder.orders, mode: acMode,
					blockContextMap: blockContextMap))
		}
		let dcData = try assemble(
			outputs: outputs, dim: dim, params: params,
			optimizeCodes: optimizeCodes, sections: &sections)
		var modularTree: ContextTree.Prepared?
		var modularTreeCode: EntropyCode?

		if optimizeCodes {
			let tree = ContextTree.prepare(groups: dcData, jpegTranscode: false)
			let streams = try dcData.enumerated().map {
				try DCGroupEncoder.tokenStreams(
					data: $0.element, groupIndex: $0.offset, tree: tree)
			}
			let payloadTokens = streams.flatMap { $0.dc + $0.metadata }
			dcCode = SectionOptimizer.modularCode(
				tokenStreams: [payloadTokens], contextCount: tree.contextCount,
				extraDCPrecision: 1)
			let treeCode = SectionOptimizer.modularCode(
				tokenStreams: [tree.tokens],
				contextCount: ContextTree.treeContextCount,
				extraDCPrecision: 1)
			for index in dcData.indices {
				var section = BitWriter()
				try DCGroupEncoder.write(
					data: dcData[index], streams: streams[index],
					code: dcCode, writer: &section)
				sections[1 + index] = SectionWriter(prewritten: section)
			}
			modularTree = tree
			modularTreeCode = treeCode
			acCode = SectionOptimizer.optimize(
				sections: &sections, range: acRange, baseCode: acCode,
				allowANS: true)
		}

		// The globals carry the codes, so they can only be written once the
		// codes are final.
		var dcGlobal = BitWriter()
		try FrameAssembly.writeDCGlobal(
			params: params, dcGroupCount: dim.dcGroupCount, code: dcCode,
			modularTree: modularTree.flatMap { tree in
				modularTreeCode.map { (tree: tree, code: $0) }
			},
			blockContextMap: blockContextMap, writer: &dcGlobal)
		sections[0] = SectionWriter(prewritten: dcGlobal)

		var acGlobal = BitWriter()
		try FrameAssembly.writeACGlobal(
			groupCount: dim.groupCount, code: acCode, coeffOrder: coeffOrder,
			writer: &acGlobal)
		sections[1 + dim.dcGroupCount] = SectionWriter(prewritten: acGlobal)

		FrameAssembly.writeFrameHeader(
			colorMode: .xyb(xQuantMatrixScale: params.xQuantMatrixScale),
			loopFilter: .init(gaborish: false, epfIterations: params.epfIterations),
			upsampling: params.upsampling,
			writer: &writer)
		FrameAssembly.combineSections(
			sections.map { $0.finished() }, writer: &writer)
	}

	/// Encodes an image as a bare JPEG XL codestream.
	///
	/// `distance` must be positive and finite; zero is unsupported. Values below
	/// 0.05 are normalized to 0.05. At values of 10 and above, the encoder
	/// selects 2x resampling for the input image and derives its effective distance
	/// from the original value. Lower targets mean higher quality; this VarDCT encoder is lossy.
	public static func encode(
		_ image: ImageBuffer,
		distance: Float,
		transferFunction: TransferFunction = .sRGB,
		optimizeCodes: Bool = true
	) throws -> [UInt8] {
		let params = try DistanceParams(distance: distance)
		let pixelFrame = preparePixelFrame(
			stripeAt: linearizingStripeSource(image),
			width: image.width, height: image.height, params: params)

		var writer = BitWriter()
		try ImageHeader.write(
			width: image.width, height: image.height,
			transferFunction: transferFunction, to: &writer)
		try encodeFrame(
			pixelFrame: pixelFrame,
			params: params, optimizeCodes: optimizeCodes, writer: &writer)
		writer.zeroPadToByte()
		return writer.take()
	}
}

extension Encoder {
	/// Encodes with the AC groups computed concurrently.
	///
	/// Produces byte-identical output to `encode`: groups read only the shared
	/// 8-bit samples and their own geometry, and the assembly step keys off each
	/// group's coordinates rather than the order results arrive in. What changes
	/// is only how long it takes.
	///
	/// `distance` must be positive and finite; zero is unsupported. Values below
	/// 0.05 are normalized to 0.05. At values of 10 and above, the encoder
	/// selects 2x resampling for the input image and derives its effective distance
	/// from the original value. Lower targets mean higher quality; this VarDCT encoder is lossy.
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
		let pixelFrame = preparePixelFrame(
			stripeAt: linearizingStripeSource(image),
			width: image.width, height: image.height, params: params)
		let dim = pixelFrame.dim

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
						xybAt: pixelFrame.xybAt, dim: dim,
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
		let blockContextMap =
			optimizeCodes ? computeBlockContextMap(computes, params: params) : nil
		if let blockContextMap {
			acCode = EntropyCode(
				contextMap: [UInt8](
					repeating: 0,
					count: blockContextMap.numContexts
						* (ACContext.nonZeroBuckets
							+ ACContext.zeroDensityCount)),
				prefixCodes: [])
		}

		let outputs = await withTaskGroup(of: ACGroupOutput.self) { group in
			for compute in computes {
				group.addTask {
					tokenizeACGroup(
						compute, order: coeffOrder.orders, mode: acMode,
						blockContextMap: blockContextMap)
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
		let dcData = try assemble(
			outputs: outputs, dim: dim, params: params,
			optimizeCodes: optimizeCodes, sections: &sections)

		let acRange = (2 + dim.dcGroupCount)..<(2 + dim.dcGroupCount + dim.groupCount)
		var modularTree: ContextTree.Prepared?
		var modularTreeCode: EntropyCode?
		if optimizeCodes {
			let tree = ContextTree.prepare(groups: dcData, jpegTranscode: false)
			let streams = try dcData.enumerated().map {
				try DCGroupEncoder.tokenStreams(
					data: $0.element, groupIndex: $0.offset, tree: tree)
			}
			let payloadTokens = streams.flatMap { $0.dc + $0.metadata }
			dcCode = SectionOptimizer.modularCode(
				tokenStreams: [payloadTokens], contextCount: tree.contextCount,
				extraDCPrecision: 1)
			let treeCode = SectionOptimizer.modularCode(
				tokenStreams: [tree.tokens],
				contextCount: ContextTree.treeContextCount,
				extraDCPrecision: 1)
			for index in dcData.indices {
				var section = BitWriter()
				try DCGroupEncoder.write(
					data: dcData[index], streams: streams[index],
					code: dcCode, writer: &section)
				sections[1 + index] = SectionWriter(prewritten: section)
			}
			modularTree = tree
			modularTreeCode = treeCode
			acCode = SectionOptimizer.optimize(
				sections: &sections, range: acRange, baseCode: acCode,
				allowANS: true)
		}

		var dcGlobal = BitWriter()
		try FrameAssembly.writeDCGlobal(
			params: params, dcGroupCount: dim.dcGroupCount, code: dcCode,
			modularTree: modularTree.flatMap { tree in
				modularTreeCode.map { (tree: tree, code: $0) }
			},
			blockContextMap: blockContextMap, writer: &dcGlobal)
		sections[0] = SectionWriter(prewritten: dcGlobal)

		var acGlobal = BitWriter()
		try FrameAssembly.writeACGlobal(
			groupCount: dim.groupCount, code: acCode, coeffOrder: coeffOrder,
			writer: &acGlobal)
		sections[1 + dim.dcGroupCount] = SectionWriter(prewritten: acGlobal)

		FrameAssembly.writeFrameHeader(
			colorMode: .xyb(xQuantMatrixScale: params.xQuantMatrixScale),
			loopFilter: .init(gaborish: false, epfIterations: params.epfIterations),
			upsampling: params.upsampling,
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
		try encodeJPEGFrame(
			transcode,
			loopFilter: .init(gaborish: false, epfIterations: 0),
			optimizeCodes: optimizeCodes, writer: &writer)
		writer.zeroPadToByte()
		return writer.take()
	}

	/// Returns the entropy codes it settled on, which is what the globals
	/// carry. Only the tests read them, to check the transmitted context maps
	/// against the decoder's rules.
	@discardableResult
	static func encodeJPEGFrame(
		_ transcode: JPEGTranscode,
		loopFilter: FrameAssembly.LoopFilter,
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
				subsampling: transcode.subsampling, epfSharpness: 0)
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
			var sampler = CoeffOrder.Sampler()
			for gy in 0..<dim.heightInGroups {
				for gx in 0..<dim.widthInGroups {
					let rect = dim.pixelRect(
						ix: gx, iy: gy, dim: Geometry.groupDim)
					let groupDim = ImageDim(
						width: rect.width, height: rect.height,
						blockAlignment: alignment)
					let coefficients =
						ACGroupEncoder.jpegCoefficientsForOrdering(
							transcode: transcode,
							blockX0: gx * Geometry.groupDimInBlocks,
							blockY0: gy * Geometry.groupDimInBlocks,
							widthInBlocks: groupDim.widthInBlocks,
							heightInBlocks: groupDim.heightInBlocks)
					CoeffOrder.accumulateGroup(
						coefficients, widthInBlocks: groupDim.widthInBlocks,
						heightInBlocks: groupDim.heightInBlocks,
						sampler: &sampler, counts: &counts)
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

				var groupDC = [[Int32]](
					repeating: [Int32](
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

		var modularTree: ContextTree.Prepared?
		var modularTreeCode: EntropyCode?
		if optimizeCodes {
			let tree = ContextTree.prepare(groups: dcData, jpegTranscode: true)
			let streams = try dcData.enumerated().map {
				try DCGroupEncoder.tokenStreams(
					data: $0.element, groupIndex: $0.offset, tree: tree)
			}
			let payloadTokens = streams.flatMap { $0.dc + $0.metadata }
			dcCode = SectionOptimizer.modularCode(
				tokenStreams: [payloadTokens], contextCount: tree.contextCount,
				extraDCPrecision: 0)
			let treeCode = SectionOptimizer.modularCode(
				tokenStreams: [tree.tokens],
				contextCount: ContextTree.treeContextCount,
				extraDCPrecision: 0)
			for index in dcData.indices {
				var section = BitWriter()
				try DCGroupEncoder.write(
					data: dcData[index], streams: streams[index],
					code: dcCode, writer: &section)
				sections[1 + index] = SectionWriter(prewritten: section)
			}
			modularTree = tree
			modularTreeCode = treeCode
		} else {
			for i in 0..<dim.dcGroupCount {
				DCGroupEncoder.write(data: dcData[i], writer: &sections[1 + i])
			}
		}

		if optimizeCodes {
			acCode = SectionOptimizer.optimize(
				sections: &sections, range: acRange, baseCode: acCode,
				allowANS: true)
		}

		var dcGlobal = BitWriter()
		try FrameAssembly.writeDCGlobal(
			params: try DistanceParams(distance: 1.0),
			dcGroupCount: dim.dcGroupCount, code: dcCode,
			modularTree: modularTree.flatMap { tree in
				modularTreeCode.map { (tree: tree, code: $0) }
			},
			dcQuantization: (0..<3).map { transcode.dcQuantization(channel: $0) },
			globalScale: FrameAssembly.jpegGlobalScale,
			quantDC: 1,
			blockContextMap: blockContextMap, writer: &dcGlobal)
		sections[0] = SectionWriter(prewritten: dcGlobal)

		var acGlobal = BitWriter()
		try FrameAssembly.writeACGlobal(
			groupCount: dim.groupCount, code: acCode,
			quantTables: (0..<3).map { transcode.quantTable(channel: $0) },
			coeffOrder: coeffOrder, writer: &acGlobal)
		sections[1 + dim.dcGroupCount] = SectionWriter(prewritten: acGlobal)

		FrameAssembly.writeFrameHeader(
			colorMode: .ycbcr(subsampling: transcode.subsampling),
			loopFilter: loopFilter,
			writer: &writer)
		FrameAssembly.combineSections(
			sections.map { $0.finished() }, writer: &writer)
		return (dcCode, acCode)
	}
}

extension Encoder {
	struct PixelFrameInput: Sendable {
		let dim: ImageDim
		let xybAt: @Sendable (Rect) -> PaddedStripe
	}

	static func preparePixelFrame(
		stripeAt: @escaping @Sendable (Rect) -> PaddedStripe,
		width: Int, height: Int, params: DistanceParams
	) -> PixelFrameInput {
		precondition(width > 0 && height > 0)
		if params.upsampling == 1 {
			return PixelFrameInput(
				dim: ImageDim(width: width, height: height),
				xybAt: { AdaptiveQuantPipeline.toXYB(stripeAt($0)) })
		}

		let original = stripeAt(Rect(x0: 0, y0: 0, width: width, height: height))
		let downsampled = PixelDownsampler.downsample2(
			AdaptiveQuantPipeline.toXYB(original))
		let storage = paddedPixelStorage(downsampled)
		return PixelFrameInput(
			dim: ImageDim(
				width: Geometry.divCeil(width, 2),
				height: Geometry.divCeil(height, 2)),
			xybAt: { rect in Self.copyPixelStorage(storage, rect: rect) })
	}

	private static func paddedPixelStorage(_ image: PaddedStripe) -> PaddedStripe {
		let width = Geometry.roundUp(image.width, to: Geometry.blockDim)
		let height = Geometry.roundUp(image.height, to: Geometry.blockDim)
		let planes = image.planes.map { plane in
			var padded = [Float](repeating: 0, count: width * height)
			for y in 0..<height {
				let sourceY = min(y, image.height - 1)
				for x in 0..<width {
					padded[y * width + x] =
						plane[
							sourceY * image.width
								+ min(x, image.width - 1)]
				}
			}
			return padded
		}
		return PaddedStripe(width: width, height: height, planes: planes)
	}

	private static func copyPixelStorage(
		_ image: PaddedStripe, rect: Rect
	) -> PaddedStripe {
		let width = Geometry.roundUp(rect.width, to: Geometry.blockDim)
		let height = Geometry.roundUp(rect.height, to: Geometry.blockDim)
		let planes = image.planes.map { plane in
			var output = [Float](repeating: 0, count: width * height)
			for y in 0..<height {
				let sourceY = min(rect.y0 + y, image.height - 1)
				for x in 0..<width {
					let sourceX = min(rect.x0 + x, image.width - 1)
					output[y * width + x] =
						plane[sourceY * image.width + sourceX]
				}
			}
			return output
		}
		return PaddedStripe(width: width, height: height, planes: planes)
	}
}

enum PixelDownsampler {
	static let kernel: [Float] = [
		-0.000314256996835, -0.000314256996835, -0.000897597057705,
		-0.000562751488849, -0.000176807273646, 0.001864627368902,
		0.001864627368902, -0.000176807273646, -0.000562751488849,
		-0.000897597057705, -0.000314256996835, -0.000314256996835,
		-0.000314256996835, -0.001527942804748, -0.000121760530512,
		0.000191123989093, 0.010193185932466, 0.058637519197110,
		0.058637519197110, 0.010193185932466, 0.000191123989093,
		-0.000121760530512, -0.001527942804748, -0.000314256996835,
		-0.000897597057705, -0.000121760530512, 0.000946363683751,
		0.007113577630288, 0.000437956841058, -0.000372823835211,
		-0.000372823835211, 0.000437956841058, 0.007113577630288,
		0.000946363683751, -0.000121760530512, -0.000897597057705,
		-0.000562751488849, 0.000191123989093, 0.007113577630288,
		0.044592622228814, 0.000222278879007, -0.162864473015945,
		-0.162864473015945, 0.000222278879007, 0.044592622228814,
		0.007113577630288, 0.000191123989093, -0.000562751488849,
		-0.000176807273646, 0.010193185932466, 0.000437956841058,
		0.000222278879007, -0.000913092543974, -0.017071696107902,
		-0.017071696107902, -0.000913092543974, 0.000222278879007,
		0.000437956841058, 0.010193185932466, -0.000176807273646,
		0.001864627368902, 0.058637519197110, -0.000372823835211,
		-0.162864473015945, -0.017071696107902, 0.414660099370354,
		0.414660099370354, -0.017071696107902, -0.162864473015945,
		-0.000372823835211, 0.058637519197110, 0.001864627368902,
		0.001864627368902, 0.058637519197110, -0.000372823835211,
		-0.162864473015945, -0.017071696107902, 0.414660099370354,
		0.414660099370354, -0.017071696107902, -0.162864473015945,
		-0.000372823835211, 0.058637519197110, 0.001864627368902,
		-0.000176807273646, 0.010193185932466, 0.000437956841058,
		0.000222278879007, -0.000913092543974, -0.017071696107902,
		-0.017071696107902, -0.000913092543974, 0.000222278879007,
		0.000437956841058, 0.010193185932466, -0.000176807273646,
		-0.000562751488849, 0.000191123989093, 0.007113577630288,
		0.044592622228814, 0.000222278879007, -0.162864473015945,
		-0.162864473015945, 0.000222278879007, 0.044592622228814,
		0.007113577630288, 0.000191123989093, -0.000562751488849,
		-0.000897597057705, -0.000121760530512, 0.000946363683751,
		0.007113577630288, 0.000437956841058, -0.000372823835211,
		-0.000372823835211, 0.000437956841058, 0.007113577630288,
		0.000946363683751, -0.000121760530512, -0.000897597057705,
		-0.000314256996835, -0.001527942804748, -0.000121760530512,
		0.000191123989093, 0.010193185932466, 0.058637519197110,
		0.058637519197110, 0.010193185932466, 0.000191123989093,
		-0.000121760530512, -0.001527942804748, -0.000314256996835,
		-0.000314256996835, -0.000314256996835, -0.000897597057705,
		-0.000562751488849, -0.000176807273646, 0.001864627368902,
		0.001864627368902, -0.000176807273646, -0.000562751488849,
		-0.000897597057705, -0.000314256996835, -0.000314256996835,
	]

	static func downsample2(_ xyb: PaddedStripe) -> PaddedStripe {
		let width = Geometry.divCeil(xyb.width, 2)
		let height = Geometry.divCeil(xyb.height, 2)
		let box = xyb.planes.map { boxDownsample($0, width: xyb.width, height: xyb.height) }
		let masks = box.map { createMask($0, width: width, height: height) }
		let planes = xyb.planes.indices.map { channel -> [Float] in
			let input = xyb.planes[channel]
			let mask = masks[channel]
			var output = [Float](repeating: 0, count: width * height)
			for y in 0..<height {
				for x in 0..<width {
					var minValue = Float.greatestFiniteMagnitude
					// The source uses the smallest positive normal value here.
					var maxValue = Float.leastNormalMagnitude
					for ky in 5..<7 {
						let iy = clampIndex(
							y * 2 + ky - 5, limit: xyb.height)
						for kx in 5..<7 {
							let ix = clampIndex(
								x * 2 + kx - 5, limit: xyb.width)
							let value = input[iy * xyb.width + ix]
							minValue = min(minValue, value)
							maxValue = max(maxValue, value)
						}
					}

					var sum: Float = 0
					for ky in 0..<12 {
						let iy = clampIndex(
							y * 2 + ky - 5, limit: xyb.height)
						let inputRow = iy * xyb.width
						for kx in 0..<12 {
							let ix = clampIndex(
								x * 2 + kx - 5, limit: xyb.width)
							sum +=
								input[inputRow + ix]
								* Self.kernel[ky * 12 + kx]
						}
					}

					let a = mask[y * width + x]
					let clipMin = minValue - a
					let clipMax = maxValue + a
					output[y * width + x] = min(max(sum, clipMin), clipMax)
				}
			}
			return output
		}
		return PaddedStripe(width: width, height: height, planes: planes)
	}

	private static func boxDownsample(_ input: [Float], width: Int, height: Int) -> [Float] {
		let outWidth = Geometry.divCeil(width, 2)
		let outHeight = Geometry.divCeil(height, 2)
		var output = [Float](repeating: 0, count: outWidth * outHeight)
		for y in 0..<outHeight {
			for x in 0..<outWidth {
				var sum: Float = 0
				var count: Float = 0
				for dy in 0..<2 where y * 2 + dy < height {
					for dx in 0..<2 where x * 2 + dx < width {
						sum += input[(y * 2 + dy) * width + x * 2 + dx]
						count += 1
					}
				}
				output[y * outWidth + x] = sum / count
			}
		}
		return output
	}

	private static func createMask(_ image: [Float], width: Int, height: Int) -> [Float] {
		var mask = [Float](repeating: 0, count: width * height)
		for y in 0..<height {
			for x in 0..<width {
				let center = image[y * width + x]
				let west = image[y * width + max(x - 1, 0)]
				let east = image[y * width + min(x + 1, width - 1)]
				let north = image[max(y - 1, 0) * width + x]
				let south = image[min(y + 1, height - 1) * width + x]
				var min1 = Float.greatestFiniteMagnitude
				var min2 = Float.greatestFiniteMagnitude
				for difference in [
					abs(center - west), abs(center - east), abs(center - north),
					abs(center - south),
				] {
					if difference < min2 {
						if difference < min1 {
							min2 = min1
							min1 = difference
						} else {
							min2 = difference
						}
					}
				}
				mask[y * width + x] = min2
			}
		}
		return mask
	}

	private static func clampIndex(_ index: Int, limit: Int) -> Int {
		min(max(index, 0), limit - 1)
	}
}
