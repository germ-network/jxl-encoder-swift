import Testing

@testable import JXLEncoder

@Suite("Upstream context-map encoding")
struct ContextMapTranslationTests {
	@Test(.disabled("Awaiting context-map translation"))
	func fixedUintMatchesPinnedReference() throws {
		let configuration = HybridUintConfiguration(
			splitExponent: 2, msbInToken: 0, lsbInToken: 1)
		let encoded = configuration.encode(4)
		#expect(encoded.symbol == 4)
		#expect(encoded.bitCount == 1)
		#expect(encoded.bits == 0)
	}

	@Test(.disabled("Awaiting context-map translation"))
	func runLengthsAndDistanceContextsMatchPinnedReference() throws {
		let result = ContextMapEntropy.runLengthEncode(
			Array(repeating: 0, count: 100) + Array(repeating: 1, count: 100))
		#expect(result.enabled)
		#expect(result.tokens.contains { $0.isLength && $0.token.context == 0 })
		#expect(
			result.tokens.contains {
				!$0.isLength && $0.token.context == 1 && $0.token.value == 0
			})
	}

	@Test(.disabled("Awaiting context-map translation"))
	func bestClusteringMatchesPinnedReference() throws {
		var first = Histogram()
		first.add(0)
		var second = Histogram()
		second.add(0)
		let merged = ContextMapEntropy.cluster([first, second])
		#expect(merged.contextMap == [0, 0])
		#expect(merged.histograms.count == 1)
		Issue.record(
			"Add pinned native merge and survive witnesses, including length symbols")
	}

	@Test(.disabled("Awaiting context-map translation"))
	func candidateCostsMatchPinnedReference() throws {
		let prepared = ContextMapEntropy.prepare([0, 1, 0, 1])
		#expect(
			prepared.uintConfigurations.allSatisfy {
				$0
					== HybridUintConfiguration(
						splitExponent: 2, msbInToken: 0, lsbInToken: 1)
			})
		#expect(prepared.contextMap.count == (prepared.runLength.enabled ? 2 : 1))
		#expect(prepared.usesPrefixCode)
		#expect(prepared.logAlphabetSize == PrefixCodeWriter.prefixMaxBits)
		var writer = BitWriter()
		ContextMapEntropy.write(prepared, to: &writer)
		Issue.record(
			"Compare estimatedCost, selected histograms and written bits independently with native candidates"
		)
	}

	@Test(.disabled("Awaiting context-map translation"))
	func representationAndSerializationMatchPinnedReference() throws {
		let prepared = ContextMapEncoding.prepare([0, 1], numHistograms: 2)
		#expect(prepared.representation == .simple(entryBits: 1))
		#expect(prepared.raw != nil && prepared.moveToFront != nil)
		#expect(prepared.entries == [0, 1])
		var writer = BitWriter()
		ContextMapEncoding.write(prepared, to: &writer)
		#expect(writer.bitsWritten == 5)
		Issue.record(
			"Compare raw, MTF, ties, RLE and coder threshold fixtures including padded bytes"
		)
	}

	@Test(.disabled("Awaiting context-map translation"))
	func productionUsesPreparedContextMaps() throws {
		let prepared = ContextMapEncoding.prepare([0, 1], numHistograms: 2)
		var direct = BitWriter()
		ContextMapEncoding.write(prepared, to: &direct)
		var production = BitWriter()
		EntropyCodeWriter.writeContextMapEntries([0, 1], writer: &production)
		#expect(production.bitsWritten == direct.bitsWritten)
		#expect(production.bytes == direct.bytes)
	}

	@Test(.disabled("Awaiting context-map translation"))
	func inventoryReferencesHaveContextMapProofs() throws {
		let inventory = try DecisionInventoryTests.committed()
		#expect(inventory.parseViolations.isEmpty)
		Issue.record(
			"Require consumed typed native context-map proofs for each settled EW descriptor"
		)
	}
}
