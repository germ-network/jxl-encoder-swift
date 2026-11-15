// This file contains a modified Swift translation of libc++ sort.h's bounded
// ordinary-sort path. Licensed under Apache-2.0 WITH LLVM-exception; see
// Reference/LLVM-LICENSE.txt and Reference/NOTICE.

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
			LibcxxBoundedSort.sort(&clusters, counts: counts)
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

enum LibcxxBoundedSort {
	static func less(_ a: Int, _ b: Int, _ counts: [Int]) -> Bool { counts[a] > counts[b] }
	static func swap(_ a: Int, _ b: Int, _ values: inout [Int]) { values.swapAt(a, b) }

	static func sort3(_ a: Int, _ b: Int, _ c: Int, _ v: inout [Int], _ n: [Int]) {
		if !less(v[b], v[a], n) {
			if !less(v[c], v[b], n) { return }
			swap(b, c, &v)
			if less(v[b], v[a], n) { swap(a, b, &v) }
			return
		}
		if less(v[c], v[b], n) {
			swap(a, c, &v)
			return
		}
		swap(a, b, &v)
		if less(v[c], v[b], n) { swap(b, c, &v) }
	}

	static func sort4(_ a: Int, _ b: Int, _ c: Int, _ d: Int, _ v: inout [Int], _ n: [Int]) {
		sort3(a, b, c, &v, n)
		if less(v[d], v[c], n) {
			swap(c, d, &v)
			if less(v[c], v[b], n) {
				swap(b, c, &v)
				if less(v[b], v[a], n) { swap(a, b, &v) }
			}
		}
	}

	static func sort5(
		_ a: Int, _ b: Int, _ c: Int, _ d: Int, _ e: Int, _ v: inout [Int], _ n: [Int]
	) {
		sort4(a, b, c, d, &v, n)
		if less(v[e], v[d], n) {
			swap(d, e, &v)
			if less(v[d], v[c], n) {
				swap(c, d, &v)
				if less(v[c], v[b], n) {
					swap(b, c, &v)
					if less(v[b], v[a], n) { swap(a, b, &v) }
				}
			}
		}
	}

	static func insertion(_ first: Int, _ last: Int, _ v: inout [Int], _ n: [Int]) {
		guard first < last else { return }
		var i = first + 1
		while i < last {
			var j = i - 1
			if less(v[i], v[j], n) {
				let value = v[i]
				var source = j
				j = i
				repeat {
					v[j] = v[source]
					j = source
					if j == first { break }
					source -= 1
				} while less(value, v[source], n)
				v[j] = value
			}
			i += 1
		}
	}

	static func unguardedInsertion(_ first: Int, _ last: Int, _ v: inout [Int], _ n: [Int]) {
		guard first < last else { return }
		precondition(first > 0)
		var i = first + 1
		while i < last {
			var source = i - 1
			if less(v[i], v[source], n) {
				let value = v[i]
				var destination = i
				repeat {
					v[destination] = v[source]
					destination = source
					source -= 1
				} while less(value, v[source], n)
				v[destination] = value
			}
			i += 1
		}
	}

	static func incomplete(_ first: Int, _ last: Int, _ v: inout [Int], _ n: [Int]) -> Bool {
		let count = last - first
		if count <= 1 { return true }
		if count == 2 {
			if less(v[first + 1], v[first], n) { swap(first, first + 1, &v) }
			return true
		}
		if count == 3 {
			sort3(first, first + 1, first + 2, &v, n)
			return true
		}
		if count == 4 {
			sort4(first, first + 1, first + 2, first + 3, &v, n)
			return true
		}
		if count == 5 {
			sort5(first, first + 1, first + 2, first + 3, first + 4, &v, n)
			return true
		}
		var previous = first + 2
		sort3(first, first + 1, previous, &v, n)
		var moved = 0
		for i in (previous + 1)..<last {
			if less(v[i], v[previous], n) {
				let value = v[i]
				var source = previous
				var destination = i
				repeat {
					v[destination] = v[source]
					destination = source
					if destination == first { break }
					source -= 1
				} while less(value, v[source], n)
				v[destination] = value
				moved += 1
				if moved == 8 { return i + 1 == last }
			}
			previous = i
		}
		return true
	}

	static func partitionRight(_ first: Int, _ last: Int, _ v: inout [Int], _ n: [Int]) -> (
		Int, Bool
	) {
		let pivot = v[first]
		var left = first + 1
		while less(v[left], pivot, n) { left += 1 }
		var right = last
		if left == first + 1 {
			while left < right {
				right -= 1
				if less(v[right], pivot, n) { break }
			}
		} else {
			repeat { right -= 1 } while !less(v[right], pivot, n)
		}
		let already = left >= right
		while left < right {
			swap(left, right, &v)
			repeat { left += 1 } while less(v[left], pivot, n)
			repeat { right -= 1 } while !less(v[right], pivot, n)
		}
		let pivotIndex = left - 1
		if pivotIndex != first { v[first] = v[pivotIndex] }
		v[pivotIndex] = pivot
		return (pivotIndex, already)
	}

	static func partitionLeft(_ first: Int, _ last: Int, _ v: inout [Int], _ n: [Int]) -> Int {
		let pivot = v[first]
		var left = first
		if less(pivot, v[last - 1], n) {
			repeat { left += 1 } while !less(pivot, v[left], n)
		} else {
			repeat { left += 1 } while left < last && !less(pivot, v[left], n)
		}
		var right = last
		if left < last { repeat { right -= 1 } while less(pivot, v[right], n) }
		while left < right {
			swap(left, right, &v)
			repeat { left += 1 } while !less(pivot, v[left], n)
			repeat { right -= 1 } while less(pivot, v[right], n)
		}
		let pivotIndex = left - 1
		if pivotIndex != first { v[first] = v[pivotIndex] }
		v[pivotIndex] = pivot
		return left
	}

	static func introsort(
		_ first: Int, _ end: Int, _ initialDepth: Int, _ leftmost: Bool, _ v: inout [Int],
		_ n: [Int]
	) {
		var first = first
		var end = end
		var depth = initialDepth
		var isLeftmost = leftmost
		while true {
			let length = end - first
			switch length {
			case 0, 1: return
			case 2:
				if less(v[end - 1], v[first], n) { swap(first, end - 1, &v) }
				return
			case 3:
				sort3(first, first + 1, end - 1, &v, n)
				return
			case 4:
				sort4(first, first + 1, first + 2, end - 1, &v, n)
				return
			case 5:
				sort5(first, first + 1, first + 2, first + 3, end - 1, &v, n)
				return
			default: break
			}
			if length < 24 {
				if isLeftmost {
					insertion(first, end, &v, n)
				} else {
					unguardedInsertion(first, end, &v, n)
				}
				return
			}
			depth -= 1
			let half = length / 2
			sort3(first + half, first, end - 1, &v, n)
			if !isLeftmost && !less(v[first - 1], v[first], n) {
				first = partitionLeft(first, end, &v, n)
				continue
			}
			let (pivot, already) = partitionRight(first, end, &v, n)
			if already {
				let leftSorted = incomplete(first, pivot, &v, n)
				if incomplete(pivot + 1, end, &v, n) {
					if leftSorted { return }
					end = pivot
					continue
				} else if leftSorted {
					first = pivot + 1
					isLeftmost = false
					continue
				}
			}
			introsort(first, pivot, depth, isLeftmost, &v, n)
			isLeftmost = false
			first = pivot + 1
		}
	}

	static func sort(_ values: inout [Int], counts: [Int]) {
		precondition(values.count <= 26)
		let depth =
			values.isEmpty
			? 0 : 2 * (Int.bitWidth - 1 - values.count.leadingZeroBitCount)
		introsort(0, values.count, depth, true, &values, counts)
	}
}
