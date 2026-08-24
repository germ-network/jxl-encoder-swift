//
//  DistanceParams.swift
//  JXLEncoder
//
//  Turns a butteraugli distance into the frame-level quantizer settings.
//  `globalScale`/`scale`/`quantDC` follow the same shape as full libjxl's
//  `Quantizer::ComputeGlobalScaleAndQuant` (`quantizer.cc`) — inherited from
//  libjxl-tiny's own `ComputeDistanceParams`, which already assumed no
//  per-block deviation (`quant_median_absd = 0`), exactly matching what
//  `-e 4`'s own uniform quant field does. `quantDC`'s constants and
//  `uniformQuant` are retargeted to `InitialQuantDC`/the uniform branch's
//  own literals (`enc_adaptive_quantization.cc`, `enc_heuristics.cc`), not
//  tiny's — see docs/gap-closure-plan.md, "Quant calibration."
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
	/// Edge-preserving filter iterations the decoder will run.
	public let epfIterations: UInt32
	/// The per-block AC quant value every block gets: `-e 4`'s own quant
	/// field is uniform (`ComputeUsedOrders`'s speed tier — kCheetah — never
	/// calls the adaptive map), so there is only one value to compute.
	public let uniformQuant: UInt8

	static let globalScaleDenominator = 1 << 16
	static let globalScaleNumerator = 4096
	/// `kCheetah`'s (`-e 4`'s) own literal in the uniform-quant-field branch
	/// (`enc_heuristics.cc`), not `kAcQuant` (0.765, the adaptive branch's
	/// constant) or libjxl-tiny's own historically-diverged 0.8.
	static let acQuant: Float = 0.79
	static let quantFieldTarget: Float = 5
	/// `Quantizer::kQuantMax`, minus one: `raw_quant_field` is `ImageI` in
	/// the reference (int32, no 255 ceiling) but this port stores it as
	/// `UInt8` — 256 has never been reached at any distance this port's
	/// corpus covers, so this pre-existing ceiling is left as is.
	static let quantMax: Int = 255

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

		let q = Self.acQuant / distance
		uniformQuant = UInt8(clamp1(Int(q * inverseScale + 0.5), 1, Self.quantMax))

		var xScale: UInt32 = 2
		for step in [Float(1.25), 9.0] where distance > step {
			xScale += 1
		}
		if distance < 0.299 {
			// Favours chroma preservation so heavily zoomed images stay faithful.
			xScale += 1
		}
		xQuantMatrixScale = xScale

		var iterations: UInt32 = 0
		for threshold in [Float(0.7), 1.5, 4.0] where distance >= threshold {
			iterations += 1
		}
		epfIterations = iterations
	}

	/// `InitialQuantDC` (`enc_adaptive_quantization.cc`), not libjxl-tiny's
	/// own `QuantDC` — same clamp structure, historically-diverged
	/// constants (`kDcQuantPow`/`kDcQuant`/`kDcMul`).
	static func quantDC(distance: Float) -> Float {
		let dcQuantPow: Float = 0.83
		let dcQuant: Float = 1.095_924_047_623_553
		// Butteraugli target where the non-linearity kicks in.
		let dcMul: Float = 0.3

		var effective = dcMul * Float.pow(distance / dcMul, dcQuantPow)
		effective = clamp1(effective, 0.5 * distance, distance)
		return min(dcQuant / effective, 50)
	}
}
