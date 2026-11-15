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
	@Test(.disabled("Awaiting native table_bits capture and independent contract review."))
	func fixedPrefixEntropySerializationMatchesNativeWire() throws {
		let fixture = try EntropyReferenceFixture.load(
			"context_entropy_prefix_99_fixed_wire")
		let tokenValues = try fixture.integers(
			fixture.expected, "entropy.context_entropy.tokens")
		guard tokenValues.count.isMultiple(of: 3) else {
			throw SemanticDumpError.unimplemented
		}
		let tokens = stride(from: 0, to: tokenValues.count, by: 3).map { index in
			ContextMapEntropy.EncodedToken(
				token: Token(
					context: UInt32(tokenValues[index]),
					value: UInt32(tokenValues[index + 1])),
				isLength: tokenValues[index + 2] != 0)
		}
		let capturedCounts = try fixture.integers(
			fixture.expected, "entropy.context_entropy.histogram_counts")
		var histogram = Histogram()
		for (symbol, count) in capturedCounts.enumerated() {
			histogram.counts[symbol] = UInt32(count)
			histogram.totalCount += Int(count)
		}
		let capturedTables = try fixture.integers(
			fixture.expected, "entropy.context_entropy.tables")
		guard capturedTables.count.isMultiple(of: 2) else {
			throw SemanticDumpError.unimplemented
		}
		let depths = stride(from: 0, to: capturedTables.count, by: 2)
			.map { UInt8(capturedTables[$0]) }
		let tableBits = try fixture.integers(
			fixture.expected, "entropy.context_entropy.table_bits")
		guard tableBits.count == depths.count,
			tableBits.allSatisfy({ (0...Int64(UInt16.max)).contains($0) })
		else { throw SemanticDumpError.unimplemented }
		let prefixCode = PrefixCode(
			depths: depths + [UInt8](repeating: 0, count: 64 - depths.count),
			bits: tableBits.map(UInt16.init)
				+ [UInt16](repeating: 0, count: 64 - tableBits.count))
		let nativeBytes = try fixture.integers(
			fixture.expected, "entropy.context_entropy.bytes"
		).map(UInt8.init)
		let nativeRecord = FixedPrefixNativeWireRecord(
			fixture: "context_entropy_prefix_99_fixed_wire",
			tableBits: tableBits,
			bitCount: Int(
				try fixture.integers(
					fixture.expected, "entropy.context_entropy.bit_count")[0]),
			bytes: nativeBytes)
		let prepared = ContextMapEntropy.Prepared(
			runLength: .init(enabled: false, tokens: tokens),
			contextMap: [0], histograms: [histogram],
			uintConfigurations: [
				HybridUintConfiguration(
					splitExponent: 2, msbInToken: 0, lsbInToken: 1)
			], usesPrefixCode: true, logAlphabetSize: 15,
			prefixCodes: [prefixCode], ansHistograms: [],
			estimatedCost: Int(
				try fixture.integers(
					fixture.expected, "entropy.context_entropy.cost")[0]))
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
