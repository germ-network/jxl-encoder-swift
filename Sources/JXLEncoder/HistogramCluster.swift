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
	/// Cached Shannon entropy in bits; recomputed explicitly after mutation.
	var bitCost: Float = 0

	mutating func add(_ symbol: UInt32) {
		let index = Int(symbol)
		if index >= counts.count {
			counts += [UInt32](
				repeating: 0, count: ((index + 8) / 8) * 8 - counts.count)
		}
		counts[index] += 1
		totalCount += 1
	}

	mutating func add(_ other: Histogram) {
		if counts.count < other.counts.count {
			counts += [UInt32](repeating: 0, count: other.counts.count - counts.count)
		}
		for i in other.counts.indices { counts[i] += other.counts[i] }
		totalCount += other.totalCount
	}

	/// Shannon entropy. `lanes` accumulates in the four lanes libjxl's vector
	/// loop uses, so near-tied distances break the same way; otherwise the sum
	/// runs left to right.
	mutating func computeBitCost(lanes useLanes: Bool = false) {
		bitCost = 0
		guard totalCount != 0 else { return }
		let total = Float(totalCount)
		let inverseTotal = 1.0 / total
		var cost: Float = 0
		var lanes = SIMD4<Float>(repeating: 0)
		for i in counts.indices {
			let count = counts[i]
			precondition(count <= UInt32(Int32.max))
			let value = Float(count)
			if count == 0 || value == total { continue }
			let term = -(value * FastMath.log2(inverseTotal * value))
			if useLanes { lanes[i & 3] += term } else { cost += term }
		}
		bitCost = useLanes ? (lanes[0] + lanes[1]) + (lanes[2] + lanes[3]) : cost
	}
}

extension Histogram {
	/// libjxl `Histogram::Flat(alphabetSize, 4096)`: the fixed histogram a
	/// streaming frame's first DC group prepends (enc_ans.cc:1187-1213).
	static func flat(alphabetSize: Int) -> Histogram {
		let total = 4096
		precondition(alphabetSize > 0 && alphabetSize <= total)
		var histogram = Histogram()
		histogram.counts = (0..<alphabetSize).map {
			UInt32(total / alphabetSize + ($0 < total % alphabetSize ? 1 : 0))
		}
		histogram.totalCount = total
		return histogram
	}

	/// libjxl `HistogramFromSymbolInfo` (enc_ans.cc ~692-707): what an
	/// already-encoded histogram looks like to later clustering — ANS
	/// normalized frequencies, or `2^(15 - depth)` per prefix-coded symbol.
	init(encodedANS histogram: ANSEncodingHistogram) {
		counts = histogram.normalizedCounts.map { UInt32($0) }
		totalCount = histogram.normalizedCounts.reduce(0, +)
	}

	init(encodedPrefix code: PrefixCode) {
		// libjxl gives a lone symbol depth 0, so it reads back empty.
		counts =
			code.isDegenerate
			? code.depths.map { _ in 0 }
			: code.depths.map { $0 == 0 ? 0 : UInt32(1) << UInt32(15 - Int($0)) }
		totalCount = counts.reduce(0) { $0 + Int($1) }
	}
}

enum HistogramCluster {
	/// Merging two contexts costs the difference between the combined code and
	/// the two separate ones.
	static func distance(_ a: Histogram, _ b: Histogram, lanes: Bool = false) -> Float {
		guard a.totalCount != 0, b.totalCount != 0 else { return 0 }
		var combined = Histogram()
		combined.add(a)
		combined.add(b)
		combined.computeBitCost(lanes: lanes)
		return Float(combined.bitCost - a.bitCost - b.bitCost)
	}

	static let clustersLimit = 128
	static let minDistanceForDistinct: Float = 48.0

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

		var largest = input.firstIndex(where: { $0.totalCount > 0 }) ?? 0
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
			var bestDistance = Float.greatestFiniteMagnitude
			for j in 0..<output.count {
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

	/// libjxl `FastClusterHistograms` with `prev_histograms` (enc_cluster.cc:136-210):
	/// streaming DC groups extend the clusters earlier DC groups already
	/// encoded. Symbols index `previous` first, then the new clusters; only
	/// new clusters absorb counts, since earlier ones are already transmitted.
	/// The returned `clusters` are the new ones only.
	static func fastCluster(
		_ input: [Histogram], maxHistograms: Int, previous: [Histogram]
	) -> (clusters: [Histogram], symbols: [UInt32]) {
		guard !previous.isEmpty else {
			return fastCluster(input, maxHistograms: maxHistograms)
		}
		var input = input
		var previous = previous
		for i in previous.indices { previous[i].computeBitCost(lanes: true) }
		let unassigned = UInt32.max
		var output: [Histogram] = []
		var symbols = [UInt32](repeating: unassigned, count: input.count)
		var dists = [Float](repeating: .greatestFiniteMagnitude, count: input.count)

		var largest = 0
		for i in 0..<input.count {
			if input[i].totalCount == 0 {
				symbols[i] = 0
				dists[i] = 0
				continue
			}
			input[i].computeBitCost(lanes: true)
			if input[i].totalCount > input[largest].totalCount { largest = i }
		}
		for i in 0..<input.count where dists[i] != 0 {
			for old in previous {
				dists[i] = min(klDivergence(input[i], coding: old), dists[i])
			}
		}
		if let farthest = dists.indices.max(by: { dists[$0] < dists[$1] }),
			dists[farthest] > 0
		{
			largest = farthest
		}

		while output.count < maxHistograms {
			symbols[largest] = UInt32(previous.count + output.count)
			output.append(input[largest])
			dists[largest] = 0
			largest = 0
			for i in 0..<input.count where dists[i] != 0 {
				let d = distance(input[i], output[output.count - 1], lanes: true)
				dists[i] = min(d, dists[i])
				if dists[i] > dists[largest] { largest = i }
			}
			if dists[largest] < minDistanceForDistinct { break }
		}

		for i in 0..<input.count where symbols[i] == unassigned {
			var best = 0
			var bestDistance = Float.greatestFiniteMagnitude
			for j in 0..<(previous.count + output.count) {
				let d =
					j < previous.count
					? klDivergence(input[i], coding: previous[j])
					: distance(
						input[i], output[j - previous.count], lanes: true)
				if d < bestDistance {
					best = j
					bestDistance = d
				}
			}
			if best >= previous.count {
				output[best - previous.count].add(input[i])
				output[best - previous.count].computeBitCost(lanes: true)
			}
			symbols[i] = UInt32(best)
		}
		return (output, symbols)
	}

	/// libjxl `HistogramKLDivergence` (enc_cluster.cc:108-133): bits lost coding
	/// `actual` with a code already fitted to `coding`.
	static func klDivergence(_ actual: Histogram, coding: Histogram) -> Float {
		guard actual.totalCount != 0 else { return 0 }
		guard coding.totalCount != 0 else { return .infinity }
		var actual = actual
		actual.computeBitCost(lanes: true)
		let inverseTotal = 1.0 / Float(coding.totalCount)
		var lanes = SIMD4<Float>(repeating: 0)
		for i in actual.counts.indices where actual.counts[i] != 0 {
			let codingCount = i < coding.counts.count ? coding.counts[i] : 0
			if codingCount == 0 { return .infinity }
			lanes[i & 3] = lanes[i & 3].addingProduct(
				-Float(actual.counts[i]),
				FastMath.log2(Float(codingCount) * inverseTotal))
		}
		let cost = (lanes[0] + lanes[1]) + (lanes[2] + lanes[3])
		return cost - actual.bitCost
	}

	static func clusterBest(_ histograms: [Histogram]) -> (
		clusters: [Histogram], contextMap: [UInt8]
	) {
		guard histograms.count > 1 else {
			return (histograms, [UInt8](repeating: 0, count: histograms.count))
		}
		var (clusters, symbols) = fastCluster(
			histograms, maxHistograms: histograms.count)
		var costs = clusters.map {
			ANSEncodingHistogram.computeBest(counts: $0.counts, strategy: .fast).cost
		}
		var versions = [UInt32](repeating: 1, count: clusters.count)
		var renumbering = Array(clusters.indices)
		var nextVersion: UInt32 = 2
		var pairs: [(cost: Float, first: Int, second: Int, version: UInt32)] = []
		func mergeCost(_ first: Int, _ second: Int) -> Float {
			var combined = clusters[first]
			combined.add(clusters[second])
			let combinedCost = ANSEncodingHistogram.computeBest(
				counts: combined.counts, strategy: .fast
			).cost
			return combinedCost - (costs[first] + costs[second])
		}
		func enqueue(_ first: Int, _ second: Int) {
			let cost = mergeCost(first, second)
			guard cost < 0 else { return }
			pairs.append(
				(
					cost, min(first, second), max(first, second),
					max(versions[first], versions[second])
				))
		}
		for first in clusters.indices {
			for second in clusters.indices where second > first {
				enqueue(first, second)
			}
		}
		while !pairs.isEmpty {
			pairs.sort {
				if $0.cost != $1.cost { return $0.cost < $1.cost }
				if $0.first != $1.first { return $0.first < $1.first }
				if $0.second != $1.second { return $0.second < $1.second }
				return $0.version < $1.version
			}
			let pair = pairs.removeFirst()
			let first = pair.first
			let second = pair.second
			guard versions[first] != 0, versions[second] != 0,
				pair.version == max(versions[first], versions[second])
			else { continue }
			clusters[first].add(clusters[second])
			costs[first] =
				ANSEncodingHistogram.computeBest(
					counts: clusters[first].counts, strategy: .fast
				).cost
			for index in renumbering.indices where renumbering[index] == second {
				renumbering[index] = first
			}
			versions[second] = 0
			versions[first] = nextVersion
			nextVersion += 1
			for other in clusters.indices where other != first && versions[other] != 0 {
				enqueue(first, other)
			}
		}
		var reverse = [Int](repeating: -1, count: clusters.count)
		var alive: [Histogram] = []
		for index in clusters.indices where versions[index] != 0 {
			reverse[index] = alive.count
			alive.append(clusters[index])
		}
		for index in renumbering.indices {
			renumbering[index] = reverse[renumbering[index]]
		}
		symbols = symbols.map { UInt32(renumbering[Int($0)]) }
		return reindex(symbols: symbols, clusters: alive)
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

	/// `reindex` for clusters that extend `previousCount` earlier ones: symbols
	/// below it keep their index, new clusters renumber by first use after
	/// them (libjxl `HistogramReindex`, enc_cluster.cc:234-256).
	static func reindex(
		symbols: [UInt32], clusters: [Histogram], previousCount: Int
	) -> (clusters: [Histogram], contextMap: [UInt8]) {
		var reordered: [Histogram] = []
		var newIndex: [UInt32: Int] = [:]
		for symbol in symbols where Int(symbol) >= previousCount {
			guard newIndex[symbol] == nil else { continue }
			newIndex[symbol] = previousCount + reordered.count
			reordered.append(clusters[Int(symbol) - previousCount])
		}
		return (
			reordered,
			symbols.map { UInt8(Int($0) < previousCount ? Int($0) : newIndex[$0]!) }
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
			var length = histogram.counts.count
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
						count: histogram.counts.count - length),
				bits: bits
					+ [UInt16](
						repeating: 0,
						count: histogram.counts.count - length))
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
