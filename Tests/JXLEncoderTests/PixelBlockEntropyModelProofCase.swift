@testable import JXLEncoder

struct PixelBlockMapDifference: Equatable, Sendable {
	let index: Int
	let source: UInt8
	let native: UInt8
}

struct PixelBlockEntropyModelProofCase: Sendable {
	let quantCounts: [Int]
	let qfThresholds: [UInt32]
	let numContexts: Int
	let contextMap: [UInt8]
	let sourceMapDifferences: [PixelBlockMapDifference]

	static let small13: Self = {
		let counts = histogram([(0, 1024)])
		var map: [UInt8] = [0]
		map.append(contentsOf: repeatElement(1, count: 12))
		map.append(contentsOf: repeatElement(2, count: 26))
		return Self(
			quantCounts: counts, qfThresholds: [], numContexts: 3,
			contextMap: map, sourceMapDifferences: [])
	}()

	static let unequalPositive26: Self = {
		let counts = histogram([(3, 4000), (10, 6000)])
		var map: [UInt8] = [0, 1, 2, 3]
		map.append(contentsOf: repeatElement(3, count: 22))
		map.append(contentsOf: [4, 5, 6])
		map.append(contentsOf: repeatElement(6, count: 23))
		map.append(contentsOf: [4, 5, 6])
		map.append(contentsOf: repeatElement(6, count: 23))
		return Self(
			quantCounts: counts, qfThresholds: [10], numContexts: 7,
			contextMap: map, sourceMapDifferences: [])
	}()

	static let tieObservation: Self = {
		let entries: [(Int, Int)] = (0..<250).map { ($0, 200) }
		let counts = histogram(entries)
		var map: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7]
		map.append(contentsOf: repeatElement(8, count: 18))
		map.append(contentsOf: [9, 10, 11, 12])
		map.append(contentsOf: repeatElement(13, count: 22))
		map.append(contentsOf: [9, 10, 11, 12])
		map.append(contentsOf: repeatElement(13, count: 22))
		return Self(
			quantCounts: counts, qfThresholds: [125], numContexts: 14,
			contextMap: map, sourceMapDifferences: tieObservationDifferences)
	}()

	static let flower1024: Self = {
		let counts = histogram([(5, 16_384)])
		var map: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7]
		map.append(contentsOf: repeatElement(7, count: 18))
		map.append(contentsOf: [8, 9, 10, 11])
		map.append(contentsOf: repeatElement(12, count: 22))
		map.append(contentsOf: [8, 9, 10, 11])
		map.append(contentsOf: repeatElement(12, count: 22))
		return Self(
			quantCounts: counts, qfThresholds: [5], numContexts: 13,
			contextMap: map, sourceMapDifferences: [])
	}()

	private static func histogram(_ entries: [(Int, Int)]) -> [Int] {
		var counts = [Int](repeating: 0, count: 256)
		for (index, count) in entries { counts[index] = count }
		return counts
	}

	private static let tieObservationDifferences: [PixelBlockMapDifference] = {
		let sourceIndices = Array(8...12) + Array(14...25)
		return (0..<3).flatMap { channel in
			sourceIndices.map {
				PixelBlockMapDifference(
					index: channel * 26 + $0,
					source: channel == 0 ? 2 : 11,
					native: channel == 0 ? 8 : 13)
			}
		}
	}()
}

struct SourcePixelBlockModelFields: Sendable {
	let total: Int
	let qfThresholds: [UInt32]
	let numContexts: Int
	let contextMap: [UInt8]
	let consumerRawQuant: [Int]
	let consumerCategories: [Int]
}
