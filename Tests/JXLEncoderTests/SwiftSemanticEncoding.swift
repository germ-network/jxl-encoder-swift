import Foundation

@testable import JXLEncoder

/// The decisions the optimized pixel path (`Encoder.encodeFrame` with
/// `optimizeCodes: true`) makes for one frame, captured so they can be dumped
/// and, in mutation tests, altered before the frame is written.
struct SwiftFrameDecisions {
	let width: Int
	let height: Int
	let transferFunction: TransferFunction
	let params: DistanceParams
	let loopFilter: FrameAssembly.LoopFilter
	var coeffOrder: CoeffOrder.Result
	var acCode: EntropyCode
	var blockContextMap: JPEGBlockContextMap.Result?
	/// No category reads it yet; the entropy categories will.
	var dcCode: EntropyCode
	/// Per AC group, in group raster order: the raw quant field the group
	/// wrote, block-major.
	var quantFields: [[UInt8]]
	var pixelGroups: [Encoder.ACGroupCompute]?
}

/// Re-runs `Encoder.encodeFrame`'s optimized composition from the same
/// internal steps, so the Swift side can report the decisions it made.
///
/// Must stay byte-identical to `Encoder.encode` / `Encoder.encodeFrame` when
/// nothing is altered; a test pins that, so this copy can't drift from the
/// encoder it describes.
enum SwiftSemanticEncoding {
	struct Result {
		let codestream: [UInt8]
		let decisions: SwiftFrameDecisions
	}

	/// Where a mutation test may alter a decision, after it's computed and
	/// before anything that depends on it is written. Each alteration must leave
	/// a codestream that still decodes.
	struct Alterations: Sendable {
		/// Before AC tokenization, so tokens and the signalled order agree.
		var coeffOrder: @Sendable (inout CoeffOrder.Result) -> Void = { _ in }
		/// After the AC code is optimized, before the AC global section is
		/// written. The AC groups are already written with the unaltered code
		/// by then, so only a context that carries no tokens may be remapped,
		/// and only to a cluster other contexts still use.
		var acCode: @Sendable (inout EntropyCode) -> Void = { _ in }

		static let none = Alterations()
	}

	/// 8-bit sRGB input, the production path (`Encoder.encode`).
	static func encode(
		_ image: ImageBuffer, distance: Float, altering: Alterations = .none
	) throws -> Result {
		try compose(
			width: image.width, height: image.height, distance: distance,
			transfer: .sRGB, stripeAt: Encoder.linearizingStripeSource(image),
			altering: altering)
	}

	/// Pre-linearized float input with a linear transfer function, the path the
	/// stage-dump tests use (`EncoderTests.encodeMatchingReference`, but optimized).
	static func encode(
		linear: StageDump, distance: Float, altering: Alterations = .none
	) throws -> Result {
		let pixels = linear.interleaved
		let width = linear.width
		return try compose(
			width: linear.width, height: linear.height, distance: distance,
			transfer: .linear,
			stripeAt: {
				PlaneBuffer.copyAndPad(source: pixels, sourceWidth: width, rect: $0)
			}, altering: altering)
	}
	private static func compose(
		width: Int, height: Int, distance: Float, transfer: TransferFunction,
		stripeAt: @escaping @Sendable (Rect) -> PaddedStripe, altering: Alterations
	) throws -> Result {
		let params = try DistanceParams(distance: distance)
		let pixelFrame = Encoder.preparePixelFrame(
			stripeAt: stripeAt, width: width, height: height, params: params)
		let loopFilter = FrameAssembly.LoopFilter(
			gaborish: false, epfIterations: params.epfIterations)
		let dim = pixelFrame.dim
		var writer = BitWriter()
		try ImageHeader.write(
			width: width, height: height, transferFunction: transfer, to: &writer)
		var dcCode = EntropyCode.staticDC
		var acCode = EntropyCode.staticAC
		var sections = Array(
			repeating: SectionWriter(mode: .staging(dcCode)),
			count: 2 + dim.dcGroupCount + dim.groupCount)
		let acRange = (2 + dim.dcGroupCount)..<sections.count
		for i in acRange { sections[i] = SectionWriter(mode: .staging(acCode)) }
		let computes = (0..<dim.groupCount).map {
			Encoder.computeACGroup(
				xybAt: pixelFrame.xybAt, dim: dim,
				groupX: $0 % dim.widthInGroups,
				groupY: $0 / dim.widthInGroups, params: params)
		}
		let plan = FramePlan(dim: dim, upsampling: params.upsampling)
		var order = Encoder.computeCoeffOrder(computes, dim: dim, plan: plan)
		altering.coeffOrder(&order)
		let blockContextMap = Encoder.computeBlockContextMap(
			computes, params: params, plan: plan)
		acCode = EntropyCode(
			contextMap: [UInt8](
				repeating: 0,
				count: plan.histogramSetCount
					* Encoder.PixelFrameAnalysis.contextsPerSet(blockContextMap)
			),
			prefixCodes: [])
		let analysis = Encoder.PixelFrameAnalysis(
			coeffOrder: order, blockContextMap: blockContextMap, acCode: acCode,
			plan: plan)
		let outputs = computes.reversed().map {
			Encoder.tokenizeACGroup($0, analysis: analysis, mode: .staging(acCode))
		}
		let dcData = try Encoder.assemble(
			outputs: outputs, dim: dim, params: params,
			optimizeCodes: true, sections: &sections)
		let isStreaming: Bool
		if case .streaming = plan { isStreaming = true } else { isStreaming = false }
		var modularTree: (tree: ContextTree.Prepared, code: EntropyCode)?
		if isStreaming {
			for index in dcData.indices {
				var section = BitWriter()
				try DCGroupEncoder.write(
					data: dcData[index],
					local: DCGroupEncoder.localStreams(data: dcData[index]),
					writer: &section)
				sections[1 + index] = SectionWriter(prewritten: section)
			}
		} else {
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
				contextCount: ContextTree.treeContextCount, extraDCPrecision: 1)
			for index in dcData.indices {
				var section = BitWriter()
				try DCGroupEncoder.write(
					data: dcData[index], streams: streams[index],
					code: dcCode, writer: &section)
				sections[1 + index] = SectionWriter(prewritten: section)
			}
			modularTree = (tree: tree, code: treeCode)
		}
		if isStreaming {
			acCode = SectionOptimizer.optimizeStreaming(
				sections: &sections, range: acRange,
				histogramSetCount: plan.histogramSetCount,
				contextsPerSet: analysis.acContextsPerSet)
		} else {
			acCode = SectionOptimizer.optimize(
				sections: &sections, range: acRange, baseCode: acCode,
				allowANS: true)
		}
		altering.acCode(&acCode)
		var dcGlobal = BitWriter()
		if isStreaming {
			try FrameAssembly.writeStreamingDCGlobal(
				params: params, blockContextMap: blockContextMap, writer: &dcGlobal)
		} else {
			try FrameAssembly.writeDCGlobal(
				params: params, dcGroupCount: dim.dcGroupCount, code: dcCode,
				modularTree: modularTree,
				blockContextMap: blockContextMap, writer: &dcGlobal)
		}
		sections[0] = SectionWriter(prewritten: dcGlobal)
		var acGlobal = BitWriter()
		try FrameAssembly.writeACGlobal(
			groupCount: dim.groupCount, code: acCode, coeffOrder: order,
			histogramSetCount: plan.histogramSetCount, writer: &acGlobal)
		sections[1 + dim.dcGroupCount] = SectionWriter(prewritten: acGlobal)
		FrameAssembly.writeFrameHeader(
			colorMode: .xyb(xQuantMatrixScale: params.xQuantMatrixScale),
			loopFilter: loopFilter,
			upsampling: params.upsampling,
			writer: &writer)
		FrameAssembly.combineSections(sections.map { $0.finished() }, writer: &writer)
		writer.zeroPadToByte()
		return Result(
			codestream: writer.take(),
			decisions: SwiftFrameDecisions(
				width: width, height: height, transferFunction: transfer,
				params: params, loopFilter: loopFilter, coeffOrder: order,
				acCode: acCode, blockContextMap: blockContextMap,
				dcCode: dcCode,
				quantFields: computes.map(\.quantField), pixelGroups: computes))
	}

}

extension SemanticDump {
	/// The harness categories the Swift side emits from its own decisions.
	/// Lanes that add a category add it here alongside its emitter.
	static let swiftEmittedCategories: Set<String> = [
		"image_header", "image_sample_format", "frame", "frame_flags", "gaborish",
		"epf", "x_matrix_scale", "b_matrix_scale", "coeff_order", "block_context",
		"context_map", "quant_field", "quant_matrix", "inverse_quant_matrix",
		"dc_quant_matrix", "inverse_dc_quant_matrix", "ac_entropy",
		"ac_entropy_alphabet",
	]

	/// The dump of `decisions` in exactly the field names and layout the
	/// harness's decoder-side dumpers write for the same categories.
	init(swiftDecisions decisions: SwiftFrameDecisions) throws {
		self.init()
		let params = decisions.params
		let dim = ImageDim(
			width: Geometry.divCeil(decisions.width, decisions.params.upsampling),
			height: Geometry.divCeil(decisions.height, decisions.params.upsampling))
		guard
			let pixelGroups = decisions.pixelGroups,
			pixelGroups.count == dim.groupCount,
			decisions.quantFields.count == dim.groupCount
		else { throw SemanticDumpError.unimplemented }
		try recordACEntropyCode(decisions.acCode)
		record("frame.encoding", .integers([0]))
		record("frame.groups", .integers([Int64(dim.groupCount)]))
		record("frame.dc_groups", .integers([Int64(dim.dcGroupCount)]))
		record("frame.passes", .integers([1]))
		for channel in 0..<3 {
			record(
				"coeff_order.dct8.c\(channel)",
				.integers(decisions.coeffOrder.orders[channel].map(Int64.init)))
			record("block_context.dc_thresholds.c\(channel)", .integers([]))
		}
		record(
			"coeff_order.nondefault_orders",
			.integers([
				decisions.coeffOrder.orders.contains { $0 != CoeffOrder.natural }
					? 1 : 0
			]))
		record(
			"block_context.qf_thresholds",
			.integers((decisions.blockContextMap?.qfThresholds ?? []).map(Int64.init)))
		record(
			"block_context.ctx_map",
			.integers((decisions.blockContextMap?.contextMap ?? []).map(Int64.init)))
		record(
			"block_context.num_ctxs",
			.integers([Int64(decisions.blockContextMap?.numContexts ?? 0)]))
		record("context_map.num_histograms", .integers([1]))
		let code = decisions.acCode
		let map =
			code.originalContextMap?.map { code.contextMap[Int($0)] } ?? code.contextMap
		record("context_map.ac", .integers(map.map(Int64.init)))
		var quant = Array(
			repeating: Int64(0), count: dim.widthInBlocks * dim.heightInBlocks)
		for group in 0..<dim.groupCount {
			let x0 = (group % dim.widthInGroups) * 32
			let y0 = (group / dim.widthInGroups) * 32
			let width = min(32, dim.widthInBlocks - x0)
			let height = min(32, dim.heightInBlocks - y0)
			for y in 0..<height {
				for x in 0..<width {
					quant[(y0 + y) * dim.widthInBlocks + x0 + x] = Int64(
						decisions.quantFields[group][y * width + x])
				}
			}
		}
		record("quant_field.raw", .integers(quant))
		record("quant_field.global_scale", .integers([Int64(params.globalScale)]))
		record("quant_field.quant_dc", .integers([Int64(params.quantDC)]))
		recordPixelDecisions(decisions)
	}
}
