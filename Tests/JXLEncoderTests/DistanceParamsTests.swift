import Testing

@testable import JXLEncoder

/// Expected values come from compiling libjxl-tiny's `ComputeDistanceParams`
/// arithmetic directly and printing raw bit patterns, so these pin the exact
/// float results rather than an approximation.
@Suite("DistanceParams")
struct DistanceParamsTests {
	struct Expected {
		let distance: Float
		let globalScale: Int
		let quantDC: Int
		let scaleBits: UInt32
		let scaleDCBits: UInt32
		let xQuantMatrixScale: UInt32
	}

	static let reference: [Expected] = [
		.init(
			distance: 0.03, globalScale: 32768, quantDC: 75, scaleBits: 0x3F00_0000,
			scaleDCBits: 0x4216_0000, xQuantMatrixScale: 3),
		.init(
			distance: 0.1, globalScale: 32768, quantDC: 22, scaleBits: 0x3F00_0000,
			scaleDCBits: 0x4130_0000, xQuantMatrixScale: 3),
		.init(
			distance: 0.25, globalScale: 29360, quantDC: 10, scaleBits: 0x3EE5_6000,
			scaleDCBits: 0x408F_5C00, xQuantMatrixScale: 3),
		.init(
			distance: 0.5, globalScale: 14680, quantDC: 10, scaleBits: 0x3E65_6000,
			scaleDCBits: 0x400F_5C00, xQuantMatrixScale: 2),
		.init(
			distance: 1.0, globalScale: 7340, quantDC: 10, scaleBits: 0x3DE5_6000,
			scaleDCBits: 0x3F8F_5C00, xQuantMatrixScale: 2),
		.init(
			distance: 1.5, globalScale: 4893, quantDC: 10, scaleBits: 0x3D98_E800,
			scaleDCBits: 0x3F3F_2200, xQuantMatrixScale: 3),
		.init(
			distance: 2.0, globalScale: 3670, quantDC: 10, scaleBits: 0x3D65_6000,
			scaleDCBits: 0x3F0F_5C00, xQuantMatrixScale: 3),
		.init(
			distance: 3.0, globalScale: 2482, quantDC: 10, scaleBits: 0x3D1B_2000,
			scaleDCBits: 0x3EC1_E800, xQuantMatrixScale: 3),
		.init(
			distance: 5.0, globalScale: 1855, quantDC: 10, scaleBits: 0x3CE7_E000,
			scaleDCBits: 0x3E90_EC00, xQuantMatrixScale: 3),
		.init(
			distance: 10.0, globalScale: 1048, quantDC: 12, scaleBits: 0x3C83_0000,
			scaleDCBits: 0x3E44_8000, xQuantMatrixScale: 4),
	]

	@Test("matches libjxl-tiny", arguments: reference)
	func matchesReference(expected: Expected) throws {
		let params = try DistanceParams(distance: expected.distance)
		#expect(params.globalScale == expected.globalScale)
		#expect(params.quantDC == expected.quantDC)
		#expect(params.scale.bitPattern == expected.scaleBits)
		#expect(params.scaleDC.bitPattern == expected.scaleDCBits)
		#expect(params.xQuantMatrixScale == expected.xQuantMatrixScale)
	}

	/// The distances where the `effective_dist` clamp does not bind, so the
	/// result depends on `pow` to the last bit. These are the cases that would
	/// expose a mismatch between swift-numerics and the reference's `std::pow`.
	@Test(
		"QuantDC matches std::pow bit-for-bit where the clamp does not bind",
		arguments: [
			(Float(3.0), UInt32(0x3EC1_F41B)),
			(Float(5.0), UInt32(0x3E90_F565)),
			(Float(10.0), UInt32(0x3E43_4B07)),
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
