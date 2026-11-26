#if (os(macOS) && !targetEnvironment(macCatalyst)) || os(Linux)
	import Foundation
	import Testing

	@testable import JXLEncoder

	/// Profiled recompression checked by libjxl's own decoder through the
	/// `jpeg-witness` harness at `JXL_HARNESS_PATH`.
	@Suite("JPEG recompression native integration")
	struct JPEGRecompressionNativeTests {
		/// Each fixture also fixes whether its coded ICC enables LZ77, measured
		/// with pinned libjxl `WriteICC`: off for the P3 profiles, on for the
		/// repeated-desc ones.
		static let fixtures: [String: (name: String, lz77: Int64)] = [
			"ycbcr-p3": ("display_p3_profile", 0),
			"rgb-p3": ("rgb_p3_profile", 0),
			"lz77-p3": ("p3_desc4_profile", 1),
			"kLZ77": ("p3_desc1000_profile_420", 1),
			"random": ("p3_random40000_profile_420", 1),
			"ratio-above": ("p3_ratio_above_420", 1),
		]

		@Test(
			"libjxl recovers the exact profile, coefficients and quantizers",
			.enabled(if: CoeffOrderNativeIntegrationTests.harness != nil),
			arguments: [
				"ycbcr-p3", "rgb-p3", "lz77-p3", "kLZ77", "random", "ratio-above",
			],
			[true, false])
		func witnessRecoversProfileCoefficientsAndQuantizers(
			fixture: String, optimizeCodes: Bool
		) throws {
			try Self.witness(fixture, optimizeCodes)
		}

		static func witness(_ fixture: String, _ optimizeCodes: Bool) throws {
			let (name, lz77) = try #require(Self.fixtures[fixture])
			let jpeg = try JPEGParserTests.fixture(name)
			let image = try JPEGParser.parse(jpeg)
			let profile = try #require(image.iccProfile)
			let codestream = try Encoder.encodeJPEG(
				JPEGTranscode(image), optimizeCodes: optimizeCodes)
			let witness = try CoeffOrderNativeIntegrationTests.jpegWitness(
				sourceJPEG: Data(jpeg), codestream: Data(codestream),
				name: "\(fixture) optimizeCodes=\(optimizeCodes)")
			for field in [
				"want_icc", "exact_bytes", "coefficients_exact", "quantizers_exact",
			] {
				#expect(
					witness.fields["jpeg_icc.\(field)"] == .integers([1]),
					"\(field)")
			}
			#expect(
				witness.fields["jpeg_icc.size"] == .integers([Int64(profile.count)])
			)
			#expect(witness.fields["jpeg_icc.lz77_enabled"] == .integers([lz77]))
		}
	}
#endif
