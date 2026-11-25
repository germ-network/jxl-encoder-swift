//
//  ContextTree.swift
//  JXLEncoder
//
//  Builds the selected pinned libjxl modular tree for DC and AC metadata.
//  The fixed token stream below remains a legacy tiny-tree diagnostic path.
//
//  Generator: lib/jxl/modular/encoding/enc_encoding.cc
//  Upstream: libjxl@a7a9c787341cf703dede03c2009fa460cae5e5df
//  Config: e4 Cheetah pixel; JPEG -j 1
//
enum ContextTree {
	enum Predictor: UInt32, Sendable {
		case zero = 0
		case left = 1
		case gradient = 5
		case weighted = 6
	}

	enum Node: Equatable, Sendable {
		case split(property: Int, threshold: Int32, greater: Int, notGreater: Int)
		case leaf(predictor: Predictor, context: UInt32)
	}

	struct Prepared: Sendable {
		let nodes: [Node]
		let tokens: [Token]
		let contextCount: Int
		let dcGroupCount: Int

		func leaf(
			streamID: Int, channel: Int, row: Int, north: Int32,
			west: Int32, weightedProperty: Int64
		) -> Node {
			var index = 0
			while true {
				switch nodes[index] {
				case .leaf(let predictor, let context):
					return .leaf(predictor: predictor, context: context)
				case .split(
					let property, let threshold, let greater, let notGreater):
					let value: Int64 =
						switch property {
						case 0: Int64(channel)
						case 1: Int64(streamID)
						case 2: Int64(row)
						case 6: Int64(north)
						case 7: Int64(west)
						case 15: weightedProperty
						default:
							preconditionFailure(
								"unsupported selected tree property"
							)
						}
					index = value > Int64(threshold) ? greater : notGreater
				}
			}
		}
	}

	static func prepare(groups: [DCGroupData], jpegTranscode: Bool) -> Prepared {
		let dcPixels = max(
			1, groups.reduce(0) { $0 + $1.quantDC.reduce(0) { $0 + $1.count } })
		let metadataPixels = max(
			1,
			groups.reduce(0) { sum, group in
				let blocks = group.widthInBlocks * group.heightInBlocks
				return sum + 2 * group.cmapWidth * group.cmapHeight + 3 * blocks
			})
		let dcTree = fixedWeightedTree(totalPixels: dcPixels)
		let metadataTree = metadataTree(
			totalPixels: metadataPixels, jpegTranscode: jpegTranscode)
		let merged = Draft.split(
			property: 1, threshold: Int32(2 * groups.count),
			greater: metadataTree, notGreater: dcTree)
		return flatten(merged, dcGroupCount: groups.count)
	}

	/// A streaming DC group's local trees (enc_encoding.cc:72-102, 495-549),
	/// each sized by that group's own pixels rather than the frame's.
	static func prepareLocal(group: DCGroupData) -> (dc: Prepared, metadata: Prepared) {
		preconditionFailure("not implemented")
	}

	private indirect enum Draft {
		case split(property: Int, threshold: Int32, greater: Draft, notGreater: Draft)
		case leaf(Predictor)
	}

	private static let wpCutoffs: [Int32] = [
		-500, -392, -255, -191, -127, -95, -63, -47, -31, -23, -15,
		-11, -7, -4, -3, -1, 0, 1, 3, 5, 7, 11, 15, 23, 31, 47,
		63, 95, 127, 191, 255, 392, 500,
	]

	private static func fixedWeightedTree(totalPixels: Int) -> Draft {
		let logPixels =
			totalPixels <= 1 ? 0 : Int.bitWidth - (totalPixels - 1).leadingZeroBitCount
		let minGap = logPixels < 14 ? 8 * (14 - logPixels) : 0
		func build(_ begin: Int, _ end: Int) -> Draft {
			guard begin + minGap < end else { return .leaf(.weighted) }
			let split = (begin + end) / 2
			return .split(
				property: 15, threshold: wpCutoffs[split],
				greater: build(split + 1, end), notGreater: build(begin, split))
		}
		return build(0, wpCutoffs.count)
	}

	private static func metadataTree(totalPixels: Int, jpegTranscode: Bool) -> Draft {
		if jpegTranscode { return .leaf(.zero) }
		if totalPixels < 1024 { return .leaf(.left) }
		func build(_ index: Int) -> Draft {
			switch index {
			case 0:
				return .split(
					property: 0, threshold: 1, greater: build(1),
					notGreater: build(2))
			case 1:
				return .split(
					property: 0, threshold: 2, greater: build(3),
					notGreater: build(4))
			case 2:
				return .split(
					property: 0, threshold: 0, greater: build(5),
					notGreater: build(6))
			case 3:
				return .split(
					property: 6, threshold: 3, greater: build(21),
					notGreater: build(22))
			case 4:
				return .split(
					property: 2, threshold: 0, greater: build(7),
					notGreater: build(8))
			case 5, 6: return .leaf(.gradient)
			case 7:
				return .split(
					property: 7, threshold: 5, greater: build(9),
					notGreater: build(10))
			case 8:
				return .split(
					property: 7, threshold: 5, greater: build(15),
					notGreater: build(16))
			case 9:
				return .split(
					property: 7, threshold: 11, greater: build(11),
					notGreater: build(12))
			case 10:
				return .split(
					property: 7, threshold: 3, greater: build(13),
					notGreater: build(14))
			case 15:
				return .split(
					property: 7, threshold: 11, greater: build(17),
					notGreater: build(18))
			case 16:
				return .split(
					property: 7, threshold: 3, greater: build(19),
					notGreater: build(20))
			case 21:
				return .split(
					property: 7, threshold: 3, greater: build(23),
					notGreater: build(24))
			case 22:
				return .split(
					property: 7, threshold: 3, greater: build(25),
					notGreater: build(26))
			case 11, 12, 13, 14: return .leaf(.left)
			case 17, 18, 19, 20, 23, 24, 25, 26: return .leaf(.zero)
			default: preconditionFailure("invalid selected AC metadata node")
			}
		}
		return build(0)
	}

	private static func flatten(_ root: Draft, dcGroupCount: Int) -> Prepared {
		var nodes: [Node] = []
		var queue: [(Draft, Int)] = [(root, 0)]
		var cursor = 0
		var nextContext: UInt32 = 0
		while cursor < queue.count {
			let (draft, index) = queue[cursor]
			cursor += 1
			if nodes.count <= index {
				nodes += Array(
					repeating: .leaf(predictor: .zero, context: 0),
					count: index + 1 - nodes.count)
			}
			switch draft {
			case .leaf(let predictor):
				nodes[index] = .leaf(predictor: predictor, context: nextContext)
				nextContext += 1
			case .split(
				let property, let threshold, let greaterDraft, let notGreaterDraft):
				let greater = nodes.count
				nodes.append(.leaf(predictor: .zero, context: 0))
				let notGreater = nodes.count
				nodes.append(.leaf(predictor: .zero, context: 0))
				nodes[index] = .split(
					property: property, threshold: threshold,
					greater: greater, notGreater: notGreater)
				queue.append((greaterDraft, greater))
				queue.append((notGreaterDraft, notGreater))
			}
		}
		var tokens: [Token] = []
		for node in nodes {
			switch node {
			case .split(let property, let threshold, _, _):
				tokens.append(Token(context: 1, value: UInt32(property + 1)))
				tokens.append(Token(context: 0, value: packSigned(threshold)))
			case .leaf(let predictor, _):
				tokens.append(Token(context: 1, value: 0))
				tokens.append(Token(context: 2, value: predictor.rawValue))
				tokens.append(Token(context: 3, value: 0))
				tokens.append(Token(context: 4, value: 0))
				tokens.append(Token(context: 5, value: 0))
			}
		}
		return Prepared(
			nodes: nodes, tokens: tokens, contextCount: Int(nextContext),
			dcGroupCount: dcGroupCount)
	}

	static func write(
		_ prepared: Prepared, code: EntropyCode, writer: inout BitWriter
	) {
		writer.write(1, 1)
		writer.write(1, 0)
		EntropyCodeWriter.write(code, writer: &writer)
		EntropyCodeWriter.writeTokens(prepared.tokens, code: code, writer: &writer)
	}

	/// Contexts in the tree's own token stream.
	static let treeContextCount = 6

	private static func t(_ context: UInt32, _ value: UInt32) -> Token {
		Token(context: context, value: value)
	}

	/// The reference's fixed context tree, as a token stream.
	static let staticTokens: [Token] = [
		t(1, 2), t(0, 4), t(1, 1), t(0, 2), t(1, 10), t(0, 0),
		t(1, 1), t(0, 4), t(1, 1), t(0, 0), t(1, 10), t(0, 94),
		t(1, 10), t(0, 61), t(1, 0), t(2, 0), t(3, 0), t(4, 0),
		t(5, 0), t(1, 3), t(0, 0), t(1, 0), t(2, 5), t(3, 0),
		t(4, 0), t(5, 0), t(1, 0), t(2, 5), t(3, 0), t(4, 0),
		t(5, 0), t(1, 10), t(0, 382), t(1, 10), t(0, 22), t(1, 10),
		t(0, 13), t(1, 10), t(0, 253), t(1, 8), t(0, 10), t(1, 8),
		t(0, 10), t(1, 10), t(0, 784), t(1, 10), t(0, 190), t(1, 10),
		t(0, 46), t(1, 10), t(0, 10), t(1, 10), t(0, 5), t(1, 10),
		t(0, 29), t(1, 10), t(0, 125), t(1, 10), t(0, 509), t(1, 8),
		t(0, 22), t(1, 8), t(0, 6), t(1, 8), t(0, 22), t(1, 8),
		t(0, 6), t(1, 10), t(0, 1000), t(1, 10), t(0, 510), t(1, 10),
		t(0, 254), t(1, 10), t(0, 126), t(1, 10), t(0, 62), t(1, 10),
		t(0, 30), t(1, 10), t(0, 14), t(1, 10), t(0, 6), t(1, 10),
		t(0, 1), t(1, 10), t(0, 7), t(1, 10), t(0, 21), t(1, 10),
		t(0, 45), t(1, 10), t(0, 93), t(1, 10), t(0, 189), t(1, 10),
		t(0, 381), t(1, 10), t(0, 783), t(1, 0), t(2, 1), t(3, 0),
		t(4, 0), t(5, 0), t(1, 0), t(2, 1), t(3, 0), t(4, 0),
		t(5, 0), t(1, 0), t(2, 1), t(3, 0), t(4, 0), t(5, 0),
		t(1, 0), t(2, 1), t(3, 0), t(4, 0), t(5, 0), t(1, 0),
		t(2, 0), t(3, 0), t(4, 0), t(5, 0), t(1, 0), t(2, 0),
		t(3, 0), t(4, 0), t(5, 0), t(1, 0), t(2, 0), t(3, 0),
		t(4, 0), t(5, 0), t(1, 0), t(2, 0), t(3, 0), t(4, 0),
		t(5, 0), t(1, 0), t(2, 5), t(3, 0), t(4, 0), t(5, 0),
		t(1, 0), t(2, 5), t(3, 0), t(4, 0), t(5, 0), t(1, 0),
		t(2, 5), t(3, 0), t(4, 0), t(5, 0), t(1, 0), t(2, 5),
		t(3, 0), t(4, 0), t(5, 0), t(1, 0), t(2, 5), t(3, 0),
		t(4, 0), t(5, 0), t(1, 0), t(2, 5), t(3, 0), t(4, 0),
		t(5, 0), t(1, 0), t(2, 5), t(3, 0), t(4, 0), t(5, 0),
		t(1, 0), t(2, 5), t(3, 0), t(4, 0), t(5, 0), t(1, 0),
		t(2, 5), t(3, 0), t(4, 0), t(5, 0), t(1, 0), t(2, 5),
		t(3, 0), t(4, 0), t(5, 0), t(1, 0), t(2, 5), t(3, 0),
		t(4, 0), t(5, 0), t(1, 0), t(2, 5), t(3, 0), t(4, 0),
		t(5, 0), t(1, 0), t(2, 5), t(3, 0), t(4, 0), t(5, 0),
		t(1, 0), t(2, 5), t(3, 0), t(4, 0), t(5, 0), t(1, 0),
		t(2, 5), t(3, 0), t(4, 0), t(5, 0), t(1, 10), t(0, 2),
		t(1, 0), t(2, 5), t(3, 0), t(4, 0), t(5, 0), t(1, 0),
		t(2, 5), t(3, 0), t(4, 0), t(5, 0), t(1, 0), t(2, 5),
		t(3, 0), t(4, 0), t(5, 0), t(1, 0), t(2, 5), t(3, 0),
		t(4, 0), t(5, 0), t(1, 0), t(2, 5), t(3, 0), t(4, 0),
		t(5, 0), t(1, 0), t(2, 5), t(3, 0), t(4, 0), t(5, 0),
		t(1, 0), t(2, 5), t(3, 0), t(4, 0), t(5, 0), t(1, 0),
		t(2, 5), t(3, 0), t(4, 0), t(5, 0), t(1, 0), t(2, 5),
		t(3, 0), t(4, 0), t(5, 0), t(1, 0), t(2, 5), t(3, 0),
		t(4, 0), t(5, 0), t(1, 0), t(2, 5), t(3, 0), t(4, 0),
		t(5, 0), t(1, 0), t(2, 5), t(3, 0), t(4, 0), t(5, 0),
		t(1, 0), t(2, 5), t(3, 0), t(4, 0), t(5, 0), t(1, 0),
		t(2, 5), t(3, 0), t(4, 0), t(5, 0), t(1, 0), t(2, 5),
		t(3, 0), t(4, 0), t(5, 0), t(1, 10), t(0, 999), t(1, 0),
		t(2, 5), t(3, 0), t(4, 0), t(5, 0), t(1, 0), t(2, 5),
		t(3, 0), t(4, 0), t(5, 0), t(1, 0), t(2, 5), t(3, 0),
		t(4, 0), t(5, 0), t(1, 0), t(2, 5), t(3, 0), t(4, 0),
		t(5, 0),
	]

	/// Emits the tree. `tokens[1]` encodes how many DC groups follow, so the
	/// stream is patched rather than fully static.
	static func write(dcGroupCount: Int, writer: inout BitWriter) {
		var tokens = staticTokens
		tokens[1] = Token(
			context: tokens[1].context, value: packSigned(Int32(1 + dcGroupCount)))

		let code = HistogramCluster.optimizeEntropyCode(
			tokens: tokens, contextCount: treeContextCount)

		writer.write(1, 1)  // not an empty tree
		writer.write(1, 0)  // no lz77
		EntropyCodeWriter.write(code, writer: &writer)
		for token in tokens {
			writer.write(token: token, code: code)
		}
	}
}
