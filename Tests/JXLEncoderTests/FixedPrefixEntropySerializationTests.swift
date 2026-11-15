import Testing

@testable import JXLEncoder

private struct FixedPrefixNativeWireRecord: Sendable {
	let fixture: String
	let tableBits: [Int64]
	let bitCount: Int
	let bytes: [UInt8]
}

@Suite("Fixed prefix entropy serialization")
struct FixedPrefixEntropySerializationTests {
	@Test
	func fixedPrefixEntropySerializationMatchesNativeWire() throws {
		let fixtureName = "context_entropy_prefix_99_fixed_wire"
		let fixture = try EntropyReferenceFixture.load(
			fixtureName)
		let histogramCount = try fixture.integers(
			fixture.expected, "entropy.context_entropy.histogram_count")
		let tokenValues = try fixture.integers(
			fixture.expected, "entropy.context_entropy.tokens")
		let capturedCounts = try fixture.integers(
			fixture.expected, "entropy.context_entropy.histogram_counts")
		let capturedTables = try fixture.integers(
			fixture.expected, "entropy.context_entropy.tables")
		let histogramLengths = try fixture.integers(
			fixture.expected, "entropy.context_entropy.histogram_lengths")
		let tableBits = try fixture.integers(
			fixture.expected, "entropy.context_entropy.table_bits")
		let capturedContextMap = try fixture.integers(
			fixture.expected, "entropy.context_entropy.context_map")
		let capturedConfigurations = try fixture.integers(
			fixture.expected, "entropy.context_entropy.uint_configs")
		let runLengthEnabled = try fixture.integers(
			fixture.expected, "entropy.context_entropy.rle_enabled")
		let usesPrefixCode = try fixture.integers(
			fixture.expected, "entropy.context_entropy.use_prefix_code")
		let logAlphabetSize = try fixture.integers(
			fixture.expected, "entropy.context_entropy.log_alpha_size")
		let bitCounts = try fixture.integers(
			fixture.expected, "entropy.context_entropy.bit_count")
		let costs = try fixture.integers(
			fixture.expected, "entropy.context_entropy.cost")
		guard histogramCount == [1], tokenValues.count.isMultiple(of: 3),
			!tokenValues.isEmpty, capturedCounts.count <= 256,
			capturedTables.count.isMultiple(of: 2),
			histogramLengths == [Int64(capturedCounts.count)],
			tableBits.count == capturedCounts.count,
			capturedConfigurations == [2, 0, 1],
			runLengthEnabled.count == 1, usesPrefixCode.count == 1,
			logAlphabetSize.count == 1, bitCounts == [301],
			costs.count == 1, costs[0] >= 0
		else {
			throw SemanticDumpError.unsupportedEntropyFixture(fixtureName)
		}
		let depthValues = stride(from: 0, to: capturedTables.count, by: 2)
			.map { capturedTables[$0] }
		guard depthValues.count == capturedCounts.count,
			depthValues.allSatisfy({ (0...Int64(UInt8.max)).contains($0) }),
			depthValues.count <= 64,
			tableBits.allSatisfy({ (0...Int64(UInt16.max)).contains($0) })
		else {
			throw SemanticDumpError.unsupportedEntropyFixture(fixtureName)
		}
		let tokens = stride(from: 0, to: tokenValues.count, by: 3).map { index in
			ContextMapEntropy.EncodedToken(
				token: Token(
					context: UInt32(tokenValues[index]),
					value: UInt32(tokenValues[index + 1])),
				isLength: tokenValues[index + 2] != 0)
		}
		var histogram = Histogram()
		for (symbol, count) in capturedCounts.enumerated() {
			histogram.counts[symbol] = UInt32(count)
			histogram.totalCount += Int(count)
		}
		let depths = depthValues.map(UInt8.init)
		let prefixCode = PrefixCode(
			depths: depths + [UInt8](repeating: 0, count: 64 - depths.count),
			bits: tableBits.map(UInt16.init)
				+ [UInt16](repeating: 0, count: 64 - tableBits.count))
		let nativeByteValues = try fixture.integers(
			fixture.expected, "entropy.context_entropy.bytes"
		)
		guard nativeByteValues.count == (Int(bitCounts[0]) + 7) / 8,
			nativeByteValues.allSatisfy({ (0...Int64(UInt8.max)).contains($0) })
		else {
			throw SemanticDumpError.unsupportedEntropyFixture(fixtureName)
		}
		let nativeBytes = nativeByteValues.map(UInt8.init)
		let nativeRecord = FixedPrefixNativeWireRecord(
			fixture: fixtureName, tableBits: tableBits,
			bitCount: Int(bitCounts[0]), bytes: nativeBytes)
		let uintConfigurations = stride(
			from: 0, to: capturedConfigurations.count, by: 3
		).map { index in
			HybridUintConfiguration(
				splitExponent: Int(capturedConfigurations[index]),
				msbInToken: Int(capturedConfigurations[index + 1]),
				lsbInToken: Int(capturedConfigurations[index + 2]))
		}
		#expect(runLengthEnabled == [0])
		#expect(capturedContextMap == [0])
		#expect(usesPrefixCode == [1])
		#expect(logAlphabetSize == [15])
		let prepared = ContextMapEntropy.Prepared(
			runLength: .init(enabled: runLengthEnabled[0] == 1, tokens: tokens),
			contextMap: capturedContextMap.map(UInt8.init),
			histograms: [histogram], uintConfigurations: uintConfigurations,
			usesPrefixCode: usesPrefixCode[0] == 1,
			logAlphabetSize: Int(logAlphabetSize[0]),
			prefixCodes: [prefixCode], ansHistograms: [],
			estimatedCost: Int(costs[0]))
		var writer = BitWriter()
		ContextMapEntropy.write(prepared, to: &writer)
		#expect(nativeRecord.fixture == "context_entropy_prefix_99_fixed_wire")
		#expect(nativeRecord.tableBits.count == depths.count)
		#expect(nativeRecord.bitCount == 301)
		#expect(nativeRecord.bytes.count == 38)
		#expect(writer.bitsWritten == nativeRecord.bitCount)
		#expect(writer.bytes == nativeRecord.bytes)
	}
}
