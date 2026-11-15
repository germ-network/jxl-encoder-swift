enum PixelBlockEntropyModel {
	static func compute(
		quantCounts: [Int], params: DistanceParams
	) -> JPEGBlockContextMap.Result {
		preconditionFailure("Pixel block entropy model is not implemented")
	}
}

extension JPEGBlockContextMap.Result {
	func category(channel: Int, dcBucket: Int, rawQuant: UInt32) -> Int {
		preconditionFailure("Quant-field block category is not implemented")
	}
}

extension ACGroupEncoder {
	static func tokenizeGroup(
		coefficients: [[Int32]],
		widthInBlocks: Int,
		heightInBlocks: Int,
		subsampling: ChromaSubsampling,
		order: [[Int]],
		blockContextMap: JPEGBlockContextMap.Result,
		rawQuantField: [UInt8],
		writer: inout SectionWriter
	) {
		preconditionFailure("Pixel model tokenization is not implemented")
	}
}
