@testable import JXLEncoder

extension SemanticDump {
	static let decoderObservableCategories: Set<String> = [
		"image_header", "image_sample_format", "frame", "frame_flags", "gaborish",
		"epf", "x_matrix_scale", "b_matrix_scale", "coeff_order", "block_context",
		"context_map", "quant_field", "ac_entropy", "ac_entropy_alphabet",
	]

	mutating func recordPixelDecisions(_ decisions: SwiftFrameDecisions) {
		let transferFunction: Int64
		switch decisions.transferFunction {
		case .linear: transferFunction = 8
		case .sRGB: transferFunction = 13
		}
		record(
			"image_header.size",
			.integers([Int64(decisions.width), Int64(decisions.height)]))
		record("image_header.transfer_function", .integers([transferFunction]))
		record("image_header.color_space", .integers([0]))
		record("image_header.white_point", .integers([1]))
		record("image_header.primaries", .integers([1]))
		record("image_header.rendering_intent", .integers([1]))
		record("image_header.xyb", .integers([1]))
		record("image_header.num_extra_channels", .integers([0]))
		record("image_sample_format.floating_point", .integers([1]))
		record("image_sample_format.bits_per_sample", .integers([32]))
		record("image_sample_format.exponent_bits_per_sample", .integers([8]))
		record("frame_flags.flags", .integers([128]))
		record("gaborish.enabled", .integers([decisions.params.epfIterations == 2 ? 1 : 0]))
		record("epf.iterations", .integers([Int64(decisions.params.epfIterations)]))
		record(
			"x_matrix_scale.value",
			.integers([Int64(decisions.params.xQuantMatrixScale)]))
		record("b_matrix_scale.value", .integers([2]))
		for channel in 0..<3 {
			record(
				"quant_matrix.dct8.c\(channel)",
				.floats(Array(QuantMatrices.matrix(channel: channel))))
			record(
				"inverse_quant_matrix.dct8.c\(channel)",
				.floats(Array(QuantMatrices.inverseMatrix(channel: channel))))
		}
		record("dc_quant_matrix.values", .floats(ACGroupEncoder.dcQuant))
		record("inverse_dc_quant_matrix.values", .floats(ACGroupEncoder.inverseDCQuant))
	}
}
