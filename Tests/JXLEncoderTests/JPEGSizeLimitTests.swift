import Testing

@testable import JXLEncoder

/// Coefficients are held in full, so the frame header decides the allocation
/// before any entropy data is read: 256 bytes per block against as little as
/// two bits to code one. A flat image legitimately codes that densely, so the
/// ratio test in `decodeScan` cannot separate it from a header that simply
/// lies. The byte budget is what bounds it — the same conclusion libjpeg
/// reaches with `max_memory_to_use`, which it answers by spilling its
/// coefficient arrays to a backing store rather than refusing them.
@Suite("JPEG size limits")
struct JPEGSizeLimitTests {
	/// A structurally valid baseline JPEG claiming `width` × `height`, followed
	/// by `entropyBytes` of filler. Everything before the scan is real, so the
	/// parser reaches the frame header the same way it would on a genuine file.
	static func crafted(width: Int, height: Int, entropyBytes: Int) -> [UInt8] {
		var data: [UInt8] = [0xFF, 0xD8]
		data += [0xFF, 0xDB, 0x00, 0x43, 0x00] + [UInt8](repeating: 1, count: 64)
		data += [
			0xFF, 0xC0, 0x00, 0x11, 0x08,
			UInt8(height >> 8), UInt8(height & 0xFF),
			UInt8(width >> 8), UInt8(width & 0xFF),
			3, 1, 0x11, 0, 2, 0x11, 0, 3, 0x11, 0,
		]
		// One code of length 1 per table, so the tables are well formed.
		for tableClass: UInt8 in [0x00, 0x10] {
			data +=
				[0xFF, 0xC4, 0x00, 0x14, tableClass, 1]
				+ [UInt8](repeating: 0, count: 15) + [0]
		}
		data += [0xFF, 0xDA, 0x00, 0x0C, 3, 1, 0x00, 2, 0x00, 3, 0x00, 0, 63, 0]
		data += [UInt8](repeating: 0x55, count: entropyBytes)
		return data
	}

	/// Bytes a 4:4:4 frame of these dimensions needs, which is what the budget
	/// is measured against.
	static func coefficientBytes(width: Int, height: Int) -> Int {
		let blocks = ((width + 7) / 8) * ((height + 7) / 8)
		return blocks * 3 * 64 * MemoryLayout<Int32>.size
	}

	/// The shape that motivated the budget: a 1 kB file whose header asks for
	/// tens of gigabytes of coefficients.
	@Test("a header claiming 65535x65535 is refused")
	func maximalHeaderRefused() {
		let bomb = Self.crafted(width: 65535, height: 65535, entropyBytes: 1024)
		#expect(throws: JPEGParseError.self) { try JPEGParser.parse(bomb) }
	}

	/// This one satisfies the two-bits-per-block rule and used to allocate
	/// ~192 MB before the entropy data turned out to be filler. What the budget
	/// changes is that the allocation never happens.
	@Test("a claim within the entropy rule is still refused over budget")
	func amplificationRefused() {
		let bomb = Self.crafted(width: 4000, height: 4000, entropyBytes: 1 << 20)
		let required = Self.coefficientBytes(width: 4000, height: 4000)
		#expect(required > 64 << 20, "only interesting if the claim is large")
		#expect(
			throws: JPEGParseError.coefficientBudgetExceeded(
				required: required, budget: 64 << 20)
		) {
			try JPEGParser.parse(bomb, maxCoefficientBytes: 64 << 20)
		}
	}

	/// The budget is the caller's to choose, and it is judged from the header
	/// rather than the file's length. A byte either side of it decides; within
	/// budget the file goes on to fail on its filler instead.
	///
	/// The filler has to clear the two-bits-per-block rule, which is checked
	/// first — otherwise this measures that guard instead of the budget.
	@Test("the budget is a parameter", arguments: [0, -1])
	func budgetIsParameter(offset: Int) {
		let data = Self.crafted(width: 1000, height: 1000, entropyBytes: 1 << 16)
		let required = Self.coefficientBytes(width: 1000, height: 1000)
		let budget = required + offset

		var thrown: JPEGParseError?
		do {
			_ = try JPEGParser.parse(data, maxCoefficientBytes: budget)
		} catch let error as JPEGParseError {
			thrown = error
		} catch {}

		let overBudget = JPEGParseError.coefficientBudgetExceeded(
			required: required, budget: budget)
		#expect((thrown == overBudget) == (offset < 0))
	}

	/// Subsampling cuts what the same dimensions cost, which is why the budget
	/// counts bytes and not pixels. (4:2:2 and 4:1:1 come out equal at this
	/// size — MCU padding rounds the narrower chroma back up.)
	@Test(
		"subsampled frames cost less than 4:4:4",
		arguments: ["small_422", "small_440", "small_411"])
	func subsamplingCostsLess(name: String) throws {
		let cost = { (name: String) in
			try JPEGParser.parse(try JPEGParserTests.fixture(name))
				.components.reduce(0) { $0 + $1.coefficients.count }
		}
		#expect(try cost("small_444") > cost(name))
	}

	/// Real files must still parse, so the default cannot be so tight that it
	/// rejects ordinary photographs.
	@Test(
		"fixtures parse under the default budget",
		arguments: ["small_444", "hopper_420_odd", "hopper_420_restart"])
	func fixturesUnaffected(name: String) throws {
		let jpeg = try JPEGParserTests.fixture(name)
		#expect(throws: Never.self) { try JPEGParser.parse(jpeg) }
	}
}
