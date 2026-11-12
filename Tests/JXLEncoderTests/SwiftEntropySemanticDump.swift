extension SemanticDump {
	mutating func recordEntropyDecisions(_ decisions: SwiftFrameDecisions) throws {
		try recordACEntropyCode(decisions.acCode)
	}
}
