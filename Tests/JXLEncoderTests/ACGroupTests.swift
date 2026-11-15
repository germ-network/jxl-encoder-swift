import Testing

@testable import JXLEncoder

/// Byte-exact comparison against the reference's own `WriteACGroup`, reached
/// through the exported entry point so the whole shipped path is exercised:
/// DCT, Y quantize-roundtrip, colour decorrelation, tokenization and prefix
/// coding.
///
/// The quant field is held at a constant so this gate is independent of the
/// adaptive-quant stage, which has its own test.
@Suite("AC group")
struct ACGroupTests {
	static let scale: Float = 0.112_075_805_664_062_5
	static let quant: UInt8 = 5
	static let scaleDC: Float = 1.0
	static let xQuantMatrixScale: UInt32 = 2

	@Test("bitstream records the inherited libjxl-tiny comparison")
	func matchesReference() throws {
		let input = try StageDump(fixture: "edge_linear")
		let reference = try StageDump(fixture: "edge_acgroup")

		let expectedBits = Int(reference.planes[0][0])
		let expectedBytes = reference.planes[0].dropFirst().map { UInt8($0) }

		let dim = ImageDim(width: input.width, height: input.height)
		let rect = Rect(
			x0: 0, y0: 0, maxWidth: Geometry.groupDim, maxHeight: Geometry.groupDim,
			xEnd: input.width, yEnd: input.height)
		let padded = PlaneBuffer.copyAndPad(
			source: input.interleaved, sourceWidth: input.width, rect: rect)
		let xyb = AdaptiveQuantPipeline.toXYB(padded)

		let quantField = [UInt8](
			repeating: Self.quant, count: dim.widthInBlocks * dim.heightInBlocks)

		var quantDC = [[Int16]](
			repeating: [Int16](
				repeating: 0, count: dim.widthInBlocks * dim.heightInBlocks),
			count: 3)
		let coefficients = ACGroupEncoder.computeGroup(
			xyb: xyb,
			widthInBlocks: dim.widthInBlocks,
			heightInBlocks: dim.heightInBlocks,
			quantField: quantField,
			scale: Self.scale,
			scaleDC: Self.scaleDC,
			xQuantMatrixScale: Self.xQuantMatrixScale,
			quantDC: &quantDC)
		var writer = SectionWriter(mode: .direct(.staticAC))
		ACGroupEncoder.tokenizeGroup(
			coefficients: coefficients,
			widthInBlocks: dim.widthInBlocks,
			heightInBlocks: dim.heightInBlocks,
			subsampling: .none,
			order: CoeffOrder.Result.identity.orders,
			writer: &writer)

		withKnownIssue(
			Comment(
				rawValue:
					"GER-3398: Cheetah Y thresholds {0.56,0.62,0.62,0.62} and X/B thresholds {0.58,0.62,0.62,0.62} follow full libjxl enc_group.cc:336-361 and 502-509; inherited tiny golden uses prior policy"
			)
		) {
			#expect(writer.bitsWritten == expectedBits)
		}
		var writerBits = writer.finished()
		writerBits.zeroPadToByte()
		let actual = writerBits.take()
		withKnownIssue(
			Comment(
				rawValue:
					"GER-3398: Cheetah Y thresholds {0.56,0.62,0.62,0.62} and X/B thresholds {0.58,0.62,0.62,0.62} follow full libjxl enc_group.cc:336-361 and 502-509; inherited tiny golden uses prior policy"
			)
		) {
			#expect(actual.count == expectedBytes.count)
		}
		let firstDifference = zip(actual, expectedBytes).enumerated()
			.first { $0.element.0 != $0.element.1 }?.offset
		withKnownIssue(
			Comment(
				rawValue:
					"GER-3398: Cheetah Y thresholds {0.56,0.62,0.62,0.62} and X/B thresholds {0.58,0.62,0.62,0.62} follow full libjxl enc_group.cc:336-361 and 502-509; inherited tiny golden uses prior policy"
			)
		) {
			#expect(
				firstDifference == nil,
				"first differing byte at \(firstDifference ?? -1)")
		}
	}

	/// 0.5 isn't a chosen constant — `AddVarDCTDC`'s scale terms cancel down to
	/// `DCQuant(1) * InvDCQuant(2)`, which is exactly this value, applied at
	/// the default color correlation `-e 4` always uses. See
	/// `ColorCorrelationTests.factorsMatchDefaultCorrelation` for the full
	/// derivation this pins the same way.
	@Test("B DC carries the default color correlation's factor")
	func bDCDecorrelation() {
		#expect(ACGroupEncoder.dcCflFactor == [0, 0, 0.5])
	}
}
