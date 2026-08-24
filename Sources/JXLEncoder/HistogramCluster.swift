//
//  HistogramCluster.swift
//  JXLEncoder
//
//  Port of libjxl-tiny's encoder/enc_cluster.cc and the histogram helpers from
//  encoder/enc_entropy_code.cc.
//
//  Contexts are clustered so that several of them can share one prefix code:
//  every distinct code costs header bytes, so merging contexts with similar
//  statistics is usually a net win. Needed even with static coefficient tables,
//  because the modular context tree builds a code for its own token stream.
//

struct Histogram {
	var counts = [UInt32](repeating: 0, count: StaticEntropyCodes.alphabetSize)
	var totalCount = 0
	/// Cached cost in bits; recomputed explicitly, not maintained on mutation.
	var bitCost = 0

	mutating func add(_ symbol: UInt32) {
		counts[Int(symbol)] += 1
		totalCount += 1
	}

	mutating func add(_ other: Histogram) {
		for i in 0..<StaticEntropyCodes.alphabetSize { counts[i] += other.counts[i] }
		totalCount += other.totalCount
	}

	/// Bits this histogram would take under its own optimal Huffman code.
	mutating func computeBitCost() {
		bitCost = 0
		guard totalCount != 0 else { return }
		let depths = HuffmanTree.createTree(
			counts: counts, length: StaticEntropyCodes.alphabetSize, treeLimit: 15)
		for i in 0..<StaticEntropyCodes.alphabetSize {
			bitCost += Int(counts[i]) * Int(depths[i])
		}
	}
}

enum HistogramCluster {
	/// Merging two contexts costs the difference between the combined code and
	/// the two separate ones.
	static func distance(_ a: Histogram, _ b: Histogram) -> Float {
		guard a.totalCount != 0, b.totalCount != 0 else { return 0 }
		var combined = Histogram()
		combined.add(a)
		combined.add(b)
		combined.computeBitCost()
		return Float(combined.bitCost - a.bitCost - b.bitCost)
	}

	static let clustersLimit = 8
	static let minDistanceForDistinct: Float = 64.0

	/// One pass of k-means-style clustering: repeatedly promote the histogram
	/// furthest from every existing cluster, then assign the remainder.
	static func fastCluster(
		_ input: [Histogram], maxHistograms: Int
	) -> (clusters: [Histogram], symbols: [UInt32]) {
		var input = input
		var output: [Histogram] = []
		output.reserveCapacity(maxHistograms)
		var symbols = [UInt32](repeating: UInt32(maxHistograms), count: input.count)
		var dists = [Float](repeating: .greatestFiniteMagnitude, count: input.count)

		var largest = 0
		for i in 0..<input.count {
			if input[i].totalCount == 0 {
				symbols[i] = 0
				dists[i] = 0
				continue
			}
			input[i].computeBitCost()
			if input[i].totalCount > input[largest].totalCount { largest = i }
		}

		while output.count < maxHistograms {
			symbols[largest] = UInt32(output.count)
			output.append(input[largest])
			dists[largest] = 0
			largest = 0
			for i in 0..<input.count where dists[i] != 0 {
				let d = distance(input[i], output[output.count - 1])
				dists[i] = min(d, dists[i])
				if dists[i] > dists[largest] { largest = i }
			}
			if dists[largest] < minDistanceForDistinct { break }
		}

		for i in 0..<input.count where symbols[i] == UInt32(maxHistograms) {
			var best = 0
			var bestDistance = distance(input[i], output[0])
			for j in 1..<output.count {
				let d = distance(input[i], output[j])
				if d < bestDistance {
					best = j
					bestDistance = d
				}
			}
			output[best].add(input[i])
			output[best].computeBitCost()
			symbols[i] = UInt32(best)
		}
		return (output, symbols)
	}

	/// Renumbers clusters so the context map's symbols appear in increasing
	/// order, which is the canonical form the format expects.
	static func reindex(
		symbols: [UInt32], clusters: [Histogram]
	) -> (clusters: [Histogram], contextMap: [UInt8]) {
		var reordered = clusters
		var newIndex: [UInt32: Int] = [:]
		var next = 0
		for symbol in symbols where newIndex[symbol] == nil {
			newIndex[symbol] = next
			reordered[next] = clusters[Int(symbol)]
			next += 1
		}
		return (
			Array(reordered.prefix(next)),
			symbols.map { UInt8(newIndex[$0]!) }
		)
	}

	static func cluster(
		_ histograms: [Histogram], limit: Int = clustersLimit
	) -> (clusters: [Histogram], contextMap: [UInt8]) {
		guard histograms.count > 1 else {
			return (histograms, [UInt8](repeating: 0, count: histograms.count))
		}
		let maxHistograms = min(limit, histograms.count)
		let (clusters, symbols) = fastCluster(histograms, maxHistograms: maxHistograms)
		return reindex(symbols: symbols, clusters: clusters)
	}

	static func buildHistograms(
		tokens: [Token], contextMap: [UInt8]?, contextCount: Int
	) -> [Histogram] {
		var histograms = [Histogram](repeating: Histogram(), count: contextCount)
		for token in tokens {
			let (symbol, _, _) = UintCoder.encode(token.value)
			var context = Int(token.context)
			if let contextMap { context = Int(contextMap[context]) }
			histograms[context].add(symbol)
		}
		return histograms
	}

	static func buildPrefixCodes(_ histograms: [Histogram]) -> [PrefixCode] {
		histograms.map { histogram in
			var length = StaticEntropyCodes.alphabetSize
			while length > 0 && histogram.counts[length - 1] == 0 { length -= 1 }
			let depths = HuffmanTree.createTree(
				counts: histogram.counts, length: length, treeLimit: 15)
			let bits = HuffmanTree.convertBitDepthsToSymbols(
				depth: depths, length: length)
			// The alphabet is fixed width even when the code uses fewer symbols.
			return PrefixCode(
				depths: depths
					+ [UInt8](
						repeating: 0,
						count: StaticEntropyCodes.alphabetSize - length),
				bits: bits
					+ [UInt16](
						repeating: 0,
						count: StaticEntropyCodes.alphabetSize - length))
		}
	}

	/// Builds codes for a fixed context map — no clustering.
	static func optimizePrefixCodes(
		tokens: [Token], contextMap: [UInt8], prefixCodeCount: Int
	) -> EntropyCode {
		let histograms = buildHistograms(
			tokens: tokens, contextMap: contextMap, contextCount: prefixCodeCount)
		return EntropyCode(
			contextMap: contextMap, prefixCodes: buildPrefixCodes(histograms))
	}

	/// Clusters contexts and builds a code per cluster.
	static func optimizeEntropyCode(tokens: [Token], contextCount: Int) -> EntropyCode {
		let histograms = buildHistograms(
			tokens: tokens, contextMap: nil, contextCount: contextCount)
		let (clusters, contextMap) = cluster(histograms)
		return EntropyCode(
			contextMap: contextMap, prefixCodes: buildPrefixCodes(clusters))
	}
}
