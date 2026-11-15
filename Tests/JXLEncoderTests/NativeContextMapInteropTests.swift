import Foundation
import Testing

@testable import JXLEncoder

struct NativeContextMapDecodeInput: Sendable {
	let entryCount: Int
	let bitCount: Int
	let bytes: [UInt8]

	var arguments: [String] {
		["decode-context-map", String(entryCount), String(bitCount), Self.hex(bytes)]
	}

	private static func hex(_ bytes: [UInt8]) -> String {
		bytes.map { String(format: "%02x", $0) }.joined()
	}
}

struct NativeBlockContextMapDecodeInput: Sendable {
	let bitCount: Int
	let bytes: [UInt8]

	var arguments: [String] {
		[
			"decode-block-context-map", String(bitCount),
			bytes.map {
				String(format: "%02x", $0)
			}.joined(),
		]
	}
}

struct DecodedContextMap: Equatable, Sendable {
	let entries: [UInt8]
	let numHistograms: Int
	let decodeSucceeded: Bool
	let totalBitsConsumed: Int
	let closeSucceeded: Bool
}

struct DecodedBlockContextMap: Equatable, Sendable {
	let dcThresholds0: [Int32]
	let dcThresholds1: [Int32]
	let dcThresholds2: [Int32]
	let qfThresholds: [UInt32]
	let numDC: Int
	let numContexts: Int
	let contextMap: [UInt8]
	let decodeSucceeded: Bool
	let totalBitsConsumed: Int
	let closeSucceeded: Bool
}

struct NativeContextMapDecodeCase: Sendable {
	let name: String
	let input: NativeContextMapDecodeInput
	let expectedEntries: [UInt8]
	let expectedNumHistograms: Int
}

struct NativeBlockContextMapDecodeCase: Sendable {
	let input: NativeBlockContextMapDecodeInput
	let expectedDCThresholds: [[Int32]]
	let expectedQFThresholds: [UInt32]
	let expectedNumDC: Int
	let expectedNumContexts: Int
	let expectedContextMap: [UInt8]
}

enum NativeInteropGateError: Error, Equatable {
	case requiredHarnessMissingOrInvalid
	case decoderCommandsNotImplemented
}

enum NativeInteropGate {
	static func harnessURL(
		required: Bool, path: String?, fileManager: FileManager = .default
	) throws -> URL? {
		guard let path, !path.isEmpty,
			fileManager.isExecutableFile(atPath: path)
		else {
			if required { throw NativeInteropGateError.requiredHarnessMissingOrInvalid }
			return nil
		}
		return URL(fileURLWithPath: path)
	}
}

private enum NativeDecoderHarness {
	static func decodeContextMap(
		_ input: NativeContextMapDecodeInput, using harness: URL
	) throws -> DecodedContextMap {
		_ = (input, harness)
		throw NativeInteropGateError.decoderCommandsNotImplemented
	}

	static func decodeBlockContextMap(
		_ input: NativeBlockContextMapDecodeInput, using harness: URL
	) throws -> DecodedBlockContextMap {
		_ = (input, harness)
		throw NativeInteropGateError.decoderCommandsNotImplemented
	}
}

@Suite("Native context-map decoder interop")
struct NativeContextMapInteropTests {
	@Test
	func requiredInteropPathFailsClosed() throws {
		#expect(throws: NativeInteropGateError.requiredHarnessMissingOrInvalid) {
			try NativeInteropGate.harnessURL(required: true, path: nil)
		}
		#expect(throws: NativeInteropGateError.requiredHarnessMissingOrInvalid) {
			try NativeInteropGate.harnessURL(
				required: true, path: "/missing/jxl-harness")
		}
		let optionalHarness = try NativeInteropGate.harnessURL(
			required: false, path: nil)
		#expect(optionalHarness == nil)
	}

	@Test(.disabled("Awaiting native decoder commands and the required host interop gate."))
	func nativeContextMapDecoderConsumesExactBits() throws {
		let environment = ProcessInfo.processInfo.environment
		let harnessPath = try NativeInteropGate.harnessURL(
			required: environment["JXL_REQUIRE_NATIVE_INTEROP"] == "1",
			path: environment["JXL_HARNESS_PATH"])
		guard let harness = harnessPath else { return }
		for name in Self.contextMapFixtures {
			let fixture = try EntropyReferenceFixture.load(name)
			let entries = try fixture.integers(
				fixture.input, "input.context_map.entries"
			).map(UInt8.init)
			let claimedHistograms = Int(
				try fixture.integers(
					fixture.input, "input.context_map.num_histograms")[0])
			let prepared = ContextMapEncoding.prepare(
				entries, numHistograms: claimedHistograms)
			var writer = BitWriter()
			ContextMapEncoding.write(prepared, to: &writer)
			let decodeCase = NativeContextMapDecodeCase(
				name: name,
				input: NativeContextMapDecodeInput(
					entryCount: entries.count, bitCount: writer.bitsWritten,
					bytes: writer.bytes),
				expectedEntries: entries,
				expectedNumHistograms: Int(entries.max() ?? 0) + 1)
			let decoded = try NativeDecoderHarness.decodeContextMap(
				decodeCase.input, using: harness)
			#expect(decoded.decodeSucceeded, Comment(rawValue: decodeCase.name))
			#expect(
				decoded.entries == decodeCase.expectedEntries,
				Comment(rawValue: decodeCase.name))
			#expect(
				decoded.numHistograms == decodeCase.expectedNumHistograms,
				Comment(rawValue: decodeCase.name))
			#expect(
				decoded.totalBitsConsumed == decodeCase.input.bitCount,
				Comment(rawValue: decodeCase.name))
			#expect(decoded.closeSucceeded, Comment(rawValue: decodeCase.name))
		}
	}

	@Test(.disabled("Awaiting native decoder commands and the required host interop gate."))
	func nativeBlockContextMapDecoderConsumesExactBits() throws {
		var quantCounts = [Int](repeating: 0, count: 256)
		for quant in 0..<250 { quantCounts[quant] = 200 }
		let model = PixelBlockEntropyModel.compute(
			quantCounts: quantCounts, params: try DistanceParams(distance: 1))
		var writer = BitWriter()
		JPEGBlockContextMap.write(model, writer: &writer)
		let decodeCase = NativeBlockContextMapDecodeCase(
			input: NativeBlockContextMapDecodeInput(
				bitCount: writer.bitsWritten, bytes: writer.bytes),
			expectedDCThresholds: [[], [], []],
			expectedQFThresholds: model.qfThresholds,
			expectedNumDC: model.numDCContexts,
			expectedNumContexts: model.numContexts,
			expectedContextMap: model.contextMap)
		let environment = ProcessInfo.processInfo.environment
		let harnessPath = try NativeInteropGate.harnessURL(
			required: environment["JXL_REQUIRE_NATIVE_INTEROP"] == "1",
			path: environment["JXL_HARNESS_PATH"])
		guard let harness = harnessPath else { return }
		let decoded = try NativeDecoderHarness.decodeBlockContextMap(
			decodeCase.input, using: harness)
		#expect(decoded.decodeSucceeded)
		#expect(
			[
				decoded.dcThresholds0, decoded.dcThresholds1, decoded.dcThresholds2,
			] == decodeCase.expectedDCThresholds)
		#expect(decoded.qfThresholds == decodeCase.expectedQFThresholds)
		#expect(decoded.numDC == decodeCase.expectedNumDC)
		#expect(decoded.numContexts == decodeCase.expectedNumContexts)
		#expect(decoded.contextMap == decodeCase.expectedContextMap)
		#expect(decoded.totalBitsConsumed == decodeCase.input.bitCount)
		#expect(decoded.closeSucceeded)
	}

	private static let contextMapFixtures = [
		"context_single_histogram", "context_simple_two_histograms",
		"context_full_256", "context_tie_raw_mtf", "context_mtf_ans",
		"context_raw_ans", "context_prefix_99", "context_ans_100",
		"context_raw_rle",
	]
}
