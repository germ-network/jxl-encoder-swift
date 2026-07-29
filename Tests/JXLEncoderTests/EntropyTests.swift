import Testing

@testable import JXLEncoder

/// Expected values are printed by `Reference/tools/gentokens.cc`, which links
/// libjxl-tiny and calls its own `UintCoder`, `PackSigned`, context functions
/// and `WriteToken`. These pin the port against the reference implementation
/// rather than against a reading of the spec.
@Suite("Hybrid uint coder")
struct UintCoderTests {
	@Test(
		"splits values as libjxl-tiny does",
		arguments: [
			(UInt32(0), UInt32(0), UInt32(0), UInt32(0)),
			(1, 1, 0, 0),
			(15, 15, 0, 0),
			(16, 16, 2, 0),
			(17, 16, 2, 1),
			(20, 17, 2, 0),
			(24, 18, 2, 0),
			(28, 19, 2, 0),
			(32, 20, 3, 0),
			(63, 23, 3, 7),
			(64, 24, 4, 0),
			(255, 31, 5, 31),
			(256, 32, 6, 0),
			(1000, 39, 7, 104),
			(65535, 63, 13, 8191),
			(65536, 64, 14, 0),
			(1_048_576, 80, 18, 0),
		])
	func encodes(value: UInt32, token: UInt32, bitCount: UInt32, bits: UInt32) {
		let result = UintCoder.encode(value)
		#expect(result.token == token)
		#expect(result.bitCount == bitCount)
		#expect(result.bits == bits)
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
	@Test(
		"matches libjxl-tiny",
		arguments: [
			(Int32(0), UInt32(0)), (1, 2), (-1, 1), (2, 4), (-2, 3),
			(100, 200), (-100, 199), (32767, 65534), (-32768, 65535),
			(1_048_576, 2_097_152), (-1_048_576, 2_097_151),
		])
	func packs(value: Int32, expected: UInt32) {
		#expect(packSigned(value) == expected)
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
		#expect(ACContext.numACContexts == 1980)
		#expect(StaticEntropyCodes.acContextMap.count == ACContext.numACContexts)
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
		#expect(maxUnderInvariant == ACContext.zeroDensityContextCount - 1)
		#expect(maxOverall == ACContext.zeroDensityContextLimit - 1)
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
