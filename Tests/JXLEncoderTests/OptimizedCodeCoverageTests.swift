import Testing

@testable import JXLEncoder

/// Checks the context maps a real transcode transmits against the rule the
/// decoder applies to them.
///
/// `VerifyContextMap` demands every prefix code be *referenced* by the map, not
/// merely in range, and rejects the stream as "Incomplete context map"
/// otherwise. Synthetic histograms would not reproduce whatever the subsampled
/// images do, so these run the codes the encoder actually settles on.
@Suite("Optimized code coverage")
struct OptimizedCodeCoverageTests {
	/// The map `EntropyCodeWriter.writeContextMap` puts on the wire: a
	/// re-clustered code composes with the map it was built from, so the decoder
	/// sees one entry per original context.
	static func transmitted(_ code: EntropyCode) -> [UInt8] {
		if let original = code.originalContextMap {
			return original.map { code.contextMap[Int($0)] }
		}
		return code.contextMap
	}

	static func codes(_ name: String, optimize: Bool) throws -> (
		dc: EntropyCode, ac: EntropyCode
	) {
		let jpeg = try JPEGParser.parse(try JPEGParserTests.fixture(name))
		let transcode = try JPEGTranscode(jpeg)
		var writer = BitWriter()
		return try Encoder.encodeJPEGFrame(
			transcode, optimizeCodes: optimize, writer: &writer)
	}

	/// Reports coverage rather than just asserting, so a failure names the code
	/// and the count instead of only saying "false".
	static func report(_ code: EntropyCode, _ label: String) -> String? {
		let map = transmitted(code)
		let referenced = Set(map.map(Int.init))
		let missing = (0..<code.prefixCodeCount).filter { !referenced.contains($0) }
		guard !missing.isEmpty else { return nil }
		return
			"\(label): \(code.prefixCodeCount) prefix codes, map of \(map.count) "
			+ "entries references \(referenced.count); unreferenced \(missing)"
	}

	/// `writePrefixCode` derives its symbol width from the last used symbol. A
	/// code with no symbols at all makes that `length - 1` underflow, and a code
	/// with exactly one takes the degenerate path. Neither should reach the wire.
	static func shapes(_ code: EntropyCode, _ label: String) -> String {
		let counts = code.prefixCodes.map { prefix in
			prefix.depths.reduce(0) { $0 + ($1 == 0 ? 0 : 1) }
		}
		return "\(label) \(counts)"
	}

	@Test(
		"no transmitted prefix code is empty",
		arguments: ["small_444", "small_422", "small_440", "hopper_420_odd"])
	func noEmptyCodes(name: String) throws {
		let (dc, ac) = try Self.codes(name, optimize: true)
		let detail = Self.shapes(dc, "DC") + "  " + Self.shapes(ac, "AC")
		let empty =
			dc.prefixCodes.contains { $0.depths.allSatisfy { $0 == 0 } }
			|| ac.prefixCodes.contains { $0.depths.allSatisfy { $0 == 0 } }
		#expect(!empty, "\(name): a code with no symbols — \(detail)")
	}

	@Test(
		"subsampled transcodes transmit a covering context map",
		arguments: ["small_422", "small_440", "hopper_420_odd"])
	func subsampledCoverage(name: String) throws {
		let (dc, ac) = try Self.codes(name, optimize: true)
		let problems = [Self.report(dc, "DC"), Self.report(ac, "AC")].compactMap { $0 }
		#expect(problems.isEmpty, "\(problems.joined(separator: "; "))")
	}

	/// The unsubsampled case decodes, so its maps are known good — a control that
	/// tells a real coverage bug apart from a broken check.
	@Test(
		"unsubsampled transcodes transmit a covering context map",
		arguments: ["small_444", "hopper_gray_odd"])
	func unsubsampledCoverage(name: String) throws {
		let (dc, ac) = try Self.codes(name, optimize: true)
		let problems = [Self.report(dc, "DC"), Self.report(ac, "AC")].compactMap { $0 }
		#expect(problems.isEmpty, "\(problems.joined(separator: "; "))")
	}
}
