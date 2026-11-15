import Foundation
import Testing

@testable import JXLEncoder

struct SharpnessProofCase: Sendable {
	enum Consumer: Hashable, Sendable {
		case selectedSharpnessTokens
		case jpegSharpnessMatchesReference
		case actualJPEGSharpnessCrossCheck
	}

	let fixture: String
	let jpegInput: String?
	let sourceWidth: Int
	let sourceHeight: Int
	let componentSampling: [Int]
	let widthInBlocks: Int
	let heightInBlocks: Int
	let sharpness: UInt8
	let decision: String
	let consumers: Set<Consumer>

	var reference: String {
		"Tests/JXLEncoderTests/Fixtures/semantic/\(fixture).sem#epf_sharpness"
	}

	static let all: [Self] = [
		.init(
			fixture: "sharpness_pixel_edge", jpegInput: nil,
			sourceWidth: 32, sourceHeight: 32, componentSampling: [],
			widthInBlocks: 4, heightInBlocks: 4, sharpness: 4, decision: "DG-08",
			consumers: [.selectedSharpnessTokens]),
		.init(
			fixture: "sharpness_jpeg_444", jpegInput: "small_444",
			sourceWidth: 37, sourceHeight: 23,
			componentSampling: [1, 1, 1, 1, 1, 1],
			widthInBlocks: 5, heightInBlocks: 3, sharpness: 0, decision: "DG-12",
			consumers: [.jpegSharpnessMatchesReference, .actualJPEGSharpnessCrossCheck]),
		.init(
			fixture: "sharpness_jpeg_422", jpegInput: "small_422",
			sourceWidth: 37, sourceHeight: 23,
			componentSampling: [2, 1, 1, 1, 1, 1],
			widthInBlocks: 6, heightInBlocks: 3, sharpness: 0, decision: "DG-12",
			consumers: [.jpegSharpnessMatchesReference, .actualJPEGSharpnessCrossCheck]),
		.init(
			fixture: "sharpness_jpeg_440", jpegInput: "small_440",
			sourceWidth: 37, sourceHeight: 23,
			componentSampling: [1, 2, 1, 1, 1, 1],
			widthInBlocks: 5, heightInBlocks: 4, sharpness: 0, decision: "DG-12",
			consumers: [.jpegSharpnessMatchesReference, .actualJPEGSharpnessCrossCheck]),
		.init(
			fixture: "sharpness_jpeg_420_odd", jpegInput: "hopper_420_odd",
			sourceWidth: 101, sourceHeight: 67,
			componentSampling: [2, 2, 1, 1, 1, 1],
			widthInBlocks: 14, heightInBlocks: 10, sharpness: 0, decision: "DG-12",
			consumers: [.jpegSharpnessMatchesReference, .actualJPEGSharpnessCrossCheck]),
		.init(
			fixture: "sharpness_jpeg_gray_odd", jpegInput: "hopper_gray_odd",
			sourceWidth: 101, sourceHeight: 67, componentSampling: [1, 1],
			widthInBlocks: 13, heightInBlocks: 9, sharpness: 0, decision: "DG-12",
			consumers: [.jpegSharpnessMatchesReference, .actualJPEGSharpnessCrossCheck]),
		.init(
			fixture: "sharpness_jpeg_flower_513x267_420",
			jpegInput: "jpeg_flower_513x267_420", sourceWidth: 513,
			sourceHeight: 267, componentSampling: [2, 2, 1, 1, 1, 1],
			widthInBlocks: 66, heightInBlocks: 34, sharpness: 0, decision: "DG-12",
			consumers: [.jpegSharpnessMatchesReference, .actualJPEGSharpnessCrossCheck]),
		.init(
			fixture: "sharpness_jpeg_flower_513x267_440",
			jpegInput: "jpeg_flower_513x267_440", sourceWidth: 513,
			sourceHeight: 267, componentSampling: [1, 2, 1, 1, 1, 1],
			widthInBlocks: 65, heightInBlocks: 34, sharpness: 0, decision: "DG-12",
			consumers: [.jpegSharpnessMatchesReference, .actualJPEGSharpnessCrossCheck]),
	]

	func verifies(
		_ candidate: String, consumer: Consumer, knownIssues: Set<String> = []
	) -> Bool {
		guard candidate == reference, consumers.contains(consumer), knownIssues.isEmpty,
			let dump = try? SemanticDump(fixture: fixture),
			case .integers(let dimensions)? = dump.fields["epf_sharpness.dimensions"],
			case .integers(let values)? = dump.fields["epf_sharpness.values"],
			dimensions == [Int64(widthInBlocks), Int64(heightInBlocks)],
			values.count == widthInBlocks * heightInBlocks,
			values.allSatisfy({ $0 == Int64(sharpness) }),
			let data = try? dcGroupData(),
			let tokens = try? DCGroupSharpnessTests.tokens(data: data)
		else { return false }
		return tokensMatchNative(tokens, values: values)
	}

	func tokensMatchNative(_ tokens: [Token], values: [Int64]) -> Bool {
		let suffix = tokens.suffix(values.count)
		return suffix.count == values.count
			&& zip(suffix, values).allSatisfy {
				$0.0.context == 0 && $0.0.value == packSigned(Int32($0.1))
			}
	}

	func dcGroupData() throws -> DCGroupData {
		let subsampling: ChromaSubsampling
		if let jpegInput {
			let image = try JPEGParser.parse(
				JPEGSemanticCorpusEntry.jpegBytes(jpegInput))
			guard image.width == sourceWidth, image.height == sourceHeight,
				image.components.flatMap({
					[$0.horizontalSampling, $0.verticalSampling]
				})
					== componentSampling
			else { throw SharpnessProofError.inputMismatch(fixture) }
			subsampling = try JPEGTranscode(image).subsampling
		} else {
			guard sourceWidth == widthInBlocks * 8,
				sourceHeight == heightInBlocks * 8
			else { throw SharpnessProofError.inputMismatch(fixture) }
			subsampling = .none
		}
		if sharpness == 4 {
			return DCGroupData(
				widthInBlocks: widthInBlocks, heightInBlocks: heightInBlocks,
				subsampling: subsampling)
		}
		return DCGroupData(
			widthInBlocks: widthInBlocks, heightInBlocks: heightInBlocks,
			subsampling: subsampling, epfSharpness: sharpness)
	}
}

enum SharpnessProofError: Error { case inputMismatch(String) }

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

	static func tokens(data: DCGroupData) throws -> [Token] {
		var section = SectionWriter(mode: .staging(.staticDC))
		DCGroupEncoder.writeACMetadataTokens(data: data, writer: &section)
		return section.staged.compactMap { record in
			guard case .token(let context, let value) = record else { return nil }
			return Token(context: context, value: value)
		}
	}

	@Test("metadata emits the selected sharpness on every full-grid block")
	func selectedSharpnessTokens() throws {
		let samplingModes: [([Int], [Int])] = [
			([1, 1, 1], [1, 1, 1]),
			([2, 1, 1], [1, 1, 1]),
			([1, 1, 1], [2, 1, 1]),
			([2, 1, 1], [2, 1, 1]),
		]
		for (horizontal, vertical) in samplingModes {
			let subsampling = try #require(
				ChromaSubsampling.fromJPEG(
					horizontalSampling: horizontal, verticalSampling: vertical))
			let defaultData = DCGroupData(
				widthInBlocks: 5, heightInBlocks: 3, subsampling: subsampling)
			#expect(defaultData.epfSharpness == 4)
			let baseline = try Self.tokens(data: defaultData)
			let suffixCount = 5 * 3
			let prefixCount = baseline.count - suffixCount
			for sharpness in [UInt8(0), 4, 7] {
				let data = DCGroupData(
					widthInBlocks: 5, heightInBlocks: 3,
					subsampling: subsampling, epfSharpness: sharpness)
				let emitted = try Self.tokens(data: data)
				#expect(emitted.count == baseline.count)
				#expect(
					Array(emitted.prefix(prefixCount))
						== Array(baseline.prefix(prefixCount)))
				#expect(
					emitted.suffix(suffixCount).allSatisfy {
						$0.context == 0
							&& $0.value == packSigned(Int32(sharpness))
					})
			}
			func rawBits(_ sharpness: UInt8) -> [String] {
				var section = SectionWriter(mode: .staging(.staticDC))
				DCGroupEncoder.write(
					data: DCGroupData(
						widthInBlocks: 5, heightInBlocks: 3,
						subsampling: subsampling, epfSharpness: sharpness),
					writer: &section)
				return section.staged.compactMap { record in
					guard case .rawBits(let value, let count) = record else {
						return nil
					}
					return "\(count):\(value)"
				}
			}
			#expect(rawBits(0) == rawBits(4) && rawBits(4) == rawBits(7))
		}

		let pixel = try Self.decodedSharpness(Self.dump("sharpness_pixel_edge"))
		let pixelData = DCGroupData(widthInBlocks: 4, heightInBlocks: 4)
		#expect(pixelData.epfSharpness == 4)
		let pixelTokens = try Self.tokens(data: pixelData)
		#expect(pixel.dimensions == [4, 4])
		#expect(
			pixel.values.map { Int64(packSigned(Int32($0))) }
				== Array(pixelTokens.suffix(16)).map { Int64($0.value) })
		#expect(
			SharpnessProofCase.all[0].verifies(
				SharpnessProofCase.all[0].reference,
				consumer: .selectedSharpnessTokens))
	}

	@Test("JPEG metadata matches pinned native sharpness across sampling and grayscale")
	func jpegSharpnessMatchesReference() throws {
		for proof in SharpnessProofCase.all where proof.jpegInput != nil {
			#expect(
				proof.verifies(
					proof.reference, consumer: .jpegSharpnessMatchesReference))
			let reference = try Self.decodedSharpness(Self.dump(proof.fixture))
			#expect(
				reference.dimensions == [
					Int64(proof.widthInBlocks), Int64(proof.heightInBlocks),
				])
			#expect(
				reference.values.count == proof.widthInBlocks * proof.heightInBlocks
			)
			#expect(reference.values.allSatisfy { $0 == Int64(proof.sharpness) })
			let tokens = try Self.tokens(data: proof.dcGroupData())
			let altered =
				Array(tokens.dropLast()) + [
					Token(
						context: 0,
						value: packSigned(Int32(proof.sharpness + 1)))
				]
			#expect(!proof.tokensMatchNative(altered, values: reference.values))
		}
	}

	@Test(
		"native decoding observes actual JPEG sharpness in both coding modes",
		.enabled(
			if: ProcessInfo.processInfo.environment["JXL_SHARPNESS_EXPORT_DIR"] != nil
				|| ProcessInfo.processInfo.environment["JXL_SHARPNESS_CHECK_DIR"]
					!= nil
		))
	func actualJPEGSharpnessCrossCheck() throws {
		let exportPath = ProcessInfo.processInfo.environment["JXL_SHARPNESS_EXPORT_DIR"]
		let checkPath = ProcessInfo.processInfo.environment["JXL_SHARPNESS_CHECK_DIR"]
		#expect((exportPath == nil) != (checkPath == nil))
		if let exportPath {
			let directory = URL(fileURLWithPath: exportPath, isDirectory: true)
			try FileManager.default.createDirectory(
				at: directory, withIntermediateDirectories: true)
			for proof in SharpnessProofCase.all where proof.jpegInput != nil {
				guard let jpegInput = proof.jpegInput else { continue }
				let transcode = try JPEGTranscode(
					JPEGParser.parse(
						JPEGSemanticCorpusEntry.jpegBytes(jpegInput))
				)
				for optimizeCodes in [false, true] {
					let suffix = optimizeCodes ? "optimized" : "static"
					let path = directory.appendingPathComponent(
						"\(proof.fixture)-\(suffix).jxl")
					try Data(
						Encoder.encodeJPEG(
							transcode, optimizeCodes: optimizeCodes)
					).write(to: path)
				}
			}
			return
		}

		let directory = URL(fileURLWithPath: try #require(checkPath), isDirectory: true)
		for proof in SharpnessProofCase.all where proof.jpegInput != nil {
			let expected = try Self.dump(proof.fixture)
			for suffix in ["static", "optimized"] {
				let actual = try SemanticDump(
					parsing: String(
						contentsOf: directory.appendingPathComponent(
							"\(proof.fixture)-\(suffix).epf.sem"),
						encoding: .utf8))
				#expect(actual == expected)
				#expect(
					proof.verifies(
						proof.reference,
						consumer: .actualJPEGSharpnessCrossCheck))
			}
		}
	}

	@Test("sharpness fixture proofs require consumed exact comparisons")
	func sharpnessProofReferences() throws {
		for proof in SharpnessProofCase.all {
			let consumer: SharpnessProofCase.Consumer =
				proof.jpegInput == nil
				? .selectedSharpnessTokens : .jpegSharpnessMatchesReference
			#expect(proof.verifies(proof.reference, consumer: consumer))
			#expect(!proof.verifies(proof.reference + "-other", consumer: consumer))
			#expect(
				!proof.verifies(
					proof.reference, consumer: consumer,
					knownIssues: ["GER-3386"]))
			let wrongConsumer: SharpnessProofCase.Consumer =
				proof.jpegInput == nil
				? .actualJPEGSharpnessCrossCheck : .selectedSharpnessTokens
			#expect(!proof.verifies(proof.reference, consumer: wrongConsumer))
			let tokens = try Self.tokens(data: proof.dcGroupData())
			let altered =
				Array(tokens.dropLast()) + [
					Token(
						context: 0,
						value: packSigned(Int32(proof.sharpness + 1)))
				]
			let native = try Self.decodedSharpness(Self.dump(proof.fixture))
			#expect(!proof.tokensMatchNative(altered, values: native.values))
			#expect(
				!proof.verifies(
					"Tests/JXLEncoderTests/Fixtures/semantic/\(proof.fixture).sem#epf",
					consumer: consumer
				))
		}
	}
}
