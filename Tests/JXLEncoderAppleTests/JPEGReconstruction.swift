#if canImport(ImageIO)

	import Foundation
	import JXLEncoder

	/// Turns parsed coefficients back into RGB, so the parser can be checked
	/// against a decoder that starts from the same file.
	///
	/// Exists only for the cross-check: dequantize, inverse DCT, upsample,
	/// colour-convert. The inverse DCT is a plain float transform rather than
	/// libjpeg's fixed-point one, worth about a level per sample; the chroma
	/// upsampling copies libjpeg's triangle filter exactly, since a different
	/// filter would swamp that with edge differences.
	enum JPEGReconstruction {
		/// Edge-clamped access to one component's samples, which is how a
		/// decoder reads past the right and bottom edges while interpolating.
		struct Plane {
			let samples: [UInt8]
			let width: Int
			let height: Int

			subscript(x: Int, y: Int) -> Int {
				let column = min(max(x, 0), width - 1)
				let row = min(max(y, 0), height - 1)
				return Int(samples[row * width + column])
			}
		}

		static let cosines: [[Float]] = (0..<8).map { x in
			(0..<8).map { u in
				Float(cos(Double(2 * x + 1) * Double(u) * Double.pi / 16))
			}
		}

		static func clamped(_ value: Int) -> UInt8 {
			UInt8(min(255, max(0, value)))
		}

		static func clamped(_ value: Float) -> UInt8 {
			clamped(Int((value + 0.5).rounded(.down)))
		}

		static func inverseDCT1D(_ input: [Float], offset: Int, stride: Int) -> [Float] {
			var output = [Float](repeating: 0, count: 8)
			for x in 0..<8 {
				var sum: Float = 0
				for u in 0..<8 {
					let scale: Float = u == 0 ? 0.707_106_78 : 1
					sum += scale * input[offset + u * stride] * cosines[x][u]
				}
				output[x] = sum / 2
			}
			return output
		}

		/// One block's samples: dequantized, inverse-transformed, level-shifted.
		static func block(_ coefficients: ArraySlice<Int32>, quantTable: [UInt16])
			-> [UInt8]
		{
			let base = coefficients.startIndex
			var values = [Float](repeating: 0, count: 64)
			for i in 0..<64 {
				values[i] = Float(coefficients[base + i]) * Float(quantTable[i])
			}

			var rows = [Float](repeating: 0, count: 64)
			for v in 0..<8 {
				let row = inverseDCT1D(values, offset: v * 8, stride: 1)
				for x in 0..<8 { rows[v * 8 + x] = row[x] }
			}

			var samples = [UInt8](repeating: 0, count: 64)
			for x in 0..<8 {
				let column = inverseDCT1D(rows, offset: x, stride: 8)
				for y in 0..<8 { samples[y * 8 + x] = clamped(column[y] + 128) }
			}
			return samples
		}

		/// A component's samples over its whole block grid, padding included.
		static func samples(of component: JPEGComponent, quantTable: [UInt16]) -> Plane {
			let width = component.blocksPerLine * 8
			let height = component.blocksPerColumn * 8
			var plane = [UInt8](repeating: 0, count: width * height)

			for blockY in 0..<component.blocksPerColumn {
				for blockX in 0..<component.blocksPerLine {
					let base = (blockY * component.blocksPerLine + blockX) * 64
					let decoded = block(
						component.coefficients[base..<(base + 64)],
						quantTable: quantTable)
					for y in 0..<8 {
						let row = (blockY * 8 + y) * width + blockX * 8
						for x in 0..<8 {
							plane[row + x] = decoded[y * 8 + x]
						}
					}
				}
			}
			return Plane(samples: plane, width: width, height: height)
		}

		static func replicate(
			_ plane: Plane, xFactor: Int, yFactor: Int, width: Int, height: Int
		) -> [UInt8] {
			var output = [UInt8](repeating: 0, count: width * height)
			for y in 0..<height {
				for x in 0..<width {
					output[y * width + x] = clamped(
						plane[x / xFactor, y / yFactor])
				}
			}
			return output
		}

		/// libjpeg's `h2v1_fancy_upsample`: 3/4 of the nearer sample plus 1/4 of
		/// the further one.
		static func fancyHorizontal(_ plane: Plane, width: Int, height: Int) -> [UInt8] {
			var output = [UInt8](repeating: 0, count: width * height)
			for y in 0..<height {
				for x in 0..<width {
					let source = x / 2
					let neighbour = x % 2 == 0 ? source - 1 : source + 1
					let bias = x % 2 == 0 ? 1 : 2
					let value =
						3 * plane[source, y] + plane[neighbour, y] + bias
					output[y * width + x] = clamped(value >> 2)
				}
			}
			return output
		}

		/// libjpeg's `h2v2_fancy_upsample`: the same triangle filter down the
		/// columns first, then across.
		static func fancyBoth(_ plane: Plane, width: Int, height: Int) -> [UInt8] {
			var output = [UInt8](repeating: 0, count: width * height)
			for y in 0..<height {
				let source = y / 2
				let rowNeighbour = y % 2 == 0 ? source - 1 : source + 1
				func columnSum(_ column: Int) -> Int {
					3 * plane[column, source] + plane[column, rowNeighbour]
				}
				for x in 0..<width {
					let column = x / 2
					let neighbour = x % 2 == 0 ? column - 1 : column + 1
					let bias = x % 2 == 0 ? 8 : 7
					let value =
						3 * columnSum(column) + columnSum(neighbour) + bias
					output[y * width + x] = clamped(value >> 4)
				}
			}
			return output
		}

		static func rgb(from image: JPEGImage) -> [UInt8] {
			let maxHorizontal = image.maxHorizontalSampling
			let maxVertical = image.maxVerticalSampling

			let planes = image.components.map { component -> [UInt8] in
				let decoded = samples(
					of: component,
					quantTable: image.quantTables[component.quantTableIndex])

				// Trim the MCU padding before upsampling: the interpolation has
				// to see the component's real right and bottom edges, which is
				// where a decoder clamps.
				let horizontal = maxHorizontal / component.horizontalSampling
				let vertical = maxVertical / component.verticalSampling
				let width = ceilDiv(
					image.width * component.horizontalSampling, maxHorizontal)
				let height = ceilDiv(
					image.height * component.verticalSampling, maxVertical)
				var trimmed = [UInt8](repeating: 0, count: width * height)
				for y in 0..<height {
					for x in 0..<width {
						trimmed[y * width + x] = UInt8(decoded[x, y])
					}
				}
				let plane = Plane(samples: trimmed, width: width, height: height)

				switch (horizontal, vertical) {
				case (2, 1):
					return fancyHorizontal(
						plane, width: image.width, height: image.height)
				case (2, 2):
					return fancyBoth(
						plane, width: image.width, height: image.height)
				default:
					return replicate(
						plane, xFactor: horizontal, yFactor: vertical,
						width: image.width, height: image.height)
				}
			}

			var rgb = [UInt8](repeating: 0, count: image.width * image.height * 3)
			for i in 0..<(image.width * image.height) {
				let y = Float(planes[0][i])
				guard planes.count == 3 else {
					for channel in 0..<3 { rgb[i * 3 + channel] = clamped(y) }
					continue
				}
				let cb = Float(planes[1][i]) - 128
				let cr = Float(planes[2][i]) - 128
				rgb[i * 3] = clamped(y + 1.402 * cr)
				rgb[i * 3 + 1] = clamped(y - 0.344_136 * cb - 0.714_136 * cr)
				rgb[i * 3 + 2] = clamped(y + 1.772 * cb)
			}
			return rgb
		}

		static func ceilDiv(_ a: Int, _ b: Int) -> Int { (a + b - 1) / b }
	}

#endif  // canImport(ImageIO)
