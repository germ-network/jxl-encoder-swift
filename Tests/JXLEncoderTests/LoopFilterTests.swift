import Testing

@testable import JXLEncoder

@Suite("Loop filter headers")
struct LoopFilterTests {
	@Test(
		"independent filter fields preserve every default-weight wire state", .disabled(),
		arguments: [false, true], [UInt32(0), 1, 2, 3])
	func loopFilterFieldsRoundTrip(gaborish: Bool, epfIterations: UInt32) {
		let filter = FrameAssembly.LoopFilter(
			gaborish: gaborish, epfIterations: epfIterations)
		_ = filter
		Issue.record(
			"Read back both filter fields, conditional custom flags, extensions and sentinel"
		)
	}

	@Test("production pixel headers keep Gaborish off across EPF transitions", .disabled())
	func pixelHeadersKeepGaborishOffAtThresholds() throws {
		Issue.record(
			"Read actual Encoder.encode header fields at all nine threshold neighbors")
	}

	@Test("JPEG headers disable both filters", .disabled())
	func jpegHeadersDisableBothFilters() throws {
		Issue.record(
			"Read actual Encoder.encodeJPEG filter fields for supported JPEG fixtures")
	}

	@Test("concurrent pixel assembly preserves serial filter fields", .disabled())
	func concurrentPixelHeadersMatchSerialFilters() async throws {
		Issue.record(
			"Read actual concurrent and serial headers at the same threshold neighbors")
	}
}
