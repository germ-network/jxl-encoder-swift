import Foundation
import Testing

@testable import JXLEncoder

struct SharpnessProofCase: Sendable {
	let fixture: String
	let widthInBlocks: Int
	let heightInBlocks: Int
	let sharpness: Int64
	let decision: String

	var reference: String {
		"Tests/JXLEncoderTests/Fixtures/semantic/\(fixture).sem#\(category)"
	}

	var category: String { "epf_sharpness" }
	var consumer: String {
		decision == "DG-08" ? "selectedSharpnessTokens" : "jpegSharpnessMatchesReference"
	}

	func proves(_ candidate: String, knownIssues: Set<String> = []) -> Bool {
		guard candidate == reference, knownIssues.isEmpty,
			let dump = try? SemanticDump(fixture: fixture),
			case .integers(let dimensions)? = dump.fields["\(category).dimensions"],
			case .integers(let values)? = dump.fields["\(category).values"]
		else { return false }
		return dimensions == [Int64(widthInBlocks), Int64(heightInBlocks)]
			&& values.count == widthInBlocks * heightInBlocks
			&& values.allSatisfy { $0 == sharpness }
	}

	static let all: [Self] = [
		.init(
			fixture: "sharpness_pixel_edge", widthInBlocks: 4, heightInBlocks: 4,
			sharpness: 4, decision: "DG-08"),
		.init(
			fixture: "sharpness_jpeg_444", widthInBlocks: 5, heightInBlocks: 3,
			sharpness: 0, decision: "DG-12"),
		.init(
			fixture: "sharpness_jpeg_422", widthInBlocks: 6, heightInBlocks: 3,
			sharpness: 0, decision: "DG-12"),
		.init(
			fixture: "sharpness_jpeg_440", widthInBlocks: 5, heightInBlocks: 4,
			sharpness: 0, decision: "DG-12"),
		.init(
			fixture: "sharpness_jpeg_420_odd", widthInBlocks: 14, heightInBlocks: 10,
			sharpness: 0, decision: "DG-12"),
		.init(
			fixture: "sharpness_jpeg_gray_odd", widthInBlocks: 13, heightInBlocks: 9,
			sharpness: 0, decision: "DG-12"),
	]
}

@Suite("DC group sharpness")
struct DCGroupSharpnessTests {
	static func dump(_ fixture: String) throws -> SemanticDump {
		try SemanticDump(fixture: fixture)
	}

	static func decodedSharpness(_ dump: SemanticDump) throws -> (
		dimensions: [Int64], values: [Int64]
	) {
		guard case .integers(let dimensions)? = dump.fields["epf_sharpness.dimensions"],
			case .integers(let values)? = dump.fields["epf_sharpness.values"]
		else {
			throw SemanticDumpError.malformedLine(
				line: 0, reason: "missing sharpness fields")
		}
		return (dimensions, values)
	}

	@Test("metadata emits the selected sharpness on every full-grid block")
	func selectedSharpnessTokens() throws {
		func tokens(_ sharpness: UInt8?) -> [Token] {
			let data = DCGroupData(
				widthInBlocks: 3, heightInBlocks: 2, epfSharpness: sharpness ?? 4)
			var section = SectionWriter(mode: .staging(.staticDC))
			DCGroupEncoder.writeACMetadataTokens(data: data, writer: &section)
			return section.staged.compactMap { record in
				guard case .token(let context, let value) = record else {
					return nil
				}
				return Token(context: context, value: value)
			}
		}
		let baseline = tokens(nil)
		let suffixCount = 3 * 2
		let prefixCount = baseline.count - suffixCount
		#expect(tokens(4) == baseline)
		for (sharpness, emitted) in [(0, tokens(0)), (4, tokens(4)), (7, tokens(7))] {
			#expect(emitted.count == baseline.count)
			#expect(
				Array(emitted.prefix(prefixCount))
					== Array(baseline.prefix(prefixCount)))
			#expect(
				emitted.suffix(suffixCount).allSatisfy {
					$0.context == 0 && $0.value == packSigned(Int32(sharpness))
				})
		}
		func rawBits(_ sharpness: UInt8) -> [String] {
			var section = SectionWriter(mode: .staging(.staticDC))
			DCGroupEncoder.write(
				data: DCGroupData(
					widthInBlocks: 3, heightInBlocks: 2, epfSharpness: sharpness
				),
				writer: &section)
			return section.staged.compactMap { record in
				guard case .rawBits(let value, let count) = record else {
					return nil
				}
				return "\(count):\(value)"
			}
		}
		#expect(rawBits(0) == rawBits(4) && rawBits(4) == rawBits(7))
		let pixel = try Self.decodedSharpness(Self.dump("sharpness_pixel_edge"))
		#expect(pixel.dimensions == [4, 4])
		var pixelSection = SectionWriter(mode: .staging(.staticDC))
		DCGroupEncoder.writeACMetadataTokens(
			data: DCGroupData(widthInBlocks: 4, heightInBlocks: 4),
			writer: &pixelSection)
		let pixelTokens = pixelSection.staged.compactMap { record -> Token? in
			guard case .token(let context, let value) = record else { return nil }
			return Token(context: context, value: value)
		}
		#expect(
			pixel.values.map { Int64(packSigned(Int32($0))) }
				== Array(pixelTokens.suffix(16)).map { Int64($0.value) })
		#expect(SharpnessProofCase.all[0].proves(SharpnessProofCase.all[0].reference))
	}

	@Test("JPEG metadata matches pinned native sharpness across sampling and grayscale")
	func jpegSharpnessMatchesReference() throws {
		for proof in SharpnessProofCase.all {
			#expect(proof.proves(proof.reference))
			let reference = try Self.decodedSharpness(Self.dump(proof.fixture))
			#expect(
				reference.dimensions == [
					Int64(proof.widthInBlocks), Int64(proof.heightInBlocks),
				])
			#expect(
				reference.values.count == proof.widthInBlocks * proof.heightInBlocks
			)
			#expect(reference.values.allSatisfy { $0 == proof.sharpness })
		}
	}

	@Test(
		"native decoding observes actual JPEG sharpness in both coding modes",
		.enabled(if: ProcessInfo.processInfo.environment["JXL_SHARPNESS_HARNESS"] != nil))
	func actualJPEGSharpnessCrossCheck() throws {
		let harness = try #require(
			ProcessInfo.processInfo.environment["JXL_SHARPNESS_HARNESS"])
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent(
				"jxl-sharpness-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(
			at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let entries = [
			("sharpness_jpeg_444", "small_444"), ("sharpness_jpeg_422", "small_422"),
			("sharpness_jpeg_440", "small_440"),
			("sharpness_jpeg_420_odd", "hopper_420_odd"),
			("sharpness_jpeg_gray_odd", "hopper_gray_odd"),
		]
		for (name, jpeg) in entries {
			let transcode = try JPEGTranscode(
				JPEGParser.parse(JPEGParserTests.fixture(jpeg)))
			let proof = try Self.decodedSharpness(Self.dump(name))
			for optimizeCodes in [false, true] {
				let path = directory.appendingPathComponent(
					"\(name)-\(optimizeCodes).jxl")
				try Data(
					Encoder.encodeJPEG(transcode, optimizeCodes: optimizeCodes)
				).write(to: path)
				let process = Process()
				process.executableURL = URL(fileURLWithPath: harness)
				process.arguments = ["dump", path.path, "epf_sharpness"]
				let output = Pipe()
				process.standardOutput = output
				try process.run()
				let outputData = output.fileHandleForReading.readDataToEndOfFile()
				process.waitUntilExit()
				#expect(process.terminationStatus == 0)
				let decodedText = try #require(
					String(data: outputData, encoding: .utf8))
				let decoded = try SemanticDump(parsing: decodedText)
				#expect(
					try Self.decodedSharpness(decoded).dimensions
						== proof.dimensions)
				#expect(try Self.decodedSharpness(decoded).values == proof.values)
			}
		}
	}

	@Test("sharpness fixture proofs require consumed exact comparisons")
	func sharpnessProofReferences() throws {
		#expect(
			SharpnessProofCase.all.map(\.reference).count
				== SharpnessProofCase.all.count)
		for proof in SharpnessProofCase.all {
			#expect(proof.proves(proof.reference))
			#expect(!proof.proves(proof.reference + "-other"))
			#expect(!proof.proves(proof.reference, knownIssues: ["GER-3386"]))
			#expect(["DG-08", "DG-12"].contains(proof.decision))
			#expect(
				["selectedSharpnessTokens", "jpegSharpnessMatchesReference"]
					.contains(
						proof.consumer))
		}
	}
}
