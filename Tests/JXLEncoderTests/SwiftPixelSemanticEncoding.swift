@testable import JXLEncoder

extension SwiftSemanticEncoding {
	static func coefficients(
		from groups: [Encoder.ACGroupCompute], dimension: ImageDim
	) -> (ac: [[Int32]], dc: [[Int16]]) {
		preconditionFailure("Pixel coefficient assembly is not implemented")
	}
}
