@testable import JXLEncoder

extension SemanticDump {
	static let decoderObservableCategories: Set<String> = [
		"frame", "coeff_order", "block_context", "context_map", "quant_field",
	]

	mutating func recordPixelDecisions(_ decisions: SwiftFrameDecisions) {
		preconditionFailure("Pixel decision emission is not implemented")
	}
}
