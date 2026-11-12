struct EntropyReferenceFixture {
	let input: SemanticDump
	let expected: SemanticDump

	static func load(_ name: String) throws -> Self {
		fatalError("Entropy reference fixture loading is not implemented")
	}
}
