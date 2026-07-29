//
//  DistanceParams.swift
//  JXLEncoder
//
//  Port of `QuantDC` and `ComputeDistanceParams` from libjxl-tiny's
//  encoder/enc_frame.cc: turns a butteraugli distance into the frame-level
//  quantizer settings.
//

import RealModule

func clamp1<T: Comparable>(_ value: T, _ low: T, _ high: T) -> T {
	value < low ? low : (value > high ? high : value)
}

/// Frame-level quantizer settings derived from the requested distance.
public struct DistanceParams: Equatable, Sendable {
	public let distance: Float
	public let globalScale: Int
	public let quantDC: Int
	public let scale: Float
	public let inverseScale: Float
	public let scaleDC: Float
	public let xQuantMatrixScale: UInt32

	static let globalScaleDenominator = 1 << 16
	static let globalScaleNumerator = 4096
	static let acQuant: Float = 0.8
	static let quantFieldTarget: Float = 5

	public init(distance: Float) throws {
		guard distance >= 0 else { throw EncoderError.invalidDistance(distance) }
		guard distance > 0 else { throw EncoderError.losslessNotSupported }

		// Below this the average bits-per-pixel exceeds lossless, so the
		// reference clamps rather than encoding a pointlessly large file.
		let distance = max(distance, 0.03)
		self.distance = distance

		let dcQuant = Self.quantDC(distance: distance)

		var scale =
			Float(Self.globalScaleDenominator) * Self.acQuant
			/ (distance * Self.quantFieldTarget)
		scale = clamp1(scale, 1.0, Float(1 << 15))

		// `1.6` is a double literal in the reference, so the product promotes to
		// double before being truncated.
		let scaledQuantDC = Int(Double(dcQuant * Float(Self.globalScaleNumerator)) * 1.6)
		globalScale = clamp1(Int(scale), 1, scaledQuantDC)

		self.scale = Float(globalScale) * (1.0 / Float(Self.globalScaleDenominator))
		inverseScale = 1.0 / self.scale
		quantDC = clamp1(Int(dcQuant / self.scale + 0.5), 1, 1 << 16)
		scaleDC = Float(quantDC) * self.scale

		var xScale: UInt32 = 2
		for step in [Float(1.25), 9.0] where distance > step {
			xScale += 1
		}
		if distance < 0.299 {
			// Favours chroma preservation so heavily zoomed images stay faithful.
			xScale += 1
		}
		xQuantMatrixScale = xScale
	}

	static func quantDC(distance: Float) -> Float {
		let dcQuantPow: Float = 0.57
		let dcQuant: Float = 1.12
		// Butteraugli target where the non-linearity kicks in.
		let dcMul: Float = 2.9

		var effective = dcMul * Float.pow(distance / dcMul, dcQuantPow)
		effective = clamp1(effective, 0.5 * distance, distance)
		return min(dcQuant / effective, 50)
	}
}
