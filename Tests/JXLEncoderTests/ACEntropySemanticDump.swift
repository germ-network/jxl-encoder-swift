@testable import JXLEncoder

enum ACEntropyCaptureError: Error, Equatable {
	case invalidTableCount
	case invalidContextMap
	case invalidANSTable(Int)
	case invalidPrefixTable(Int)
	case duplicateField(String)
}

extension SemanticDump {
	mutating func recordACEntropyCode(_ code: EntropyCode) throws {
		_ = code
	}
}
