import Foundation
import Testing

@testable import JXLEncoder

struct JPEGSemanticCorpusEntry: Sendable, CustomTestStringConvertible {
	let name: String
	let jpegFixture: String
	let knownIssues: [String: Set<String>]

	var testDescription: String { name }
	static let categories = [
		"frame", "coeff_order", "block_context", "context_map",
		"quant_field", "ac_entropy", "ac_entropy_alphabet",
	]
	var applicableCategories: [String] {
		name == "ac_entropy_jpeg_2x1"
			? ["ac_entropy", "ac_entropy_alphabet"] : Self.categories
	}
	static let all: [Self] = [
		("jpeg_small_444", "small_444"), ("jpeg_small_422", "small_422"),
		("jpeg_small_440", "small_440"), ("jpeg_hopper_420_odd", "hopper_420_odd"),
		("jpeg_hopper_420_restart", "hopper_420_restart"),
		("jpeg_hopper_420_sof1", "hopper_420_sof1"),
		("jpeg_hopper_gray_odd", "hopper_gray_odd"),
		("ac_entropy_jpeg_2x1", "ac_entropy_jpeg_2x1"),
		("jpeg_flat_444", "jpeg_flat_444"),
		("jpeg_flower_513x267_420", "jpeg_flower_513x267_420"),
		("jpeg_flower_513x267_422", "ac_entropy_jpeg_2x1"),
		("jpeg_flower_513x267_440", "jpeg_flower_513x267_440"),
	].map { name, fixture in
		var issues: [String: Set<String>] = [:]
		if name == "ac_entropy_jpeg_2x1" {
			issues["ac_entropy"] = ["GER-3386"]
			issues["ac_entropy_alphabet"] = ["GER-3388"]
		} else if name != "jpeg_flat_444" {
			issues["coeff_order"] = ["GER-3386"]
			issues["ac_entropy"] = ["GER-3386"]
			issues["ac_entropy_alphabet"] = ["GER-3388"]
		}
		if name.hasPrefix("jpeg_hopper") || name.hasPrefix("jpeg_flower") {
			issues["context_map"] = ["GER-3386"]
		}
		return JPEGSemanticCorpusEntry(
			name: name, jpegFixture: fixture, knownIssues: issues)
	}
	static let rejectedJPEGFixtures = ["small_411"]

	static func jpegBytes(_ jpegFixture: String) throws -> [UInt8] {
		let bytes: [UInt8]
		do {
			bytes = try JPEGParserTests.fixture(jpegFixture)
		} catch {
			guard
				let url = Bundle.module.url(
					forResource: jpegFixture, withExtension: "jpg",
					subdirectory: "Fixtures/semantic")
			else { throw error }
			bytes = [UInt8](try Data(contentsOf: url))
		}
		return bytes
	}

	func encoded() throws -> SwiftJPEGSemanticEncoding.Result {
		let bytes = try Self.jpegBytes(jpegFixture)
		return try SwiftJPEGSemanticEncoding.encode(
			JPEGTranscode(JPEGParser.parse(bytes)))
	}
}

struct JPEGSemanticCase: Sendable, CustomTestStringConvertible {
	let entry: JPEGSemanticCorpusEntry
	let category: String

	var knownIssues: Set<String> { entry.knownIssues[category] ?? [] }
	var testDescription: String { "\(entry.name)#\(category)" }
	static var all: [Self] {
		JPEGSemanticCorpusEntry.all.flatMap { entry in
			entry.applicableCategories.map {
				JPEGSemanticCase(entry: entry, category: $0)
			}
		}
	}
	static var references: Set<String> {
		Set(
			all.map {
				"Tests/JXLEncoderTests/Fixtures/semantic/\($0.entry.name).sem#\($0.category)"
			})
	}
	static var contextWitnessReferences: Set<String> {
		Set(
			["420", "422", "440"].map {
				"Tests/JXLEncoderTests/Fixtures/semantic/jpeg_flower_513x267_\($0)_context.sem#block_context"
			})
	}
	static var knownIssueReferences: Set<String> {
		Set(
			all.filter { !$0.knownIssues.isEmpty }.map {
				"Tests/JXLEncoderTests/Fixtures/semantic/\($0.entry.name).sem#\($0.category)"
			})
	}
}

@Suite("JPEG semantic fixtures")
struct JPEGSemanticFixtureTests {
	@Test(
		"the recomposed JPEG encode is byte-identical to Encoder.encodeJPEG",
	)
	func jpegRecompositionMatchesEncoder() throws {
		for entry in JPEGSemanticCorpusEntry.all {
			let result = try entry.encoded()
			let transcode = try JPEGTranscode(
				JPEGParser.parse(
					JPEGSemanticCorpusEntry.jpegBytes(entry.jpegFixture)))
			let referenceEncoding = try Encoder.encodeJPEG(
				transcode, optimizeCodes: true)
			let matches = result.codestream.elementsEqual(referenceEncoding)
			#expect(matches)
		}
		let baseline = try #require(
			JPEGSemanticCorpusEntry.all.first { $0.name == "jpeg_small_444" })
		let decisions = try baseline.encoded().decisions
		var groups = decisions.acGroups
		var changedToken = false
		for group in groups.indices where !changedToken {
			for index in groups[group].indices {
				guard case .token(let context, let value) = groups[group][index]
				else {
					continue
				}
				groups[group][index] = .token(context: context, value: value + 1)
				changedToken = true
				break
			}
		}
		#expect(changedToken)
		let changed = SwiftJPEGFrameDecisions(
			transcode: decisions.transcode, coeffOrder: decisions.coeffOrder,
			blockContextMap: decisions.blockContextMap, dcCode: decisions.dcCode,
			acCode: decisions.acCode, acGroups: groups)
		let changedBytes = try SwiftJPEGSemanticEncoding.recompose(changed)
		let baselineBytes = try baseline.encoded().codestream
		let changedCodestream = !changedBytes.elementsEqual(baselineBytes)
		#expect(changedCodestream)
		let invalidCode = EntropyCode(
			contextMap: [], prefixCodes: decisions.acCode.prefixCodes,
			originalContextMap: decisions.acCode.originalContextMap,
			ansInfoTables: decisions.acCode.ansInfoTables)
		let invalid = SwiftJPEGFrameDecisions(
			transcode: decisions.transcode, coeffOrder: decisions.coeffOrder,
			blockContextMap: decisions.blockContextMap, dcCode: decisions.dcCode,
			acCode: invalidCode, acGroups: decisions.acGroups)
		let invalidDumpRejected = (try? SemanticDump(swiftJPEGDecisions: invalid)) == nil
		#expect(invalidDumpRejected)
	}

	@Test(
		"actual Swift JPEG decisions match the pinned reference categories",
	)
	func jpegMatchesReference() throws {
		let encoded = try Dictionary(
			uniqueKeysWithValues: JPEGSemanticCorpusEntry.all.map {
				($0.name, try $0.encoded())
			})
		for semanticCase in JPEGSemanticCase.all {
			let actual = try SemanticDump(
				swiftJPEGDecisions: encoded[semanticCase.entry.name]!.decisions)
			let reference = try SemanticDump(fixture: semanticCase.entry.name)
			let differences = actual.restricted(to: [semanticCase.category])
				.differences(
					from: reference.restricted(to: [semanticCase.category]))
			if semanticCase.knownIssues.isEmpty {
				#expect(
					differences.isEmpty,
					"\(semanticCase.testDescription): \(differences)")
			} else {
				withKnownIssue(
					Comment(
						rawValue: semanticCase.knownIssues.sorted().joined(
							separator: ", "))
				) {
					#expect(
						differences.isEmpty,
						"\(semanticCase.testDescription): \(differences)")
				}
			}
		}
	}

	@Test(
		"the JPEG corpus covers sampling, odd bounds and partial multigroup edges",
	)
	func jpegCorpusCoversSamplingAndEdges() throws {
		#expect(JPEGSemanticCorpusEntry.all.count == 12)
		#expect(JPEGSemanticCorpusEntry.rejectedJPEGFixtures == ["small_411"])
		let sampling = Set(
			try JPEGSemanticCorpusEntry.all.map {
				try JPEGTranscode(
					JPEGParser.parse(
						JPEGSemanticCorpusEntry.jpegBytes($0.jpegFixture))
				)
				.subsampling.channelMode
			})
		#expect(sampling.count >= 4)
		for (name, horizontal, vertical) in [
			("jpeg_flower_513x267_420", 1, 1),
			("jpeg_flower_513x267_422", 1, 0),
			("jpeg_flower_513x267_440", 0, 1),
		] {
			let entry = try #require(
				JPEGSemanticCorpusEntry.all.first { $0.name == name })
			let transcode = try JPEGTranscode(
				JPEGParser.parse(
					JPEGSemanticCorpusEntry.jpegBytes(entry.jpegFixture)))
			#expect(transcode.width == 513 && transcode.height == 267)
			#expect(transcode.subsampling.horizontalShift(0) == horizontal)
			#expect(transcode.subsampling.verticalShift(0) == vertical)
			#expect(transcode.subsampling.horizontalShift(1) == 0)
			#expect(transcode.subsampling.verticalShift(1) == 0)
			#expect(ImageDim(width: 513, height: 267).groupCount == 6)
		}
		#expect(throws: JPEGTranscode.TranscodeError.unsupportedSubsampling) {
			try JPEGTranscode(
				JPEGParser.parse(JPEGParserTests.fixture("small_411")))
		}
	}

	@Test(
		"known JPEG issues name applicable categories and cannot verify inventory rows",
	)
	func jpegKnownIssuesWellFormed() throws {
		#expect(JPEGSemanticCase.references.count == 79)
		#expect(
			JPEGSemanticCorpusEntry.all.allSatisfy {
				Set($0.knownIssues.keys).isSubset(
					of: Set(JPEGSemanticCorpusEntry.categories))
			})
		#expect(
			JPEGSemanticCase.knownIssueReferences.isSubset(
				of: JPEGSemanticCase.references))
		#expect(JPEGSemanticCase.knownIssueReferences.count == 39)
		#expect(
			JPEGSemanticCorpusEntry.all.allSatisfy { entry in
				entry.knownIssues.values.allSatisfy {
					!$0.isEmpty && $0.isSubset(of: ["GER-3386", "GER-3388"])
				}
			})
		#expect(
			!JPEGSemanticCase.knownIssueReferences.contains(
				"Tests/JXLEncoderTests/Fixtures/semantic/small_411.sem#frame"))
		#expect(
			JPEGSemanticCorpusEntry.rejectedJPEGFixtures.allSatisfy { rejected in
				!JPEGSemanticCase.references.contains(
					"Tests/JXLEncoderTests/Fixtures/semantic/\(rejected).sem#frame"
				)
			})
	}

	@Test(
		"parsed JPEG component grids cover every encoded block",
	)
	func jpegComponentGridsCoverEncodedBlocks() throws {
		for entry in JPEGSemanticCorpusEntry.all {
			let bytes = try JPEGSemanticCorpusEntry.jpegBytes(entry.jpegFixture)
			let transcode = try JPEGTranscode(JPEGParser.parse(bytes))
			let dim = ImageDim(
				width: transcode.width, height: transcode.height,
				blockAlignment: (
					x: 1 << transcode.subsampling.maxHorizontalShift,
					y: 1 << transcode.subsampling.maxVerticalShift
				))
			for channel in 0..<3 {
				#expect(
					transcode.blocksPerLine(channel: channel)
						== transcode.subsampling.blocksAcross(
							channel: channel,
							fullWidthInBlocks: dim.widthInBlocks))
				#expect(
					transcode.blocksPerColumn(channel: channel)
						== transcode.subsampling.blocksDown(
							channel: channel,
							fullHeightInBlocks: dim.heightInBlocks))
			}
		}
	}

	@Test(
		"JPEG tokens use full-resolution luma DC buckets at sampled chroma positions",
	)
	func jpegContextsUseFullResolutionLumaDCBuckets() throws {
		for suffix in ["420", "422", "440"] {
			let name = "jpeg_flower_513x267_\(suffix)"
			let entry = try #require(
				JPEGSemanticCorpusEntry.all.first { $0.name == name })
			let transcode = try JPEGTranscode(
				JPEGParser.parse(
					JPEGSemanticCorpusEntry.jpegBytes(entry.jpegFixture)))
			let reference = try SemanticDump(fixture: name)
			let expected = try SemanticDump(fixture: "\(name)_context")
			let actual = try SwiftJPEGSemanticEncoding.contextWitness(
				transcode, reference: reference)
			#expect(actual == expected, "\(name) context witness differs")
			#expect(expected.fields["jpeg_context.group_count"] == .integers([6]))
			#expect(expected.fields["jpeg_context.bucket_count"] == .integers([3]))
			let distinguishing = suffix == "420" ? 608 : suffix == "422" ? 636 : 644
			let equalities = suffix == "440" ? 3 : 9
			#expect(
				expected.fields["jpeg_context.distinguishing_chroma_positions"]
					== .integers([Int64(distinguishing)]))
			#expect(
				expected.fields["jpeg_context.threshold_equalities"]
					== .integers([Int64(equalities)]))
		}
	}

	@Test(
		"DC buckets advance only when the DC value is strictly greater than a threshold",
	)
	func jpegDCBucketBoundaryUsesStrictGreaterThan() throws {
		let thresholds = [-3, 0, 7]
		let values: [Int32] = [-4, -3, -2, -1, 0, 1, 6, 7, 8]
		let dump = try SwiftJPEGSemanticEncoding.dcBoundaryWitness(
			thresholds: thresholds, dc: values)
		#expect(
			dump.fields["jpeg_context.boundary"]
				== .integers([
					-4, 0, -3, 0, -2, 1, -1, 1, 0, 1, 1, 2,
					6, 2, 7, 2, 8, 3,
				]))
	}
}
