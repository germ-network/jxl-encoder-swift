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

	static let small13 = Self(
		quantCounts: histogram([(0, 1024)]), qfThresholds: [], numContexts: 3,
		contextMap: [0] + [UInt8](repeating: 1, count: 12)
			+ [UInt8](repeating: 2, count: 26), sourceMapDifferences: [])

	static let unequalPositive26 = Self(
		quantCounts: histogram([(3, 4000), (10, 6000)]), qfThresholds: [10],
		numContexts: 7,
		contextMap: [0, 1, 2, 3] + [UInt8](repeating: 3, count: 22)
			+ [4, 5, 6] + [UInt8](repeating: 6, count: 23)
			+ [4, 5, 6] + [UInt8](repeating: 6, count: 23),
		sourceMapDifferences: [])

	static let tieObservation = Self(
		quantCounts: histogram((0..<250).map { ($0, 200) }),
		qfThresholds: [125], numContexts: 14,
		contextMap: [0, 1, 2, 3, 4, 5, 6, 7] + [UInt8](repeating: 8, count: 18)
			+ [9, 10, 11, 12] + [UInt8](repeating: 13, count: 22)
			+ [9, 10, 11, 12] + [UInt8](repeating: 13, count: 22),
		sourceMapDifferences: Self.tieObservationDifferences)

	static let flower1024 = Self(
		quantCounts: histogram([(5, 16_384)]), qfThresholds: [5], numContexts: 13,
		contextMap: [0, 1, 2, 3, 4, 5, 6, 7] + [UInt8](repeating: 7, count: 18)
			+ [8, 9, 10, 11] + [UInt8](repeating: 12, count: 22)
			+ [8, 9, 10, 11] + [UInt8](repeating: 12, count: 22),
		sourceMapDifferences: [])

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
