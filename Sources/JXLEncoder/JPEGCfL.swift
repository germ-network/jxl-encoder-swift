extension JPEGTranscode {
	static func colorCorrelationFactor(zeroCountDifferences: [Int32]) -> Int8 {
		guard zeroCountDifferences.count == 257 else { return 0 }
		var sum: Int32 = 0
		var bestSum: Int32 = 0
		var first = 0
		var last = 0
		for candidate in 0..<256 {
			sum += zeroCountDifferences[candidate]
			if sum > bestSum {
				bestSum = sum
				first = candidate
				last = candidate
			} else if sum == bestSum {
				last = candidate
			}
		}
		var baseline: Int32 = 0
		for difference in zeroCountDifferences[0...127] { baseline += difference }
		guard bestSum > baseline + 1 else { return 0 }
		let winner = (first + last + 1) >> 1
		let factor = winner - 127
		guard let represented = Int8(exactly: factor) else { return 0 }
		return represented
	}

	func populateColorCorrelation(
		data: inout DCGroupData, blockX0: Int, blockY0: Int
	) {
		guard !isGrayscale, subsampling.is444 else { return }
		for localY in 0..<data.cmapHeight {
			for localX in 0..<data.cmapWidth {
				let x0 = blockX0 + localX * 8
				let y0 = blockY0 + localY * 8
				let x1 = min((width + 7) / 8, x0 + 8)
				let y1 = min((height + 7) / 8, y0 + 8)
				guard x0 < x1, y0 < y1 else { continue }
				let i = localY * data.cmapWidth + localX
				data.ytoxMap[i] = colorCorrelation(
					channel: 0, x0: x0, y0: y0, x1: x1, y1: y1)
				data.ytobMap[i] = colorCorrelation(
					channel: 2, x0: x0, y0: y0, x1: x1, y1: y1)
			}
		}
	}

	private func colorCorrelation(channel: Int, x0: Int, y0: Int, x1: Int, y1: Int) -> Int8 {
		var differences = [Int32](repeating: 0, count: 257)
		let zeroThreshold = Float(84) * Float(0.5) * Float(0.9999)
		for y in y0..<y1 {
			for x in x0..<x1 {
				let luma = block(channel: 1, x: x, y: y)
				let chroma = block(channel: channel, x: x, y: y)
				for coefficient in 1..<64 {
					let m =
						Float(luma[coefficient]) * (1.0 / 2048.0)
						* Float(quantizationRatios[channel][coefficient])
					let s =
						Float(84) * Float(chroma[coefficient]) + Float(127)
						* m
					guard abs(m) > 1e-8 else { continue }
					let from: Float
					let to: Float
					if m > 0 {
						from = (s - zeroThreshold) / m
						to = (s + zeroThreshold) / m
					} else {
						from = (s + zeroThreshold) / m
						to = (s - zeroThreshold) / m
					}
					let clippedFrom = max(0, from)
					let clippedTo = min(255, to)
					if clippedFrom <= clippedTo {
						differences[Int(clippedFrom.rounded(.up))] += 1
						differences[Int((clippedTo + 1).rounded(.down))] -=
							1
					}
				}
			}
		}
		return Self.colorCorrelationFactor(zeroCountDifferences: differences)
	}

	func block(
		channel: Int, x: Int, y: Int, correlation: Int8
	) throws -> [Int32] {
		let raw = block(channel: channel, x: x, y: y)
		guard channel != 1, !isGrayscale, subsampling.is444, correlation != 0 else {
			return raw
		}
		let scale = Int64(correlation) * 2048 / 84
		var result = raw
		let luma = block(channel: 1, x: x, y: y)
		for coefficient in 1..<64 {
			let coeffScale =
				(scale * Int64(quantizationRatios[channel][coefficient]) + 1024)
				>> 11
			let prediction =
				(Int64(luma[coefficient]) * coeffScale + 1024) >> 11
			let residual = Int64(raw[coefficient]) - prediction
			guard let narrowed = Int32(exactly: residual) else {
				throw TranscodeError.residualOverflow(
					channel: channel, blockX: x, blockY: y,
					coefficient: coefficient)
			}
			result[coefficient] = narrowed
		}
		return result
	}
}
