import Foundation

@testable import JXLEncoder

/// The decisions the optimized pixel path (`Encoder.encodeFrame` with
/// `optimizeCodes: true`) makes for one frame, captured so they can be dumped
/// and, in mutation tests, altered before the frame is written.
struct SwiftFrameDecisions {
	let width: Int
	let height: Int
	let params: DistanceParams
	var coeffOrder: CoeffOrder.Result
	var acCode: EntropyCode
	/// No category reads it yet; the entropy categories will.
	var dcCode: EntropyCode
	/// Per AC group, in group raster order: the raw quant field the group
	/// wrote, block-major.
	var quantFields: [[UInt8]]
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
		stripeAt: @Sendable (Rect) -> PaddedStripe, altering: Alterations
	) throws -> Result {
		let params = try DistanceParams(distance: distance)
		let dim = ImageDim(width: width, height: height)
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
				stripeAt: stripeAt, dim: dim, groupX: $0 % dim.widthInGroups,
				groupY: $0 / dim.widthInGroups, params: params)
		}
		var order = Encoder.computeCoeffOrder(computes, dim: dim)
		altering.coeffOrder(&order)
		let outputs = computes.reversed().map {
			Encoder.tokenizeACGroup($0, order: order.orders, mode: .staging(acCode))
		}
		Encoder.assemble(outputs: outputs, dim: dim, sections: &sections)
		dcCode = SectionOptimizer.optimize(
			sections: &sections, range: 1..<(1 + dim.dcGroupCount), baseCode: dcCode)
		acCode = SectionOptimizer.optimize(
			sections: &sections, range: acRange, baseCode: acCode, allowANS: true)
		altering.acCode(&acCode)
		var dcGlobal = BitWriter()
		try FrameAssembly.writeDCGlobal(
			params: params, dcGroupCount: dim.dcGroupCount, code: dcCode,
			allowContextMapANS: true, writer: &dcGlobal)
		sections[0] = SectionWriter(prewritten: dcGlobal)
		var acGlobal = BitWriter()
		try FrameAssembly.writeACGlobal(
			groupCount: dim.groupCount, code: acCode, coeffOrder: order,
			allowContextMapANS: true, writer: &acGlobal)
		sections[1 + dim.dcGroupCount] = SectionWriter(prewritten: acGlobal)
		FrameAssembly.writeFrameHeader(
			colorMode: .xyb(xQuantMatrixScale: params.xQuantMatrixScale),
			epfIterations: params.epfIterations, writer: &writer)
		FrameAssembly.combineSections(sections.map { $0.finished() }, writer: &writer)
		writer.zeroPadToByte()
		return Result(
			codestream: writer.take(),
			decisions: SwiftFrameDecisions(
				width: width, height: height, params: params, coeffOrder: order,
				acCode: acCode, dcCode: dcCode,
				quantFields: computes.map(\.quantField)))
	}

}

extension SemanticDump {
	/// The harness categories the Swift side emits from its own decisions.
	/// Lanes that add a category add it here alongside its emitter.
	static let swiftEmittedCategories: Set<String> = [
		"frame", "coeff_order", "block_context", "context_map", "quant_field",
	]

	/// The dump of `decisions` in exactly the field names and layout the
	/// harness's decoder-side dumpers write for the same categories.
	init(swiftDecisions decisions: SwiftFrameDecisions) throws {
		self.init()
		try recordACEntropyCode(decisions.acCode)
		let dim = ImageDim(width: decisions.width, height: decisions.height)
		let params = decisions.params
		record("frame.size", .integers([Int64(decisions.width), Int64(decisions.height)]))
		record("frame.encoding", .integers([0]))
		record("frame.groups", .integers([Int64(dim.groupCount)]))
		record("frame.dc_groups", .integers([Int64(dim.dcGroupCount)]))
		record("frame.passes", .integers([1]))
		record("frame.xyb", .integers([1]))
		record("frame.qm_scales", .integers([Int64(params.xQuantMatrixScale), 2]))
		// The default filter syntax at two iterations also enables gaborish.
		record("frame.loop_filter.gab", .integers([params.epfIterations == 2 ? 1 : 0]))
		record("frame.loop_filter.epf_iters", .integers([Int64(params.epfIterations)]))
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
		record("block_context.qf_thresholds", .integers([]))
		record(
			"block_context.ctx_map",
			.integers(ACContext.compactBlockIndexMap.map(Int64.init)))
		record("block_context.num_ctxs", .integers([Int64(ACContext.numBlockCategories)]))
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
	}
}
