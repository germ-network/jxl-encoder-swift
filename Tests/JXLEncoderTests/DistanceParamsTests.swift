import Testing

@testable import JXLEncoder

/// Historical libjxl observations retained as diagnostic data; they do not
/// define Swift's native Float.pow results.
@Suite("DistanceParams")
struct DistanceParamsTests {
	struct Expected {
		let distance: Float
		let globalScale: Int
		let quantDC: Int
		let scaleBits: UInt32
		let scaleDCBits: UInt32
		let uniformQuant: UInt8
	}

	static let reference: [Expected] = [
		.init(
			distance: 0.03, globalScale: 32768, quantDC: 73, scaleBits: 0x3F00_0000,
			scaleDCBits: 0x4212_0000, uniformQuant: 53),
		.init(
			distance: 0.1, globalScale: 32768, quantDC: 22, scaleBits: 0x3F00_0000,
			scaleDCBits: 0x4130_0000, uniformQuant: 16),
		.init(
			distance: 0.25, globalScale: 28728, quantDC: 10, scaleBits: 0x3EE0_7000,
			scaleDCBits: 0x408C_4600, uniformQuant: 7),
		.init(
			distance: 0.5, globalScale: 15667, quantDC: 10, scaleBits: 0x3E74_CC00,
			scaleDCBits: 0x4018_FF80, uniformQuant: 7),
		.init(
			distance: 1.0, globalScale: 8813, quantDC: 10, scaleBits: 0x3E09_B400,
			scaleDCBits: 0x3FAC_2100, uniformQuant: 6),
		.init(
			distance: 1.5, globalScale: 6294, quantDC: 10, scaleBits: 0x3DC4_B000,
			scaleDCBits: 0x3F75_DC00, uniformQuant: 5),
		.init(
			distance: 2.0, globalScale: 4957, quantDC: 10, scaleBits: 0x3D9A_E800,
			scaleDCBits: 0x3F41_A200, uniformQuant: 5),
		.init(
			distance: 3.0, globalScale: 3451, quantDC: 10, scaleBits: 0x3D57_B000,
			scaleDCBits: 0x3F06_CE00, uniformQuant: 5),
		.init(
			distance: 5.0, globalScale: 2070, quantDC: 11, scaleBits: 0x3D01_6000,
			scaleDCBits: 0x3EB1_E400, uniformQuant: 5),
		.init(
			distance: 10.0, globalScale: 1035, quantDC: 13, scaleBits: 0x3C81_6000,
			scaleDCBits: 0x3E52_3C00, uniformQuant: 5),
	]

	static let cppPowObservations: [(distance: Float, bits: UInt32)] = [
		(3, 0x3F0A_5313), (5, 0x3EB5_0C64), (10, 0x3E4B_B0A8),
	]

	@Test("rejects lossless and negative distances")
	func rejectsInvalid() {
		#expect(throws: EncoderError.losslessNotSupported) {
			try DistanceParams(distance: 0)
		}
		#expect(throws: EncoderError.losslessNotSupported) {
			try DistanceParams(distance: -0.0)
		}
		#expect(throws: EncoderError.invalidDistance(-1)) {
			try DistanceParams(distance: -1)
		}
	}

	@Test(
		"non-finite distances throw invalidDistance",
		arguments: [Float.nan, .infinity, -.infinity])
	func rejectsNonFiniteDistances(distance: Float) {
		#expect {
			try DistanceParams(distance: distance)
		} throws: { error in
			guard case EncoderError.invalidDistance(let rejected) = error else {
				return false
			}
			return rejected.isNaN ? distance.isNaN : rejected == distance
		}
	}

	@Test("distances below 0.03 clamp to the same parameters")
	func clampsTinyDistances() throws {
		let tiny = try DistanceParams(distance: 0.001)
		let floor = try DistanceParams(distance: 0.03)
		#expect(tiny == floor)
	}
	@Test(
		"X matrix scales match upstream at distance transition boundaries")
	func matrixScalesMatchReferenceAtTransitionBounds() throws {
		let reference = try SemanticDump(fixture: "distance_filters")
		guard
			case .integers(let inputBits)? = reference.fields["distance_filters.inputs"],
			case .integers(let scales)? = reference.fields[
				"distance_filters.x_matrix_scale_effort4"]
		else {
			Issue.record("missing upstream X matrix scale observations")
			return
		}
		let distances = inputBits.map { Float(bitPattern: UInt32(truncatingIfNeeded: $0)) }
		#expect(distances.count == scales.count)
		for (distance, expected) in zip(distances, scales) {
			let actual = try DistanceParams(distance: distance).xQuantMatrixScale
			#expect(actual == expected, "distance bitPattern \(distance.bitPattern)")
		}
	}

	@Test(
		"X matrix scale reaches coefficient quantization and frame signaling")
	func matrixScaleFlowsThroughQuantizationAndSignaling() throws {
		let input = try StageDump(fixture: "edge_linear")
		let rect = Rect(
			x0: 0, y0: 0, maxWidth: Geometry.groupDim,
			maxHeight: Geometry.groupDim, xEnd: input.width, yEnd: input.height)
		let xyb = AdaptiveQuantPipeline.toXYB(
			PlaneBuffer.copyAndPad(
				source: input.interleaved, sourceWidth: input.width, rect: rect))
		let boundarySamples: [(Float, UInt32)] = [
			(Float(2.5).nextDown, 3), (2.5, 3), (Float(2.5).nextUp, 4),
			(Float(5.5).nextDown, 4), (5.5, 4), (Float(5.5).nextUp, 5),
			(Float(9.5).nextDown, 5), (9.5, 5), (Float(9.5).nextUp, 6),
		]
		let widthInBlocks = input.width / DCT.blockDim
		let heightInBlocks = input.height / DCT.blockDim
		let blockCount = widthInBlocks * heightInBlocks
		for (distance, expectedScale) in boundarySamples {
			let params = try DistanceParams(distance: distance)
			#expect(params.xQuantMatrixScale == expectedScale)
			var rawDC = [[Float]](
				repeating: [Float](repeating: 0, count: blockCount), count: 3)
			let actual = ACGroupEncoder.computeGroup(
				xyb: xyb, widthInBlocks: widthInBlocks,
				heightInBlocks: heightInBlocks,
				quantField: [UInt8](
					repeating: params.uniformQuant, count: blockCount),
				scale: params.scale,
				xQuantMatrixScale: params.xQuantMatrixScale,
				rawDC: &rawDC)
			var expectedX: [Int32] = []
			var expectedB: [Int32] = []
			for by in 0..<heightInBlocks {
				for bx in 0..<widthInBlocks {
					let originX = bx * DCT.blockDim
					let originY = by * DCT.blockDim
					let yDCT = DCT.forward8x8(
						pixels: xyb.planes[1], stride: xyb.width,
						originX: originX, originY: originY)
					let yRoundtrip = Quantizer.roundtripYBlockAC(
						coefficients: yDCT[...],
						quant: Int32(params.uniformQuant),
						scale: params.scale)
					let xDCT = DCT.forward8x8(
						pixels: xyb.planes[0], stride: xyb.width,
						originX: originX, originY: originY)
					expectedX += Quantizer.quantizeBlockAC(
						coefficients: xDCT[...], channel: 0,
						inverseMatrix: QuantMatrices.inverseMatrix(
							channel: 0),
						quant: Int32(params.uniformQuant),
						scale: params.scale,
						matrixMultiplier: Float.pow(
							1.25, Float(expectedScale) - 2.0))
					var bDCT = DCT.forward8x8(
						pixels: xyb.planes[2], stride: xyb.width,
						originX: originX, originY: originY)
					for i in 0..<DCT.blockSize {
						bDCT[i] = bDCT[i].addingProduct(
							-ACGroupEncoder.bFactor,
							yRoundtrip.reconstructed[i])
					}
					expectedB += Quantizer.quantizeBlockAC(
						coefficients: bDCT[...], channel: 2,
						inverseMatrix: QuantMatrices.inverseMatrix(
							channel: 2),
						quant: Int32(params.uniformQuant),
						scale: params.scale,
						matrixMultiplier: 1.0)
				}
			}
			#expect(actual[0] == expectedX)
			if expectedScale > 3 {
				let defaultX = ACGroupEncoder.computeGroup(
					xyb: xyb, widthInBlocks: widthInBlocks,
					heightInBlocks: heightInBlocks,
					quantField: [UInt8](
						repeating: params.uniformQuant, count: blockCount),
					scale: params.scale,
					xQuantMatrixScale: 3, rawDC: &rawDC)[0]
				#expect(expectedX != defaultX)
			}
			#expect(actual[2] == expectedB)
			var writer = BitWriter()
			FrameAssembly.writeFrameHeader(
				colorMode: .xyb(xQuantMatrixScale: params.xQuantMatrixScale),
				loopFilter: .init(
					gaborish: false, epfIterations: params.epfIterations),
				writer: &writer)
			writer.zeroPadToByte()
			let bits = Array(writer.take()).flatMap { byte in
				(0..<8).map { (byte >> $0) & 1 }
			}
			let signaledScale = bits[16..<19].enumerated().reduce(UInt32(0)) {
				$0 | (UInt32($1.element) << UInt32($1.offset))
			}
			#expect(signaledScale == expectedScale)
		}
	}

	@Test("QuantDC follows the native Float pow formula")
	func quantDCUsesNativePowFormula() {
		let dcMul: Float = 0.3
		let dcQuantPow: Float = 0.83
		let dcQuant: Float = 1.095_924_047_623_553
		for distance: Float in [0.5, 1, 3] {
			let base = (1 / dcMul) * distance
			let effective = dcMul * Float.pow(base, dcQuantPow)
			#expect(effective > 0.5 * distance && effective < distance)
			#expect(
				DistanceParams.quantDC(distance: distance)
					== min(dcQuant / effective, 50))
		}
	}

	@Test("QuantDC applies its effective-distance clamps and cap")
	func quantDCClampsAtRepresentativeInputs() {
		let dcMul: Float = 0.3
		let dcQuantPow: Float = 0.83
		let dcQuant: Float = 1.095_924_047_623_553
		let upperClampDistance: Float = 0.1
		let upperRaw =
			dcMul
			* Float.pow(
				(1 / dcMul) * upperClampDistance, dcQuantPow)
		#expect(upperRaw > upperClampDistance)
		#expect(
			DistanceParams.quantDC(distance: upperClampDistance)
				== min(dcQuant / upperClampDistance, 50))

		let lowerClampDistance: Float = 25
		let lowerRaw =
			dcMul
			* Float.pow(
				(1 / dcMul) * lowerClampDistance, dcQuantPow)
		#expect(lowerRaw < 0.5 * lowerClampDistance)
		#expect(
			DistanceParams.quantDC(distance: lowerClampDistance)
				== min(dcQuant / (0.5 * lowerClampDistance), 50))
		#expect(DistanceParams.quantDC(distance: 0.001) == 50)
	}

	@Test("DistanceParams scale reaches production DC quantization")
	func dcScaleFlowsThroughProductionQuantization() throws {
		let params = try DistanceParams(distance: 3)
		let yPlane = [Float](repeating: 1, count: DCT.blockSize)
		let stripe = PaddedStripe(
			width: DCT.blockDim, height: DCT.blockDim,
			planes: [
				[Float](repeating: 0, count: DCT.blockSize), yPlane,
				[Float](repeating: 0, count: DCT.blockSize),
			])
		var rawDC = [[Float]](repeating: [Float](repeating: 0, count: 1), count: 3)
		_ = ACGroupEncoder.computeGroup(
			xyb: stripe, widthInBlocks: 1, heightInBlocks: 1,
			quantField: [params.uniformQuant], scale: params.scale,
			xQuantMatrixScale: params.xQuantMatrixScale, rawDC: &rawDC)
		var data = DCGroupData(widthInBlocks: 1, heightInBlocks: 1)
		try DCGroupEncoder.preparePixel(rawDC: rawDC, scaleDC: params.scaleDC, data: &data)
		#expect(data.extraDCPrecision == 1)
		#expect(data.quantDC[1][0] != 0)
	}
}
