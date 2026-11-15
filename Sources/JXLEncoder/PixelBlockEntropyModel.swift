enum PixelBlockEntropyModel {
	static func compute(
		quantCounts: [Int], params: DistanceParams
	) -> JPEGBlockContextMap.Result {
		precondition(quantCounts.count == 256)
		precondition(quantCounts.allSatisfy { $0 >= 0 })
		let total = quantCounts.reduce(0, +)
		precondition(total > 0)

		let modelSize = Int(Float(1 << 10) * params.distance)
		if total < modelSize {
			return JPEGBlockContextMap.Result.pixelDefault
		}

		let splitSize = Int(Float(1 << 13) * params.distance)
		let segments = total < splitSize ? 1 : 2
		var thresholds: [UInt32] = []
		var cumulative = 0
		var next = 1
		var lastCut = 256
		var cut = total * next / segments
		for quant in 0..<256 {
			cumulative += quantCounts[quant]
			if cumulative > cut {
				if quant != 0 { thresholds.append(UInt32(quant)) }
				lastCut = quant
				while cumulative > cut {
					next += 1
					cut = total * next / segments
				}
			} else if next > thresholds.count + 1,
				quant > 0, quant - 1 == lastCut
			{
				thresholds.append(UInt32(quant))
			}
		}

		let segmentCount = thresholds.count + 1
		var counts = [Int](
			repeating: 0, count: JPEGBlockContextMap.numOrders * segmentCount)
		var segment = 0
		for quant in 0..<256 {
			if segment < thresholds.count, quant == Int(thresholds[segment]) {
				segment += 1
			}
			counts[segment] += quantCounts[quant]
		}

		var remap = Array(0..<counts.count)
		var clusters = remap
		let lumaClusters = clamp1(total / modelSize / 2, 2, 9)
		let chromaClusters = clamp1(total / modelSize / 3, 1, 5)
		while clusters.count > lumaClusters {
			clusters.sort { counts[$0] > counts[$1] }
			counts[clusters[clusters.count - 2]] += counts[clusters[clusters.count - 1]]
			counts[clusters[clusters.count - 1]] = 0
			remap[clusters[clusters.count - 1]] = clusters[clusters.count - 2]
			clusters.removeLast()
		}
		for index in remap.indices {
			while remap[remap[index]] != remap[index] {
				remap[index] = remap[remap[index]]
			}
		}
		var labels = [Int](repeating: remap.count, count: remap.count)
		var number = 0
		for index in remap.indices {
			if labels[remap[index]] == remap.count {
				labels[remap[index]] = number
				number += 1
			}
			remap[index] = labels[remap[index]]
		}

		var map = remap.map(UInt8.init)
		for index in remap.count..<(remap.count * 3) {
			map.append(
				UInt8(
					number
						+ clamp1(
							Int(remap[index % remap.count]), 0,
							chromaClusters - 1)))
		}
		return JPEGBlockContextMap.Result(
			thresholds: [], qfThresholds: thresholds,
			contextMap: map, numContexts: Int(map.max() ?? 0) + 1)
	}
}
