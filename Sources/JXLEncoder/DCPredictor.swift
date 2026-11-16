//
//  DCPredictor.swift
//  JXLEncoder
//
//  Source-faithful predictors and context models for modular DC.
//

enum DCPredictor {
	struct WeightedState {
		private let width: Int
		private var predictions: (Int64, Int64, Int64, Int64) = (0, 0, 0, 0)
		private var predictionErrors: [[UInt32]]
		private var errors: [Int64]
		private var prediction: Int64 = 0

		init(width: Int) {
			precondition(width > 0)
			self.width = width
			let rowSize = width + 2
			predictionErrors = Array(
				repeating: [UInt32](repeating: 0, count: rowSize * 2), count: 4)
			errors = [Int64](repeating: 0, count: rowSize * 2)
		}

		mutating func predict(
			x: Int, y: Int, north: Int32, west: Int32, northEast: Int32,
			northWest: Int32, northNorth: Int32
		) -> (guess: Int64, property: Int64) {
			precondition(x >= 0 && x < width && y >= 0)
			let rowSize = width + 2
			let currentRow = y & 1 == 0 ? rowSize : 0
			let previousRow = y & 1 == 0 ? 0 : rowSize
			let northIndex = previousRow + x
			let northEastIndex = previousRow + (x < width - 1 ? x + 1 : x)
			let northWestIndex = previousRow + (x > 0 ? x - 1 : x)

			let weight0 = errorWeight(
				predictionErrors[0][northIndex]
					&+ predictionErrors[0][northEastIndex]
					&+ predictionErrors[0][northWestIndex], maxWeight: 13)
			let weight1 = errorWeight(
				predictionErrors[1][northIndex]
					&+ predictionErrors[1][northEastIndex]
					&+ predictionErrors[1][northWestIndex], maxWeight: 12)
			let weight2 = errorWeight(
				predictionErrors[2][northIndex]
					&+ predictionErrors[2][northEastIndex]
					&+ predictionErrors[2][northWestIndex], maxWeight: 12)
			let weight3 = errorWeight(
				predictionErrors[3][northIndex]
					&+ predictionErrors[3][northEastIndex]
					&+ predictionErrors[3][northWestIndex], maxWeight: 12)

			let n = Int64(north) << 3
			let w = Int64(west) << 3
			let ne = Int64(northEast) << 3
			let nw = Int64(northWest) << 3
			let nn = Int64(northNorth) << 3
			let teW = x == 0 ? 0 : errors[currentRow + x - 1]
			let teN = errors[northIndex]
			let teNW = errors[northWestIndex]
			let teNE = errors[northEastIndex]
			let weightedError = teN + teW

			predictions.0 = w + ne - n
			predictions.1 = n - ((weightedError + teNE) * 16 >> 5)
			predictions.2 = w - ((weightedError + teNW) * 10 >> 5)
			// The selected WP mode fixes the north-north and north-west coefficients to zero.
			let weightedP3 = teNW * 7 + teN * 7 + teNE * 7 + (nn - n) * 0 + (nw - w) * 0
			predictions.3 = n - (weightedP3 >> 5)
			prediction = weightedAverage(
				predictions, (weight0, weight1, weight2, weight3))

			var property = teW
			if abs(teN) > abs(property) { property = teN }
			if abs(teNW) > abs(property) { property = teNW }
			if abs(teNE) > abs(property) { property = teNE }

			if ((teN ^ teW) | (teN ^ teNW)) <= 0 {
				prediction = max(
					min(n, min(w, ne)), min(max(n, max(w, ne)), prediction))
			}
			return ((prediction + 3) >> 3, property)
		}

		mutating func updateErrors(value: Int32, x: Int, y: Int) {
			precondition(x >= 0 && x < width && y >= 0)
			let rowSize = width + 2
			let currentRow = y & 1 == 0 ? rowSize : 0
			let previousRow = y & 1 == 0 ? 0 : rowSize
			let position = currentRow + x
			let scaledValue = Int64(value) << 3
			errors[position] = prediction - scaledValue
			let error0 = UInt32((abs(predictions.0 - scaledValue) + 3) >> 3)
			let error1 = UInt32((abs(predictions.1 - scaledValue) + 3) >> 3)
			let error2 = UInt32((abs(predictions.2 - scaledValue) + 3) >> 3)
			let error3 = UInt32((abs(predictions.3 - scaledValue) + 3) >> 3)
			let future = previousRow + x + 1
			predictionErrors[0][position] = error0
			predictionErrors[1][position] = error1
			predictionErrors[2][position] = error2
			predictionErrors[3][position] = error3
			predictionErrors[0][future] &+= error0
			predictionErrors[1][future] &+= error1
			predictionErrors[2][future] &+= error2
			predictionErrors[3][future] &+= error3
		}

		private func errorWeight(_ error: UInt32, maxWeight: UInt32) -> UInt32 {
			let value = UInt64(error) + 1
			let shift = max(0, value.bitWidth - value.leadingZeroBitCount - 1 - 5)
			let index = Int(UInt64(error) >> shift)
			let reciprocal = UInt32((1 << 24) / (index + 1))
			return 4 + ((maxWeight * reciprocal) >> shift)
		}

		private func weightedAverage(
			_ values: (Int64, Int64, Int64, Int64),
			_ sourceWeights: (UInt32, UInt32, UInt32, UInt32)
		) -> Int64 {
			let total =
				sourceWeights.0 &+ sourceWeights.1 &+ sourceWeights.2
				&+ sourceWeights.3
			let logWeight = total.bitWidth - total.leadingZeroBitCount - 1
			let shift = logWeight - 4
			let weight0 = sourceWeights.0 >> shift
			let weight1 = sourceWeights.1 >> shift
			let weight2 = sourceWeights.2 >> shift
			let weight3 = sourceWeights.3 >> shift
			let weightSum = weight0 &+ weight1 &+ weight2 &+ weight3
			var sum = Int64(weightSum >> 1) - 1
			sum += values.0 * Int64(weight0)
			sum += values.1 * Int64(weight1)
			sum += values.2 * Int64(weight2)
			sum += values.3 * Int64(weight3)
			let reciprocal = Int64((1 << 24) / Int(weightSum))
			return (sum * reciprocal) >> 24
		}
	}

	static let gradRangeMin: Int = 0
	static let gradRangeMid: Int = 512
	static let gradRangeMax: Int = 1023
	static let numDCContexts = 45

	/// `n + w - l`, clamped to lie between its two direct neighbours. The
	/// reference computes the sum in unsigned arithmetic so intermediate
	/// overflow wraps rather than trapping, then relies on the clamp.
	static func clampedGradient(top n: Int32, left w: Int32, topLeft l: Int32) -> Int32 {
		let m = min(n, w)
		let mx = max(n, w)
		let gradient = Int32(
			bitPattern: UInt32(bitPattern: n) &+ UInt32(bitPattern: w)
				&- UInt32(bitPattern: l))
		let clampedHigh = l < m ? mx : gradient
		return l > mx ? m : clampedHigh
	}

	/// Maps the gradient property onto one of the DC contexts.
	static let gradientContextLut: [UInt8] = [
		44, 44, 44, 44, 44, 44, 44, 44, 44, 44, 44, 44, 44, 43, 43, 43, 43, 43, 43, 43,
		43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43,
		43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43,
		43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43,
		43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43,
		43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43, 43,
		43, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40,
		40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40,
		40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40,
		40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40,
		40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40,
		40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40,
		40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 39, 39,
		39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39,
		39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39,
		39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39,
		39, 39, 38, 38, 38, 38, 38, 38, 38, 38, 38, 38, 38, 38, 38, 38, 38, 38, 38, 38,
		38, 38, 38, 38, 38, 38, 38, 38, 38, 38, 38, 38, 38, 38, 38, 38, 38, 38, 38, 38,
		38, 38, 38, 38, 38, 38, 38, 38, 38, 38, 38, 38, 38, 38, 38, 38, 38, 38, 38, 38,
		38, 38, 38, 38, 38, 38, 37, 37, 37, 37, 37, 37, 37, 37, 37, 37, 37, 37, 37, 37,
		37, 37, 37, 37, 37, 37, 37, 37, 37, 37, 37, 37, 37, 37, 37, 37, 37, 37, 36, 36,
		36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36,
		36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 35, 35, 35, 35, 35, 35, 35, 35, 35, 35,
		35, 35, 35, 35, 35, 35, 34, 34, 34, 34, 34, 34, 34, 34, 34, 34, 34, 34, 34, 34,
		34, 34, 33, 33, 33, 33, 33, 33, 33, 33, 32, 32, 32, 32, 32, 32, 32, 32, 31, 31,
		31, 31, 30, 30, 30, 30, 29, 29, 29, 28, 27, 27, 26, 42, 41, 41, 25, 25, 24, 24,
		23, 23, 23, 23, 22, 22, 22, 22, 21, 21, 21, 21, 21, 21, 21, 21, 20, 20, 20, 20,
		20, 20, 20, 20, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19,
		18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 17, 17, 17, 17,
		17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17,
		17, 17, 17, 17, 17, 17, 17, 17, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16,
		16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16,
		15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
		15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
		15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
		15, 15, 15, 15, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14,
		14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14,
		14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14,
		14, 14, 14, 14, 14, 14, 14, 14, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13,
		13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13,
		13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13,
		13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13,
		13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13,
		13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13,
		13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13,
		13, 13, 13, 13, 13, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
		12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
		12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
		12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
		12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
		12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 11, 11, 11, 11, 11, 11, 11,
		11, 11, 11, 11,
	]
}
