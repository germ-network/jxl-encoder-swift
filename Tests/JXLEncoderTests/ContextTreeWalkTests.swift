import Testing

@testable import JXLEncoder

/// The static context tree and the tables that shortcut it have to agree.
///
/// `DCPredictor.gradientContextLut` is a 1024-entry table standing in for a walk
/// of the tree, and `writePlane` predicts with a gradient unconditionally — both
/// shortcuts that hold only as long as the tree keeps its present shape. Nothing
/// checked either against the tree itself, so this decodes the transmitted token
/// stream back into a tree and walks it.
@Suite("Context tree walk")
struct ContextTreeWalkTests {
	enum Node {
		case leaf(predictor: Int)
		case split(property: Int, value: Int32, left: Int, right: Int)
	}

	/// Reconstructs the tree the way `DecodeTree` does, so the child indices land
	/// where the decoder expects: `size + to_decode + 1` and `+ 2`.
	static func decode(_ tokens: [Token]) -> [Node] {
		var nodes: [Node] = []
		var index = 0
		var toDecode = 1
		while toDecode > 0 {
			toDecode -= 1
			let property = Int(tokens[index].value) - 1
			index += 1
			if property == -1 {
				nodes.append(.leaf(predictor: Int(tokens[index].value)))
				index += 4  // predictor, offset, multiplier log, multiplier bits
			} else {
				// Inverse of `packSigned`.
				let packed = tokens[index].value
				let value = Int32(bitPattern: (packed >> 1) ^ (0 &- (packed & 1)))
				index += 1
				nodes.append(
					.split(
						property: property, value: value,
						left: nodes.count + toDecode + 1,
						right: nodes.count + toDecode + 2))
				toDecode += 2
			}
		}
		return nodes
	}

	/// Property 0 is the channel, 1 the group id, 2 the row, 9 the gradient.
	static func walk(
		_ nodes: [Node], channel: Int, group: Int, gradient: Int32, row: Int32 = 1
	) -> (context: Int, predictor: Int) {
		var index = 0
		var leaves = 0
		// Leaf ids are assigned in decode order, and the leaf id is the context.
		var contextOf: [Int: Int] = [:]
		for (i, node) in nodes.enumerated() {
			if case .leaf = node {
				contextOf[i] = leaves
				leaves += 1
			}
		}
		while true {
			switch nodes[index] {
			case .leaf(let predictor):
				return (contextOf[index]!, predictor)
			case .split(let property, let value, let left, let right):
				let actual: Int32 =
					switch property {
					case 0: Int32(channel)
					case 1: Int32(group)
					case 2: row
					case 9: gradient
					default: 0
					}
				index = actual > value ? left : right
			}
		}
	}

	static func tree(dcGroupCount: Int = 1) -> [Node] {
		var tokens = ContextTree.staticTokens
		tokens[1] = Token(
			context: tokens[1].context,
			value: packSigned(Int32(1 + dcGroupCount)))
		return decode(tokens)
	}

	/// The whole 1024-entry table, against the tree, for every channel.
	@Test("the DC context table matches a tree walk", arguments: 0..<3)
	func lutMatchesTree(channel: Int) {
		let nodes = Self.tree()
		var mismatches = 0
		for index in 0..<1024 {
			let gradient = Int32(index - DCPredictor.gradRangeMid)
			let walked = Self.walk(
				nodes, channel: channel, group: 0, gradient: gradient)
			if Int(DCPredictor.gradientContextLut[index]) != walked.context {
				mismatches += 1
			}
		}
		#expect(mismatches == 0)
	}

	/// The DC context does not depend on the channel, which is why one table
	/// serves all three and why `writeDCTokens` passes the same closure for each.
	/// The channel splits in the tree belong to the AC-metadata subtree, where
	/// four channels genuinely need telling apart.
	@Test("DC contexts are channel-independent")
	func dcIgnoresChannel() {
		let nodes = Self.tree()
		for index in stride(from: 0, to: 1024, by: 7) {
			let gradient = Int32(index - DCPredictor.gradRangeMid)
			let contexts = (0..<3).map {
				Self.walk(nodes, channel: $0, group: 0, gradient: gradient).context
			}
			#expect(Set(contexts).count == 1)
		}
	}

	/// `writePlane` always predicts with a gradient. That is only right because
	/// every leaf the DC subtree can reach says Gradient; the AC-metadata subtree
	/// mixes three predictors, and its writers handle each explicitly.
	@Test("the DC subtree only ever asks for gradient prediction")
	func dcPredictorIsGradient() {
		let nodes = Self.tree()
		var predictors: Set<Int> = []
		for channel in 0..<3 {
			for index in 0..<1024 {
				for row in Int32(0)...1 {
					predictors.insert(
						Self.walk(
							nodes, channel: channel, group: 0,
							gradient: Int32(
								index - DCPredictor.gradRangeMid),
							row: row
						).predictor)
				}
			}
		}
		// Predictor 5 is Gradient in libjxl's modular predictor enum.
		#expect(predictors == [5])
	}

	/// The fixed contexts `writeACMetadataTokens` uses for the colour-correlation
	/// maps come from the tree's channel split, not from anywhere else.
	@Test("AC metadata channels get the contexts the writer assumes")
	func acMetadataChannels() {
		let nodes = Self.tree()
		// A group id past the DC groups selects the AC-metadata subtree.
		#expect(Self.walk(nodes, channel: 0, group: 99, gradient: 0).context == 2)
		#expect(Self.walk(nodes, channel: 1, group: 99, gradient: 0).context == 1)
		#expect(Self.walk(nodes, channel: 3, group: 99, gradient: 0).context == 0)
	}
}
