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
	case commandFailed(Int32, String)
	case malformedOutput(String)
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
		let fields = try run(input.arguments, using: harness)
		let decodeSucceeded = try boolean(fields, "decode_succeeded")
		return DecodedContextMap(
			entries: decodeSucceeded ? try byteValues(required(fields, "entries")) : [],
			numHistograms: decodeSucceeded
				? try integer(fields, "num_histograms") : 0,
			decodeSucceeded: decodeSucceeded,
			totalBitsConsumed: try integer(fields, "total_bits_consumed"),
			closeSucceeded: try boolean(fields, "close_succeeded"))
	}

	static func decodeBlockContextMap(
		_ input: NativeBlockContextMapDecodeInput, using harness: URL
	) throws -> DecodedBlockContextMap {
		let fields = try run(input.arguments, using: harness)
		let decodeSucceeded = try boolean(fields, "decode_succeeded")
		return DecodedBlockContextMap(
			dcThresholds0: decodeSucceeded
				? try int32Values(required(fields, "dc0")) : [],
			dcThresholds1: decodeSucceeded
				? try int32Values(required(fields, "dc1")) : [],
			dcThresholds2: decodeSucceeded
				? try int32Values(required(fields, "dc2")) : [],
			qfThresholds: decodeSucceeded
				? try uint32Values(required(fields, "qf_thresholds")) : [],
			numDC: decodeSucceeded ? try integer(fields, "num_dc") : 0,
			numContexts: decodeSucceeded ? try integer(fields, "num_contexts") : 0,
			contextMap: decodeSucceeded
				? try byteValues(required(fields, "context_map")) : [],
			decodeSucceeded: decodeSucceeded,
			totalBitsConsumed: try integer(fields, "total_bits_consumed"),
			closeSucceeded: try boolean(fields, "close_succeeded"))
	}

	private static func run(_ arguments: [String], using harness: URL) throws
		-> [String: String]
	{
		#if os(Linux) || os(macOS)
			let process = Process()
			let output = Pipe()
			let errors = Pipe()
			process.executableURL = harness
			process.arguments = arguments
			process.standardOutput = output
			process.standardError = errors
			try process.run()
			let outputData = output.fileHandleForReading.readDataToEndOfFile()
			process.waitUntilExit()
			let errorData = errors.fileHandleForReading.readDataToEndOfFile()
			guard process.terminationStatus == 0 else {
				let message = String(decoding: errorData, as: UTF8.self)
				throw NativeInteropGateError.commandFailed(
					process.terminationStatus, message)
			}
			let text = String(decoding: outputData, as: UTF8.self)
			var fields: [String: String] = [:]
			for line in text.split(whereSeparator: \.isNewline) {
				let pair = line.split(
					separator: "=", maxSplits: 1,
					omittingEmptySubsequences: false)
				guard pair.count == 2 else {
					throw NativeInteropGateError.malformedOutput(String(line))
				}
				let key = String(pair[0])
				guard fields[key] == nil else {
					throw NativeInteropGateError.malformedOutput(
						"duplicate field: \(key)")
				}
				fields[key] = String(pair[1])
			}
			return fields
		#else
			throw NativeInteropGateError.requiredHarnessMissingOrInvalid
		#endif
	}

	private static func required(_ fields: [String: String], _ key: String) throws -> String {
		guard let value = fields[key] else {
			throw NativeInteropGateError.malformedOutput("missing field: \(key)")
		}
		return value
	}

	private static func integer(
		_ fields: [String: String], _ key: String
	) throws -> Int {
		guard let value = fields[key], let parsed = Int(value)
		else { throw NativeInteropGateError.malformedOutput("invalid integer: \(key)") }
		return parsed
	}

	private static func boolean(_ fields: [String: String], _ key: String) throws -> Bool {
		switch fields[key] {
		case "1": return true
		case "0": return false
		default: throw NativeInteropGateError.malformedOutput("invalid boolean: \(key)")
		}
	}

	private static func values<T: LosslessStringConvertible>(_ value: String) throws -> [T] {
		guard !value.isEmpty else { return [] }
		let parts = value.split(separator: ",")
		let parsed = parts.compactMap { T(String($0)) }
		guard parsed.count == parts.count else {
			throw NativeInteropGateError.malformedOutput("invalid value list")
		}
		return parsed
	}

	private static func byteValues(_ value: String) throws -> [UInt8] {
		let parsed: [Int] = try values(value)
		return try parsed.map {
			guard let byte = UInt8(exactly: $0) else {
				throw NativeInteropGateError.malformedOutput("invalid byte value")
			}
			return byte
		}
	}

	private static func int32Values(_ value: String) throws -> [Int32] {
		let parsed: [Int] = try values(value)
		return try parsed.map {
			guard let threshold = Int32(exactly: $0) else {
				throw NativeInteropGateError.malformedOutput("invalid DC threshold")
			}
			return threshold
		}
	}

	private static func uint32Values(_ value: String) throws -> [UInt32] {
		let parsed: [Int] = try values(value)
		return try parsed.map {
			guard let threshold = UInt32(exactly: $0) else {
				throw NativeInteropGateError.malformedOutput("invalid QF threshold")
			}
			return threshold
		}
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

	#if os(Linux) || os(macOS)
		@Test
		func nativeContextMapDecoderConsumesExactBits() throws {
			let environment = ProcessInfo.processInfo.environment
			let harnessPath = try NativeInteropGate.harnessURL(
				required: environment["JXL_REQUIRE_NATIVE_INTEROP"] == "1",
				path: environment["JXL_HARNESS_PATH"])
			guard let harness = harnessPath else { return }
			var representations: Set<String> = []
			var simpleEntryBits: Set<Int> = []
			var entropyModes: Set<String> = []
			var hasRunLength = false
			for name in Self.contextMapFixtures {
				let fixture = try EntropyReferenceFixture.load(name)
				let fixtureEntries = try fixture.integers(
					fixture.input, "input.context_map.entries"
				).map(UInt8.init)
				let claimedHistograms = Int(
					try fixture.integers(
						fixture.input, "input.context_map.num_histograms")[
							0])
				let entries: [UInt8]
				let numHistograms: Int
				if name == "context_full_256" {
					// The fixture tests endpoint values; a decoder requires all 256 IDs.
					entries = (0...255).map(UInt8.init)
					numHistograms = 256
				} else {
					// DecodeContextMap rejects sparse cluster IDs.
					let canonical = HistogramCluster.reindex(
						symbols: fixtureEntries.map(UInt32.init),
						clusters: [Histogram](
							repeating: Histogram(),
							count: claimedHistograms))
					entries = canonical.contextMap
					numHistograms = canonical.clusters.count
				}
				let prepared = ContextMapEncoding.prepare(
					entries, numHistograms: numHistograms)
				if name == "context_raw_rle" {
					#expect(prepared.representation == .raw)
				}
				if name == "context_mtf_ans" {
					#expect(prepared.representation == .moveToFront)
				}
				let selectedEntropy: EntropyCodeWriter.Prepared?
				switch prepared.representation {
				case .simple(let entryBits):
					representations.insert("simple")
					simpleEntryBits.insert(entryBits)
					selectedEntropy = nil
				case .raw:
					representations.insert("raw")
					selectedEntropy = prepared.raw
				case .moveToFront:
					representations.insert("moveToFront")
					selectedEntropy = prepared.moveToFront
				}
				if let selectedEntropy {
					entropyModes.insert(
						selectedEntropy.usesPrefixCode ? "prefix" : "ans")
					hasRunLength =
						hasRunLength || selectedEntropy.code.lz77 != nil
					if name == "context_raw_rle" {
						#expect(selectedEntropy.usesPrefixCode)
						#expect(selectedEntropy.code.lz77 != nil)
					}
					if name == "context_mtf_ans" {
						#expect(!selectedEntropy.usesPrefixCode)
					}
				}
				var writer = BitWriter()
				ContextMapEncoding.write(prepared, to: &writer)
				let decodeCase = NativeContextMapDecodeCase(
					name: name,
					input: NativeContextMapDecodeInput(
						entryCount: entries.count,
						bitCount: writer.bitsWritten,
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
			#expect(representations == ["simple", "raw", "moveToFront"])
			#expect(simpleEntryBits.contains(0) && simpleEntryBits.contains(1))
			#expect(entropyModes == ["prefix", "ans"])
			#expect(hasRunLength)
		}

		@Test
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
					decoded.dcThresholds0, decoded.dcThresholds1,
					decoded.dcThresholds2,
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
	#endif
}
