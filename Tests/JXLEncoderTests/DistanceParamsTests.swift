import Testing

@testable import JXLEncoder

/// Expected values come from compiling full libjxl's own arithmetic directly
/// (`InitialQuantDC`, `Quantizer::ComputeGlobalScaleAndQuant`, the uniform
/// quant field's `q = 0.79 / distance`, and `Quantizer::ClampVal`) and
/// printing raw bit patterns, so these pin the exact float results rather
/// than an approximation. Retargeted from libjxl-tiny to `-e 4`'s own
/// uniform-quant-field branch — see docs/gap-closure-plan.md, "Quant
/// calibration."
@Suite("DistanceParams")
struct DistanceParamsTests {
	struct Expected {
		let distance: Float
		let globalScale: Int
		let quantDC: Int
		let scaleBits: UInt32
		let scaleDCBits: UInt32
		let xQuantMatrixScale: UInt32
		let uniformQuant: UInt8
	}

	static let reference: [Expected] = [
		.init(
			distance: 0.03, globalScale: 32768, quantDC: 73, scaleBits: 0x3F00_0000,
			scaleDCBits: 0x4212_0000, xQuantMatrixScale: 3, uniformQuant: 53),
		.init(
			distance: 0.1, globalScale: 32768, quantDC: 22, scaleBits: 0x3F00_0000,
			scaleDCBits: 0x4130_0000, xQuantMatrixScale: 3, uniformQuant: 16),
		.init(
			distance: 0.25, globalScale: 28728, quantDC: 10, scaleBits: 0x3EE0_7000,
			scaleDCBits: 0x408C_4600, xQuantMatrixScale: 3, uniformQuant: 7),
		.init(
			distance: 0.5, globalScale: 15667, quantDC: 10, scaleBits: 0x3E74_CC00,
			scaleDCBits: 0x4018_FF80, xQuantMatrixScale: 2, uniformQuant: 7),
		.init(
			distance: 1.0, globalScale: 8813, quantDC: 10, scaleBits: 0x3E09_B400,
			scaleDCBits: 0x3FAC_2100, xQuantMatrixScale: 2, uniformQuant: 6),
		.init(
			distance: 1.5, globalScale: 6294, quantDC: 10, scaleBits: 0x3DC4_B000,
			scaleDCBits: 0x3F75_DC00, xQuantMatrixScale: 3, uniformQuant: 5),
		.init(
			distance: 2.0, globalScale: 4957, quantDC: 10, scaleBits: 0x3D9A_E800,
			scaleDCBits: 0x3F41_A200, xQuantMatrixScale: 3, uniformQuant: 5),
		.init(
			distance: 3.0, globalScale: 3451, quantDC: 10, scaleBits: 0x3D57_B000,
			scaleDCBits: 0x3F06_CE00, xQuantMatrixScale: 3, uniformQuant: 5),
		.init(
			distance: 5.0, globalScale: 2070, quantDC: 11, scaleBits: 0x3D01_6000,
			scaleDCBits: 0x3EB1_E400, xQuantMatrixScale: 3, uniformQuant: 5),
		.init(
			distance: 10.0, globalScale: 1035, quantDC: 13, scaleBits: 0x3C81_6000,
			scaleDCBits: 0x3E52_3C00, xQuantMatrixScale: 4, uniformQuant: 5),
	]

	@Test("matches full libjxl's -e 4 uniform-quant-field branch", arguments: reference)
	func matchesReference(expected: Expected) throws {
		let params = try DistanceParams(distance: expected.distance)
		#expect(params.globalScale == expected.globalScale)
		#expect(params.quantDC == expected.quantDC)
		#expect(params.scale.bitPattern == expected.scaleBits)
		#expect(params.scaleDC.bitPattern == expected.scaleDCBits)
		#expect(params.xQuantMatrixScale == expected.xQuantMatrixScale)
		#expect(params.uniformQuant == expected.uniformQuant)
	}

	/// The distances where the `effective_dist` clamp does not bind, so the
	/// result depends on `pow` to the last bit. These are the cases that would
	/// expose a mismatch between swift-numerics and the reference's `std::pow`.
	@Test(
		"QuantDC matches std::pow bit-for-bit where the clamp does not bind",
		arguments: [
			(Float(3.0), UInt32(0x3F0A_5313)),
			(Float(5.0), UInt32(0x3EB5_0C64)),
			(Float(10.0), UInt32(0x3E4B_B0A8)),
		])
	func quantDCUsesPow(distance: Float, expectedBits: UInt32) {
		#expect(DistanceParams.quantDC(distance: distance).bitPattern == expectedBits)
	}

	@Test("rejects lossless and negative distances")
	func rejectsInvalid() {
		#expect(throws: EncoderError.losslessNotSupported) {
			try DistanceParams(distance: 0)
		}
		#expect(throws: EncoderError.invalidDistance(-1)) {
			try DistanceParams(distance: -1)
		}
	}

	@Test("distances below 0.03 clamp to the same parameters")
	func clampsTinyDistances() throws {
		let tiny = try DistanceParams(distance: 0.001)
		let floor = try DistanceParams(distance: 0.03)
		#expect(tiny == floor)
	}
}
