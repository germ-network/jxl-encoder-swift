//
//  HuffmanTree.swift
//  JXLEncoder
//
//  Port of libjxl-tiny's encoder/enc_huffman_tree.cc and the bit-depth to
//  symbol conversion from encoder/enc_entropy_code.cc.
//
//  Needed even with static prefix-code tables: the context map and the modular
//  context tree build codes for their own token streams.
//

enum HuffmanTree {
	/// Maximum depth for a code-length code tree, per the format.
	static let codeLengthCodes = 18

	private struct Node {
		var totalCount: UInt32
		var indexLeft: Int
		var indexRightOrValue: Int
	}

	/// Builds a Huffman code from population counts, capped at `treeLimit` bits.
	///
	/// The cap is enforced by retrying with progressively raised minimum counts,
	/// which flattens the tree. `depth[i] == 0` means symbol `i` is unused.
	static func createTree(
		counts: [UInt32], length: Int, treeLimit: Int
	) -> [UInt8] {
		var depth = [UInt8](repeating: 0, count: length)

		var countLimit: UInt32 = 1
		while true {
			var tree: [Node] = []
			tree.reserveCapacity(2 * length + 1)

			// Built back to front so equal counts keep the reference's ordering
			// through the stable sort below.
			var i = length
			while i != 0 {
				i -= 1
				if counts[i] != 0 {
					tree.append(
						Node(
							totalCount: max(counts[i], countLimit - 1),
							indexLeft: -1, indexRightOrValue: i))
				}
			}

			let n = tree.count
			if n == 1 {
				// Fixed up by the caller one level higher.
				depth[tree[0].indexRightOrValue] = 1
				break
			}

			// Swift's sort is not stable, so sort on (count, original position).
			let enumerated = tree.enumerated().sorted {
				$0.element.totalCount != $1.element.totalCount
					? $0.element.totalCount < $1.element.totalCount
					: $0.offset < $1.offset
			}
			tree = enumerated.map(\.element)

			// Layout: [0, n) sorted leaves, [n] sentinel, [n+1, 2n) parents in
			// ascending order, [2n] sentinel.
			let sentinel = Node(
				totalCount: UInt32.max, indexLeft: -1, indexRightOrValue: -1)
			tree.append(sentinel)
			tree.append(sentinel)

			var leaf = 0
			var parent = n + 1
			for _ in stride(from: n - 1, to: 0, by: -1) {
				let left: Int
				if tree[leaf].totalCount <= tree[parent].totalCount {
					left = leaf
					leaf += 1
				} else {
					left = parent
					parent += 1
				}
				let right: Int
				if tree[leaf].totalCount <= tree[parent].totalCount {
					right = leaf
					leaf += 1
				} else {
					right = parent
					parent += 1
				}

				// The trailing sentinel becomes this parent node.
				let end = tree.count - 1
				tree[end].totalCount =
					tree[left].totalCount + tree[right].totalCount
				tree[end].indexLeft = left
				tree[end].indexRightOrValue = right
				tree.append(sentinel)
			}

			setDepth(tree[2 * n - 1], pool: tree, depth: &depth, level: 0)

			if depth.max() ?? 0 <= UInt8(treeLimit) { break }
			countLimit *= 2
		}
		return depth
	}

	private static func setDepth(
		_ node: Node, pool: [Node], depth: inout [UInt8], level: UInt8
	) {
		guard node.indexLeft >= 0 else {
			depth[node.indexRightOrValue] = level
			return
		}
		let next = level + 1
		setDepth(pool[node.indexLeft], pool: pool, depth: &depth, level: next)
		setDepth(pool[node.indexRightOrValue], pool: pool, depth: &depth, level: next)
	}

	static func reverseBits(_ numBits: Int, _ bits: UInt16) -> UInt16 {
		// Pre-reversed nibbles.
		let lut: [UInt16] = [
			0x0, 0x8, 0x4, 0xC, 0x2, 0xA, 0x6, 0xE,
			0x1, 0x9, 0x5, 0xD, 0x3, 0xB, 0x7, 0xF,
		]
		var value = bits
		var result = UInt32(lut[Int(value & 0xF)])
		var i = 4
		while i < numBits {
			result <<= 4
			value >>= 4
			result |= UInt32(lut[Int(value & 0xF)])
			i += 4
		}
		result >>= UInt32((-numBits) & 0x3)
		return UInt16(truncatingIfNeeded: result)
	}

	/// Assigns canonical codes to the symbols of a depth table.
	static func convertBitDepthsToSymbols(depth: [UInt8], length: Int) -> [UInt16] {
		let maxBits = 16
		var lengthCount = [UInt16](repeating: 0, count: maxBits)
		for i in 0..<length { lengthCount[Int(depth[i])] += 1 }
		lengthCount[0] = 0

		var nextCode = [UInt16](repeating: 0, count: maxBits)
		var code = 0
		for i in 1..<maxBits {
			code = (code + Int(lengthCount[i - 1])) << 1
			nextCode[i] = UInt16(truncatingIfNeeded: code)
		}

		var bits = [UInt16](repeating: 0, count: length)
		for i in 0..<length where depth[i] != 0 {
			let d = Int(depth[i])
			bits[i] = reverseBits(d, nextCode[d])
			nextCode[d] += 1
		}
		return bits
	}
}
