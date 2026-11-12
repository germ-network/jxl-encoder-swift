import Foundation
import Testing

@testable import JXLEncoder

/// One recorded reference encode: an input committed under
/// `Fixtures/semantic/`, the distance, and the harness's dump of the pinned
/// libjxl's `-e 4` encoding of it (`<name>.sem`). `Reference/provenance.tsv`
/// records how each was made.
struct SemanticCorpusEntry: CustomTestStringConvertible, Sendable {
	enum Input: Sendable {
		/// 8-bit sRGB binary PPM (`P6`), `Fixtures/semantic/<file>.ppm`.
		case srgb8(file: String)
		/// Linear float `StageDump`, `Fixtures/<file>.dump`.
		case linear(file: String)
	}

	let name: String
	let input: Input
	let distance: Float
	/// Category to the issues that must all land before Swift matches upstream
	/// there, for each category where Swift is known to decide differently on
	/// this entry. That category's comparison runs under `withKnownIssue`, so it
	/// stays green and fails the moment Swift starts matching (the cue to drop
	/// the entry here). Other categories of the same entry are compared normally.
	let knownIssues: [String: Set<String>]

	var testDescription: String { name }

	/// The committed corpus. Each entry has a `.sem` fixture and provenance row.
	static let all: [SemanticCorpusEntry] = [
		SemanticCorpusEntry(
			name: "edge", input: .linear(file: "edge_linear"), distance: 1,
			knownIssues: [
				"frame": ["GER-3387"], "block_context": ["GER-3387"],
				"context_map": ["GER-3387"],
				"ac_entropy": ["GER-3386"],
				"ac_entropy_alphabet": ["GER-3386"],
			]),
		SemanticCorpusEntry(
			name: "multigroup", input: .linear(file: "multigroup_linear"), distance: 1,
			knownIssues: [
				"coeff_order": ["GER-3386", "GER-3387"], "frame": ["GER-3387"],
				"block_context": ["GER-3387"], "context_map": ["GER-3387"],
				"ac_entropy": ["GER-3386"],
				"ac_entropy_alphabet": ["GER-3386"],
			]),
		SemanticCorpusEntry(
			name: "flower_512_d1", input: .srgb8(file: "flower_512"), distance: 1,
			knownIssues: [
				"coeff_order": ["GER-3386", "GER-3387"], "frame": ["GER-3387"],
				"block_context": ["GER-3387"], "context_map": ["GER-3387"],
				"ac_entropy": ["GER-3386"],
				"ac_entropy_alphabet": ["GER-3386"],
			]),
		SemanticCorpusEntry(
			name: "flower_512_d3", input: .srgb8(file: "flower_512"), distance: 3,
			knownIssues: [
				"coeff_order": ["GER-3386", "GER-3387"], "frame": ["GER-3387"],
				"block_context": ["GER-3387"], "context_map": ["GER-3387"],
				"ac_entropy": ["GER-3386"],
				"ac_entropy_alphabet": ["GER-3386"],
			]),
		SemanticCorpusEntry(
			name: "flower_1024", input: .srgb8(file: "flower_1024"), distance: 1,
			knownIssues: [
				"coeff_order": ["GER-3386", "GER-3387", "GER-3419"],
				"frame": ["GER-3387"], "block_context": ["GER-3387"],
				"context_map": ["GER-3387", "GER-3419"],
				"ac_entropy": ["GER-3386"],
				"ac_entropy_alphabet": ["GER-3386"],
			]),
	]
}

extension SemanticCorpusEntry {
	func encoded() throws -> SwiftSemanticEncoding.Result {
		switch input {
		case .srgb8(let file):
			return try SwiftSemanticEncoding.encode(
				loadPPM(fixture: file), distance: distance)
		case .linear(let file):
			return try SwiftSemanticEncoding.encode(
				linear: StageDump(fixture: file), distance: distance)
		}
	}
}

/// One corpus entry compared in one category: the unit of expected divergence.
struct SemanticCase: CustomTestStringConvertible, Sendable {
	let entry: SemanticCorpusEntry
	let category: String

	/// Empty when this pair is expected to match.
	var knownIssues: Set<String> { entry.knownIssues[category] ?? [] }
	var testDescription: String { "\(entry.name)#\(category)" }

	/// Every corpus entry crossed with every Swift-emitted category.
	static var all: [SemanticCase] {
		SemanticCorpusEntry.all.flatMap { entry in
			SemanticDump.swiftEmittedCategories.sorted().map {
				SemanticCase(entry: entry, category: $0)
			}
		}
	}

	/// `<fixture path>#<category>` for every case, the form an inventory
	/// `fixture` reference takes. A reference outside this set is compared by
	/// no test.
	static var references: Set<String> {
		Set(
			all.map {
				"Tests/JXLEncoderTests/Fixtures/semantic/" + $0.entry.name + ".sem#"
					+ $0.category
			})
	}

	/// The subset of `references` whose case runs under a known issue; such a
	/// fixture verifies nothing.
	static var knownIssueReferences: Set<String> {
		Set(
			all.filter { !$0.knownIssues.isEmpty }.map {
				"Tests/JXLEncoderTests/Fixtures/semantic/" + $0.entry.name + ".sem#"
					+ $0.category
			})
	}
}

enum SemanticFixtureComparison {
	static func differences(
		actual: SemanticDump, reference: SemanticDump, category: String
	) -> [SemanticDifference] {
		actual.restricted(to: [category]).differences(
			from: reference.restricted(to: [category]))
	}

	static func isExpectedDivergence(
		_ differences: [SemanticDifference], knownIssues: Set<String>
	) -> Bool {
		!differences.isEmpty && !knownIssues.isEmpty
	}
}

/// Stage fixtures (`Fixtures/*.dump`) whose consuming test runs under
/// `withKnownIssue`, by fixture path, with the issue. Kept next to the
/// wrappers it describes; an inventory row can't cite these as verification.
enum StageFixtureKnownIssues {
	static let byFixture: [String: String] = [:]
}

/// Reads an 8-bit binary PPM; Foundation-only so it runs on Linux CI.
func loadPPM(fixture name: String) throws -> ImageBuffer {
	guard
		let url = Bundle.module.url(
			forResource: name, withExtension: "ppm", subdirectory: "Fixtures/semantic")
	else { throw SemanticDumpError.fixtureNotFound(name) }
	let data = [UInt8](try Data(contentsOf: url))
	var offset = 0
	func token() -> String {
		while offset < data.count {
			if data[offset] == 35 {
				while offset < data.count && data[offset] != 10 { offset += 1 }
			} else if [9, 10, 13, 32].contains(data[offset]) {
				offset += 1
			} else {
				break
			}
		}
		let start = offset
		while offset < data.count && ![9, 10, 13, 32].contains(data[offset]) { offset += 1 }
		return String(decoding: data[start..<offset], as: UTF8.self)
	}
	guard token() == "P6", let width = Int(token()), let height = Int(token()),
		token() == "255", offset < data.count
	else { throw SemanticDumpError.badHeader(name) }
	if data[offset] == 13 && offset + 1 < data.count && data[offset + 1] == 10 { offset += 1 }
	offset += 1
	return try ImageBuffer(width: width, height: height, samples: Array(data[offset...]))
}

/// The Swift encoder's decisions, dumped from its own internals, agree with the
/// pinned libjxl's for every corpus entry in each category the Swift side
/// emits, except where a named issue records that Swift still differs.
@Suite("Semantic fixtures")
struct SemanticFixtureTests {
	@Test("the recomposed encode is byte-identical to Encoder.encode")
	func recompositionMatchesEncoder() throws {
		let entries = SemanticCorpusEntry.all.filter {
			if case .srgb8 = $0.input { return true }
			return false
		}
		#expect(entries.count == 3)
		for entry in entries {
			guard case .srgb8(let file) = entry.input else { continue }
			let image = try loadPPM(fixture: file)
			#expect(
				try SwiftSemanticEncoding.encode(image, distance: entry.distance)
					.codestream
					== Encoder.encode(image, distance: entry.distance))
		}
	}

	@Test("the recomposed linear encode is byte-identical to Encoder.encodeFrame")
	func linearRecompositionMatchesEncodeFrame() throws {
		let entries = SemanticCorpusEntry.all.filter {
			if case .linear = $0.input { return true }
			return false
		}
		#expect(entries.count == 2)
		for entry in entries {
			guard case .linear(let file) = entry.input else { continue }
			let input = try StageDump(fixture: file)
			let pixels = input.interleaved
			let width = input.width
			let params = try DistanceParams(distance: entry.distance)
			var writer = BitWriter()
			try ImageHeader.write(
				width: input.width, height: input.height, transferFunction: .linear,
				to: &writer)
			try Encoder.encodeFrame(
				stripeAt: {
					PlaneBuffer.copyAndPad(
						source: pixels, sourceWidth: width, rect: $0)
				}, width: input.width, height: input.height, params: params,
				optimizeCodes: true, writer: &writer)
			writer.zeroPadToByte()
			let result = try SwiftSemanticEncoding.encode(
				linear: input, distance: entry.distance)
			#expect(result.codestream == writer.take())
			if entry.name == "multigroup" {
				// Distinct block values pin group placement and partial edge groups.
				var decisions = result.decisions
				let dim = ImageDim(width: input.width, height: input.height)
				let groupSize = Geometry.groupDimInBlocks
				for group in 0..<dim.groupCount {
					let x0 = group % dim.widthInGroups * groupSize
					let y0 = group / dim.widthInGroups * groupSize
					let width = min(groupSize, dim.widthInBlocks - x0)
					let blockCount: Int = decisions.quantFields[group].count
					var field = [UInt8]()
					field.reserveCapacity(blockCount)
					for localIndex in 0..<blockCount {
						let localY: Int = localIndex / width
						let localX: Int = localIndex % width
						let absoluteY: Int = y0 + localY
						let absoluteX: Int = x0 + localX
						let rasterIndex: Int =
							absoluteY * dim.widthInBlocks + absoluteX
						let rawValue: Int = 1 + rasterIndex % 251
						field.append(UInt8(rawValue))
					}
					decisions.quantFields[group] = field
				}
				let expected = (0..<(dim.widthInBlocks * dim.heightInBlocks)).map {
					Int64(1 + $0 % 251)
				}
				let dump = try SemanticDump(swiftDecisions: decisions)
				#expect(dump.fields["quant_field.raw"] == .integers(expected))
			}
		}
	}

	@Test("the corpus has a large multi-group entry above 8 groups")
	func corpusCoversStreamingSize() throws {
		#expect(SemanticCorpusEntry.all.count == 5)
		let entry = try #require(SemanticCorpusEntry.all.first { $0.name == "flower_1024" })
		guard case .srgb8(let file) = entry.input else {
			Issue.record("large entry must be an 8-bit image")
			return
		}
		let image = try loadPPM(fixture: file)
		#expect(ImageDim(width: image.width, height: image.height).groupCount == 16)
	}

	@Test("every known issue names an emitted category and an accepted issue")
	func knownIssuesWellFormed() throws {
		#expect(Set(SemanticCorpusEntry.all.map(\.name)).count == 5)
		#expect(SemanticCase.all.count == 35)
		#expect(SemanticCase.references.count == 35)
		for entry in SemanticCorpusEntry.all {
			for (category, issues) in entry.knownIssues {
				#expect(SemanticDump.swiftEmittedCategories.contains(category))
				#expect(
					!issues.isEmpty
						&& issues.isSubset(of: [
							"GER-3386", "GER-3387", "GER-3388",
							"GER-3419",
						]))
			}
		}
		#expect(
			SemanticCase.knownIssueReferences
				== Set(
					SemanticCase.all.filter { !$0.knownIssues.isEmpty }.map {
						"Tests/JXLEncoderTests/Fixtures/semantic/"
							+ $0.entry.name + ".sem#" + $0.category
					}))
	}

	@Test(
		"a custom coefficient order is signalled exactly when some channel's order is not natural"
	)
	func customOrderSignalledOnlyWhenNondefault() throws {
		#expect(SemanticCorpusEntry.all.count == 5)
		for entry in SemanticCorpusEntry.all {
			let order = try entry.encoded().decisions.coeffOrder
			#expect(
				order.isCustom == order.orders.contains { $0 != CoeffOrder.natural }
			)
		}
	}

	@Test(
		"Swift's decisions match the pinned libjxl's",
		arguments: SemanticCase.all)
	func matchesReference(_ semanticCase: SemanticCase) throws {
		let actual = try SemanticDump(
			swiftDecisions: try semanticCase.entry.encoded().decisions
		).restricted(to: [semanticCase.category])
		let reference = try SemanticDump(fixture: semanticCase.entry.name).restricted(to: [
			semanticCase.category
		])
		#expect(!actual.fields.isEmpty && !reference.fields.isEmpty)
		let differences = SemanticFixtureComparison.differences(
			actual: actual, reference: reference, category: semanticCase.category)
		if !SemanticFixtureComparison.isExpectedDivergence(
			differences, knownIssues: semanticCase.knownIssues)
		{
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

	@Test("a known alphabet divergence does not hide an entropy frequency mutation")
	func knownAlphabetIssueDoesNotMaskEntropyMutation() throws {
		let reference = try SemanticDump(fixture: "edge")
		var alphabetMutation = try SemanticDump(parsing: reference.serialized)
		let alpha = try #require(
			alphabetMutation.fields["ac_entropy_alphabet.ans_log_alpha_size"])
		if case .integers = alpha {
			let text = reference.serialized.replacingOccurrences(
				of: "ac_entropy_alphabet.ans_log_alpha_size i 1 7",
				with: "ac_entropy_alphabet.ans_log_alpha_size i 1 6")
			alphabetMutation = try SemanticDump(parsing: text)
		}
		let alphabetDifferences = SemanticFixtureComparison.differences(
			actual: alphabetMutation, reference: reference,
			category: "ac_entropy_alphabet")
		#expect(!alphabetDifferences.isEmpty)
		#expect(
			SemanticFixtureComparison.isExpectedDivergence(
				alphabetDifferences, knownIssues: ["GER-3388"]))
		let frequencyLine = try #require(
			reference.serialized.split(separator: "\n").first {
				$0.hasPrefix("ac_entropy.ans.frequencies ")
			})
		var parts = frequencyLine.split(separator: " ").map(String.init)
		let values = parts.dropFirst(3).compactMap { Int64($0) }
		#expect(values.count >= 2)
		parts[3] = String(values[0] + 1)
		parts[4] = String(values[1] - 1)
		let mutatedLine = parts.joined(separator: " ")
		var entropyMutation = try SemanticDump(
			parsing: reference.serialized.replacingOccurrences(
				of: String(frequencyLine), with: mutatedLine))
		let entropyDifferences = SemanticFixtureComparison.differences(
			actual: entropyMutation, reference: reference, category: "ac_entropy")
		#expect(entropyDifferences.contains { $0.field == "ac_entropy.ans.frequencies" })
		#expect(
			!SemanticFixtureComparison.isExpectedDivergence(
				entropyDifferences, knownIssues: []))
	}
}

/// A changed decision is caught by the comparison, even though the file it
/// produces still decodes.
@Suite("Semantic mutations")
struct SemanticMutationTests {
	static func encodings(contextFlip: Bool) throws -> (
		baseline: SwiftSemanticEncoding.Result, actual: SwiftSemanticEncoding.Result,
		field: String, expected: SemanticDifference.Kind
	) {
		let input = try StageDump(fixture: "multigroup_linear")
		let pixels = input.interleaved
		let width = input.width
		let dim = ImageDim(width: input.width, height: input.height)
		let params = try DistanceParams(distance: 1)
		let baseline = try SwiftSemanticEncoding.encode(linear: input, distance: 1)
		let groups = (0..<dim.groupCount).map {
			Encoder.computeACGroup(
				stripeAt: {
					PlaneBuffer.copyAndPad(
						source: pixels, sourceWidth: width, rect: $0)
				}, dim: dim, groupX: $0 % dim.widthInGroups,
				groupY: $0 / dim.widthInGroups, params: params)
		}
		var alterations = SwiftSemanticEncoding.Alterations.none
		let field: String
		let expected: SemanticDifference.Kind
		if contextFlip {
			let code = baseline.decisions.acCode
			try #require(code.originalContextMap == nil)
			let used = Set(
				groups.flatMap {
					Encoder.tokenizeACGroup(
						$0, order: baseline.decisions.coeffOrder.orders,
						mode: .staging(.staticAC)
					).section.staged.compactMap { record -> Int? in
						if case .token(let context, _) = record {
							return Int(context)
						}
						return nil
					}
				})
			let map = code.contextMap
			let index = try #require(
				map.indices.first { index in
					!used.contains(index)
						&& map.filter { $0 == map[index] }.count > 1
				})
			let destination = try #require(map.first { $0 != map[index] })
			#expect(!used.contains(index))
			#expect(map.filter { $0 == map[index] }.count > 1)
			expected = .valueMismatch(
				index: index, expected: String(map[index]),
				actual: String(destination))
			field = "context_map.ac"
			alterations.acCode = { code in
				var changed = code.contextMap
				changed[index] = destination
				code = EntropyCode(
					contextMap: changed, prefixCodes: code.prefixCodes,
					originalContextMap: code.originalContextMap,
					ansInfoTables: code.ansInfoTables)
			}
		} else {
			let order = baseline.decisions.coeffOrder
			try #require(order.isCustom)
			let candidates = (0..<3).compactMap { channel -> (Int, [Int])? in
				let positions = (1..<64).filter { position in
					groups.allSatisfy { group in
						stride(
							from: 0,
							to: group.coefficients[channel].count,
							by: 64
						).allSatisfy {
							group.coefficients[channel][
								$0 + order.orders[channel][position]
							] == 0
						}
					}
				}
				return positions.count >= 2 ? (channel, positions) : nil
			}
			let (channel, positions) = try #require(candidates.first)
			let a = positions[0]
			let b = positions[1]
			expected = .valueMismatch(
				index: a, expected: String(order.orders[channel][a]),
				actual: String(order.orders[channel][b]))
			field = "coeff_order.dct8.c\(channel)"
			alterations.coeffOrder = { order in
				var changed = order.orders
				changed[channel].swapAt(a, b)
				order = CoeffOrder.Result(orders: changed, isCustom: order.isCustom)
			}
		}
		let actual = try SwiftSemanticEncoding.encode(
			linear: input, distance: 1, altering: alterations)
		return (baseline, actual, field, expected)
	}

	@Test("a flipped entry of a token-free AC context is reported in context_map only")
	func flippedContextMapEntryCaught() throws {
		let pair = try Self.encodings(contextFlip: true)
		#expect(pair.actual.codestream != pair.baseline.codestream)
		let differences = try SemanticDump(swiftDecisions: pair.actual.decisions)
			.differences(
				from: SemanticDump(swiftDecisions: pair.baseline.decisions))
		#expect(differences.map(\.field) == ["context_map.ac"])
		#expect(differences.first?.kind == pair.expected)
	}

	@Test(
		"two swapped always-zero coefficient-order positions are reported in coeff_order only"
	)
	func swappedCoeffOrderCaught() throws {
		let pair = try Self.encodings(contextFlip: false)
		#expect(pair.actual.codestream != pair.baseline.codestream)
		let differences = try SemanticDump(swiftDecisions: pair.actual.decisions)
			.differences(
				from: SemanticDump(swiftDecisions: pair.baseline.decisions))
		#expect(differences.map(\.field) == [pair.field])
		#expect(differences.first?.kind == pair.expected)
	}
}
