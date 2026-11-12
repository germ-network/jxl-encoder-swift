@testable import JXLEncoder

enum SwiftJPEGSemanticEncoding {
	struct Result {
		let codestream: [UInt8]
		let decisions: SwiftJPEGFrameDecisions
	}

	static func encode(_ transcode: JPEGTranscode) throws -> Result {
		fatalError("Pending JPEG decision capture")
	}

	static func contextWitness(
		_ transcode: JPEGTranscode, reference: SemanticDump
	) throws -> SemanticDump {
		fatalError("Pending JPEG context witness")
	}

	static func dcBoundaryWitness(
		thresholds: [Int], dc: [Int32]
	) throws -> SemanticDump {
		fatalError("Pending DC boundary witness")
	}
}

struct SwiftJPEGFrameDecisions {
	let transcode: JPEGTranscode
	let coeffOrder: CoeffOrder.Result
	let blockContextMap: JPEGBlockContextMap.Result
	let dcCode: EntropyCode
	let acCode: EntropyCode
	let acGroups: [[StagedRecord]]
}

enum JPEGSemanticCaptureError: Error {
	case invalidReference(String)
	case invalidGeometry
	case unsupportedWitnessConfiguration
	case nonTokenACRecord(group: Int)
}

extension SemanticDump {
	init(swiftJPEGDecisions: SwiftJPEGFrameDecisions) throws {
		fatalError("Pending JPEG semantic dump")
	}
}
