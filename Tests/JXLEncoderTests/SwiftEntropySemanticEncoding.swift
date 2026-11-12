@testable import JXLEncoder

enum SwiftEntropySemanticEncoding {
	static func histogram(counts: [Int], logAlphaSize: Int) -> SemanticDump {
		fatalError("Histogram capture is not implemented")
	}

	static func clusters(histograms: [Histogram], limit: Int) -> SemanticDump {
		fatalError("Cluster capture is not implemented")
	}

	static func contextMap(entries: [UInt8], allowANS: Bool) throws -> SemanticDump {
		fatalError("Context map capture is not implemented")
	}

	static func tree(dcGroupCount: Int) -> SemanticDump {
		fatalError("Tree capture is not implemented")
	}

	static func modularTokens(data: DCGroupData) -> SemanticDump {
		fatalError("Modular token capture is not implemented")
	}

	static func acTokens(group: Encoder.ACGroupCompute, order: [[Int]]) -> SemanticDump {
		fatalError("AC token capture is not implemented")
	}

	static func tokenStreams(tokens: [[Token]], code: EntropyCode) -> SemanticDump {
		fatalError("Token stream capture is not implemented")
	}

	static func coefficientOrder(counts: [Int64]) -> SemanticDump {
		fatalError("Coefficient order capture is not implemented")
	}

	static func frameLayout(codestream: [UInt8]) throws -> SemanticDump {
		fatalError("Frame layout capture is not implemented")
	}
}
