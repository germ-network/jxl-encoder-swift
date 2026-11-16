import Testing

@testable import JXLEncoder

/// `FrameAssembly.writeColorCorrelationDC` and the AC/DC chroma-from-luma
/// factors it implies are, together, the port's whole color-correlation
/// story: `-e 4` never computes a non-default map (both `CfLHeuristics`
/// gates are stricter than `kCheetah`), so what's on the wire is always
/// exactly the reference's own default `ColorCorrelation` — see
/// `writeColorCorrelationDC`'s doc comment and docs/gap-closure-plan.md,
/// "CfL-default alignment check."
///
/// Nothing previously asserted the color-correlation bits or factors
/// directly — coverage was indirect (decode succeeds, token counts match).
/// These pin the actual values so a future edit that silently drifts one
/// side without the other (e.g. changing `bFactor` without changing
/// `dcCflFactor`) fails here instead of only showing up as a subtly wrong
/// decode.
@Suite("Color correlation")
struct ColorCorrelationTests {
	@Test("pixel path writes the single default-cmap bit")
	func defaultBits() throws {
		var writer = BitWriter()
		try FrameAssembly.writeColorCorrelationDC(jpegCompatible: false, writer: &writer)
		#expect(writer.bitsWritten == 1)
		writer.zeroPadToByte()
		#expect(writer.take() == [1])  // BitWriter is least-significant-bit first
	}

	/// `1 (not default) + 2 (colour factor) + 16 (base X) + 16 (base B) + 8
	/// (ytox_dc) + 8 (ytob_dc) = 51 bits`, all of them the reference's own
	/// default values for a non-XYB (JPEG-transcode) `ColorCorrelation`:
	/// colour factor 84 (selector `00`, no payload — `kColorFactorDist`'s
	/// first `Val`), base correlation X and B both `0.0` as half floats,
	/// `ytox_dc`/`ytob_dc` both `0` written offset by `-128`. The bit *count*
	/// alone doesn't distinguish "all defaults" from any other 51 bits, so
	/// this pins the actual byte sequence, not just the length.
	@Test("transcode path writes the 51-bit long form, all defaults")
	func jpegBits() throws {
		var writer = BitWriter()
		try FrameAssembly.writeColorCorrelationDC(jpegCompatible: true, writer: &writer)
		#expect(writer.bitsWritten == 51)
		writer.zeroPadToByte()
		#expect(writer.take() == [0, 0, 0, 0, 0, 0x04, 0x04])
	}

	/// DC correlation is applied during full-group DC preparation.
	@Test("AC factors retain the default correlation")
	func factorsMatchDefaultCorrelation() {
		#expect(ACGroupEncoder.xFactor == 0)  // YtoXRatio(0) = base_correlation_x_ = 0
		#expect(ACGroupEncoder.bFactor == 1)
	}
}
