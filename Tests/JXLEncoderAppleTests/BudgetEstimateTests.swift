#if canImport(ImageIO)

	import Testing

	@testable import JXLEncoderApple

	/// The estimate decides what gets refused, so it has to bound reality rather
	/// than approximate it. These are measured peaks on Apple silicon: full-size
	/// encodes, and thumbnails taken from a 48 MP source through ImageIO's
	/// DCT-scaled decode. Where a case was seen at more than one value across
	/// runs the largest is recorded — peak RSS moves about 20 MB run to run.
	@Suite("Encode budget estimates")
	struct BudgetEstimateTests {
		/// (source width, source height, cap, measured peak bytes)
		static let measured: [(Int, Int, Int?, Int)] = [
			(1600, 1200, nil, 110 << 20),
			(4032, 3024, nil, 503 << 20),
			(5712, 4284, nil, 772 << 20),
			(8064, 6048, nil, 1388 << 20),
			(8064, 6048, 200, 24 << 20),
			(8064, 6048, 600, 45 << 20),
			(8064, 6048, 2000, 178 << 20),
			(8064, 6048, 4000, 425 << 20),
			(8064, 6048, 6000, 846 << 20),
			(1600, 1200, 200, 17 << 20),
			(4032, 3024, 600, 36 << 20),
		]

		@Test("the estimate bounds every measured peak")
		func boundsMeasurements() {
			for (width, height, cap, peak) in Self.measured {
				let estimate = JXLEncoderApple.estimatedEncodeBytes(
					width: width, height: height, maxPixelSize: cap)
				let label =
					"\(width)x\(height) cap \(cap.map(String.init) ?? "none"): "
					+ "estimated \(estimate >> 20) MB, measured \(peak >> 20) MB"
				#expect(estimate >= peak, "\(label)")
			}
		}

		/// Wildly loose bounds are safe but useless, so keep the overshoot in
		/// view: it should stay within about 2x.
		@Test("the estimate stays within 2x of measurement")
		func notWildlyLoose() {
			for (width, height, cap, peak) in Self.measured where peak > 100 << 20 {
				let estimate = JXLEncoderApple.estimatedEncodeBytes(
					width: width, height: height, maxPixelSize: cap)
				let label =
					"\(width)x\(height): estimated \(estimate >> 20) MB "
					+ "against \(peak >> 20) MB measured"
				#expect(estimate <= peak * 2, "\(label)")
			}
		}

		/// The default has to admit the size the encoder is designed around.
		@Test("the default budget admits a 12 MP encode")
		func defaultAdmitsDesignPoint() {
			#expect(
				JXLEncoderApple.estimatedEncodeBytes(width: 4032, height: 3024)
					<= JXLEncoderApple.defaultMaxSourceBytes)
			#expect(
				JXLEncoderApple.estimatedEncodeBytes(width: 8064, height: 6048)
					> JXLEncoderApple.defaultMaxSourceBytes,
				"48 MP is expected to need an explicit budget")
		}

		/// The two directions have to agree: a cap chosen to fit a budget must
		/// actually be estimated to fit it.
		@Test(
			"the cap that fits a budget fits it",
			arguments: [128 << 20, 256 << 20, 512 << 20, 1536 << 20])
		func capFitsBudget(budget: Int) throws {
			let cap = try #require(JXLEncoderApple.maxPixelSize(fitting: budget))
			let estimate = JXLEncoderApple.estimatedEncodeBytes(
				width: 8064, height: 6048, maxPixelSize: cap)
			#expect(estimate <= budget)
			// and one step larger should not
			let larger = JXLEncoderApple.estimatedEncodeBytes(
				width: 8064, height: 6048, maxPixelSize: cap + 64)
			#expect(larger > budget)
		}

		/// Below the fixed overhead nothing fits, and saying so beats returning a
		/// cap that cannot work.
		///
		/// This is a real floor, not a modelling artefact: the smallest encode
		/// measured, a 200 px thumbnail, still peaked at 17 MB. A caller with
		/// only tens of megabytes to spare cannot use this path at any size, and
		/// should learn that from `nil` rather than from being killed.
		@Test("a budget under the fixed overhead has no cap")
		func impossibleBudget() {
			#expect(JXLEncoderApple.maxPixelSize(fitting: 1 << 20) == nil)
			#expect(JXLEncoderApple.maxPixelSize(fitting: 0) == nil)
			#expect(JXLEncoderApple.maxPixelSize(fitting: -1) == nil)
			#expect(
				JXLEncoderApple.maxPixelSize(
					fitting: JXLEncoderApple.fixedOverheadBytes) == nil)
			#expect(
				JXLEncoderApple.maxPixelSize(
					fitting: JXLEncoderApple.fixedOverheadBytes + (16 << 20))
					!= nil)
		}
	}

#endif  // canImport(ImageIO)
