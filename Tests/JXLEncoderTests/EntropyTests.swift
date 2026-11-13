import Foundation
import Testing

@testable import JXLEncoder

@Suite("Hybrid uint coder")
struct UintCoderTests {
	@Test("matches pinned HybridUintConfig (4,2,0)")
	func encodesAgainstReference() throws {
		let fixture = try EntropyReferenceFixture.load("hybrid_uint_4_2_0")
		#expect(try fixture.integers(fixture.input, "input.uint.config") == [4, 2, 0])
		let values = try fixture.integers(fixture.input, "input.uint.values")
		let tokens = try fixture.integers(fixture.expected, "entropy.uint.tokens")
		let bitCounts = try fixture.integers(
			fixture.expected, "entropy.uint.bit_counts")
		let bits = try fixture.integers(fixture.expected, "entropy.uint.bits")
		#expect(values.count == tokens.count && values.count == bitCounts.count)
		#expect(values.count == bits.count)
		for index in values.indices {
			let actual = UintCoder.encode(UInt32(values[index]))
			#expect(actual.token == UInt32(tokens[index]))
			#expect(actual.bitCount == UInt32(bitCounts[index]))
			#expect(actual.bits == UInt32(bits[index]))
		}
	}

	/// The extra bits plus the token must reconstruct the value, or the decoder
	/// cannot recover it.
	@Test("token and extra bits round-trip for a wide range")
	func roundTrips() {
		for value in stride(from: UInt32(0), to: 200_000, by: 137) {
			let (token, bitCount, bits) = UintCoder.encode(value)
			let reconstructed: UInt32
			if token < 16 {
				reconstructed = token
			} else {
				let n = (token >> 2) &- 2
				let m = (token & 3) << n
				reconstructed = (1 << (n + 2)) | m | bits
			}
			#expect(reconstructed == value, "value \(value) did not round-trip")
			#expect(bits >> bitCount == 0, "extra bits exceed their width")
		}
	}
}

@Suite("Signed packing")
struct PackSignedTests {
	@Test("matches pinned libjxl PackSigned")
	func packsAgainstReference() throws {
		let fixture = try EntropyReferenceFixture.load("pack_signed_full_reference")
		let values = try fixture.integers(fixture.input, "input.signed.values")
		let expected = try fixture.integers(
			fixture.expected, "entropy.signed.values")
		#expect(values.count == expected.count)
		for index in values.indices {
			#expect(packSigned(Int32(values[index])) == UInt32(expected[index]))
		}
	}

	@Test("small magnitudes of either sign stay small")
	func monotonic() {
		for magnitude in Int32(1)...50 {
			#expect(packSigned(magnitude) == UInt32(magnitude) * 2)
			#expect(packSigned(-magnitude) == UInt32(magnitude) * 2 - 1)
		}
	}
}

@Suite("AC context model")
struct ACContextTests {
	@Test("context map sizes match the model")
	func sizes() {
		#expect(ACContext.totalCount == 1980)
		#expect(StaticEntropyCodes.acContextMap.count == ACContext.totalCount)
		#expect(StaticEntropyCodes.dcContextMap.count == 45)
		#expect(StaticEntropyCodes.acPrefixCodes.count == 8)
		#expect(StaticEntropyCodes.dcPrefixCodes.count == 8)
	}

	/// Compared over the whole domain rather than at sample points: hand-derived
	/// expectations for these functions are easy to get wrong, and a spot check
	/// that happens to avoid the wrong case proves nothing.
	@Test("context functions match libjxl-tiny over their entire domain")
	func exhaustiveContexts() throws {
		let reference = try UInt32Fixture(name: "ac_context")
		var index = 4  // skip the domain header

		for nonZeros in 0..<256 {
			for blockContext in 0..<4 {
				let expected = Int(reference.values[index])
				index += 1
				#expect(
					ACContext.nonZeroContext(
						nonZeros: nonZeros, blockContext: blockContext)
						== expected,
					"nonZeroContext(\(nonZeros), \(blockContext))")
			}
		}

		for nonzerosLeft in 0..<64 {
			for k in 0..<64 {
				for previous in 0..<2 {
					let expected = Int(reference.values[index])
					index += 1
					#expect(
						ACContext.zeroDensityContext(
							nonzerosLeft: nonzerosLeft, k: k,
							coveredBlocks: 1, log2CoveredBlocks: 0,
							previous: previous) == expected,
						"zeroDensityContext(\(nonzerosLeft), \(k), \(previous))"
					)
				}
			}
		}

		for channel in 0..<3 {
			for code in 0..<ACContext.numAcStrategyCodes {
				let expected = Int(reference.values[index])
				index += 1
				#expect(
					ACContext.blockContext(
						channel: channel, acStrategyCode: code) == expected,
					"blockContext(\(channel), \(code))")
			}
		}
		#expect(index == reference.values.count)
	}

	@Test("every context index maps into a valid prefix code")
	func contextMapInRange() {
		for entry in StaticEntropyCodes.acContextMap {
			#expect(Int(entry) < StaticEntropyCodes.acPrefixCodes.count)
		}
		for entry in StaticEntropyCodes.dcContextMap {
			#expect(Int(entry) < StaticEntropyCodes.dcPrefixCodes.count)
		}
	}

	/// The tighter 458 bound holds only under the encoder's invariant that
	/// non-zeros remaining plus scan position stays below 64 — the tokenizer
	/// decrements `nonzeros` as `k` advances, so it always does. Without that
	/// constraint the model reaches 474, which is why the distinction matters
	/// for sizing the context map.
	@Test("zero-density contexts respect both documented bounds")
	func zeroDensityInRange() {
		var maxUnderInvariant = 0
		var maxOverall = 0
		for nonzerosLeft in 1...63 {
			for k in 1...63 {
				for previous in 0...1 {
					let ctx = ACContext.zeroDensityContext(
						nonzerosLeft: nonzerosLeft, k: k,
						coveredBlocks: 1, log2CoveredBlocks: 0,
						previous: previous)
					#expect(ctx >= 0)
					maxOverall = max(maxOverall, ctx)
					if nonzerosLeft + k < 64 {
						maxUnderInvariant = max(maxUnderInvariant, ctx)
					}
				}
			}
		}
		#expect(maxUnderInvariant == ACContext.zeroDensityCount - 1)
		#expect(maxOverall == ACContext.zeroDensityLimit - 1)
	}
}

@Suite("Token writer")
struct TokenWriterTests {
	/// Bit counts and bytes come from the reference's own `WriteToken`.
	@Test(
		"emits the same bits as libjxl-tiny",
		arguments: [
			(UInt32(0), UInt32(0), 4, [UInt8(0x00)]),
			(0, 1, 4, [0x08]),
			(0, 63, 9, [0xEF, 0x01]),
			(5, 7, 8, [0x3F]),
			(100, 300, 21, [0xFF, 0x03, 0x16]),
			(148, 1, 4, [0x08]),
			(700, 12, 12, [0xFF, 0x0A]),
			(1979, 65535, 28, [0xFF, 0xFF, 0xFF, 0x0F]),
		])
	func writesToken(context: UInt32, value: UInt32, bitCount: Int, bytes: [UInt8]) {
		var writer = BitWriter()
		writer.write(token: Token(context: context, value: value), code: .staticAC)
		#expect(writer.bitsWritten == bitCount)
		writer.zeroPadToByte()
		#expect(writer.take() == bytes)
	}
}
