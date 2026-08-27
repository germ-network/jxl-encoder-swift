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

	/// The AC and DC factors both derive from the same default correlation
	/// (`YtoXRatio(0) = 0`, `YtoBRatio(0) = kYToBRatio = 1`) — `dcCflFactor`
	/// is defined in terms of `bFactor` at the source (`ACGroupEncoder.
	/// swift`), not as an independently-maintained literal, so an edit to
	/// one without the other can't happen by construction. What this test
	/// actually pins is the *numeric result* of that shared derivation
	/// (0.5) against the reference's own `AddVarDCTDC` cancellation
	/// (`DCQuant(1) · InvDCQuant(2) · bFactor`), which the source coupling
	/// alone doesn't guarantee is still right.
	@Test("AC and DC factors both derive from the default correlation")
	func factorsMatchDefaultCorrelation() {
		// AC: `enc_group.cc`'s `x_factor`/`b_factor` at the default map.
		#expect(ACGroupEncoder.xFactor == 0)  // YtoXRatio(0) = base_correlation_x_ = 0
		// YtoBRatio(0) = base_correlation_b_ = kYToBRatio = 1
		#expect(ACGroupEncoder.bFactor == 1)

		// DC: `AddVarDCTDC`'s `y_factor · inv_factor` cancels every scale
		// term down to `DCQuant(1) · InvDCQuant(2)`, times `bFactor` above.
		let expectedB = ACGroupEncoder.dcQuant[1] * ACGroupEncoder.inverseDCQuant[2]
		#expect(expectedB == 0.5)
		#expect(ACGroupEncoder.dcCflFactor == [0, 0, expectedB * ACGroupEncoder.bFactor])
		#expect(ACGroupEncoder.dcCflFactor[0] == ACGroupEncoder.xFactor)
	}
}
