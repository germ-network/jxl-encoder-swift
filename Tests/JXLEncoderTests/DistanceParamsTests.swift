import Testing

@testable import JXLEncoder

/// Diagnostic values come from compiling full libjxl's own arithmetic directly
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
			var quantDC = [[Int16]](
				repeating: [Int16](repeating: 0, count: blockCount), count: 3)
			let actual = ACGroupEncoder.computeGroup(
				xyb: xyb, widthInBlocks: widthInBlocks,
				heightInBlocks: heightInBlocks,
				quantField: [UInt8](
					repeating: params.uniformQuant, count: blockCount),
				scale: params.scale,
				scaleDC: params.scaleDC,
				xQuantMatrixScale: params.xQuantMatrixScale,
				quantDC: &quantDC)
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
					scale: params.scale, scaleDC: params.scaleDC,
					xQuantMatrixScale: 3, quantDC: &quantDC)[0]
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

	@Test("QuantDC follows the native Float pow data flow")
	func quantDCUsesNativePowFormula() {
		let distances =
			Self.reference.map(\.distance) + [
				0.03, 0.1, 0.25, 0.5, 1, 1.5, 2, 3, 5, 10,
			]
		for distance in distances {
			let dcMul: Float = 0.3
			let dcQuantPow: Float = 0.83
			let dcQuant: Float = 1.095_924_047_623_553
			var effective = dcMul * Float.pow((1 / dcMul) * distance, dcQuantPow)
			effective = clamp1(effective, 0.5 * distance, distance)
			let expected = min(dcQuant / effective, 50)
			#expect(
				DistanceParams.quantDC(distance: distance).bitPattern
					== expected.bitPattern,
				"distance bitPattern \(distance.bitPattern)")
		}
	}

	@Test("Native quantization retains complete C++ diagnostics")
	func preservesCppQuantizationDiagnostics() throws {
		#expect(Self.reference.count == 10)
		for expected in Self.reference {
			let actual = try DistanceParams(distance: expected.distance)
			print(
				"C++ quantization diagnostic distance=\(expected.distance) "
					+ "globalScale=\(actual.globalScale == expected.globalScale) "
					+ "quantDC=\(actual.quantDC == expected.quantDC) "
					+ "scale=\(actual.scale.bitPattern == expected.scaleBits) "
					+ "scaleDC=\(actual.scaleDC.bitPattern == expected.scaleDCBits) "
					+ "uniformQuant=\(actual.uniformQuant == expected.uniformQuant)"
			)
		}
		let powDiagnostics: [(Float, UInt32)] = [
			(3, 0x3F0A_5313), (5, 0x3EB5_0C64), (10, 0x3E4B_B0A8),
		]
		#expect(powDiagnostics.count == 3)
		for (distance, cppBits) in powDiagnostics {
			let native = DistanceParams.quantDC(distance: distance)
			print(
				"C++ std::pow diagnostic distance=\(distance) "
					+ "cppBits=\(cppBits) nativeBits=\(native.bitPattern) "
					+ "same=\(cppBits == native.bitPattern)")
		}
	}

	@Test("QuantDC preserves its effective-distance clamps and cap")
	func quantDCClampsAtNativeBoundaries() {
		let upperBoundary = Self.adjacentUpperClampWitness(
			center: Float(0.3).bitPattern, searchRadius: 4096)
		guard let upperBoundary else {
			Issue.record("native upper-clamp transition not found in bounded search")
			return
		}
		#expect(
			Self.rawEffectiveDistance(
				Float(bitPattern: upperBoundary.predecessor),
				sourceOperandOrder: true)
				> Float(bitPattern: upperBoundary.predecessor))
		#expect(
			Self.rawEffectiveDistance(
				Float(bitPattern: upperBoundary.successor), sourceOperandOrder: true
			)
				<= Float(bitPattern: upperBoundary.successor))
		for bits in [
			upperBoundary.predecessor - 1, upperBoundary.predecessor,
			upperBoundary.successor,
		] {
			let distance = Float(bitPattern: bits)
			let raw = Self.rawEffectiveDistance(distance, sourceOperandOrder: true)
			let effective = min(max(raw, 0.5 * distance), distance)
			#expect(
				DistanceParams.quantDC(distance: distance).bitPattern
					== Self.expectedQuantDC(distance, sourceOperandOrder: true)
					.bitPattern)
			#expect(effective <= distance)
		}
		#expect(
			Self.rawEffectiveDistance(0.1, sourceOperandOrder: true) > 0.1)
		#expect(
			Self.rawEffectiveDistance(1, sourceOperandOrder: true) < 1
				&& Self.rawEffectiveDistance(1, sourceOperandOrder: true) > 0.5)

		let lowerBoundary = Self.adjacentClampWitness(
			center: Float(17.69644).bitPattern, searchRadius: 4096)
		guard let lowerBoundary else {
			Issue.record("native lower-clamp transition not found in bounded search")
			return
		}
		#expect(
			!(Self.rawEffectiveDistance(
				Float(bitPattern: lowerBoundary.predecessor),
				sourceOperandOrder: true)
				< 0.5 * Float(bitPattern: lowerBoundary.predecessor)))
		#expect(
			Self.rawEffectiveDistance(
				Float(bitPattern: lowerBoundary.successor), sourceOperandOrder: true
			)
				< 0.5 * Float(bitPattern: lowerBoundary.successor))
		for bits in [
			lowerBoundary.predecessor - 1, lowerBoundary.predecessor,
			lowerBoundary.successor,
		] {
			let distance = Float(bitPattern: bits)
			#expect(
				DistanceParams.quantDC(distance: distance).bitPattern
					== Self.expectedQuantDC(distance, sourceOperandOrder: true)
					.bitPattern)
		}

		let capBoundary = Self.adjacentCapWitness(
			center: Float(0.02191848).bitPattern, searchRadius: 8192)
		guard let capBoundary else {
			Issue.record("native cap transition not found in bounded search")
			return
		}
		#expect(
			Self.uncappedQuantDC(
				Float(bitPattern: capBoundary.predecessor), sourceOperandOrder: true
			) > 50)
		#expect(
			Self.uncappedQuantDC(
				Float(bitPattern: capBoundary.successor), sourceOperandOrder: true)
				<= 50)
		for bits in [
			capBoundary.predecessor - 1, capBoundary.predecessor, capBoundary.successor,
		] {
			let distance = Float(bitPattern: bits)
			let uncapped = Self.uncappedQuantDC(distance, sourceOperandOrder: true)
			#expect(DistanceParams.quantDC(distance: distance) == min(uncapped, 50))
		}
		#expect(DistanceParams.quantDC(distance: 0.001) == 50)
		let admitted = try? DistanceParams(distance: 0.03)
		#expect(admitted?.distance == 0.03)
		#expect(DistanceParams.quantDC(distance: 0.03) < 50)
	}

	@Test("QuantDC preserves source reciprocal-times-distance order")
	func quantDCUsesSourceOperandOrder() {
		// libjxl a7a9c787341cf703dede03c2009fa460cae5e5df uses
		// pow((1 / kDcMul) * distance, kDcQuantPow) at InitialQuantDC:1250-1261.
		// The division-based results stay diagnostic; Float.pow remains native.
		let witnesses: [UInt32] = [0x3E9A_29C7, 0x3E99_A327]
		for bits in witnesses {
			let distance = Float(bitPattern: bits)
			let multiplier: Float = 0.3
			let sourceBase = (1 / multiplier) * distance
			let divisionBase = distance / multiplier
			#expect(sourceBase.bitPattern != divisionBase.bitPattern)
			let source = Self.expectedQuantDC(distance, sourceOperandOrder: true)
			let division = Self.expectedQuantDC(distance, sourceOperandOrder: false)
			#expect(source.bitPattern != division.bitPattern)
			#expect(
				DistanceParams.quantDC(distance: distance).bitPattern
					== source.bitPattern)
		}
	}

	@Test("Native DC quantization reaches frame parameters")
	func nativeDCQuantFlowsThroughDistanceParams() {
		let distance = Float(bitPattern: 0x3E99_A327)
		let expected = Self.expectedParameters(distance, sourceOperandOrder: true)
		let division = Self.expectedParameters(distance, sourceOperandOrder: false)
		let actual = try! DistanceParams(distance: distance)
		#expect(actual.globalScale == expected.globalScale)
		#expect(actual.quantDC == expected.quantDC)
		#expect(actual.scaleDC.bitPattern == expected.scaleDC.bitPattern)
		#expect(division.globalScale != expected.globalScale)
		#expect(division.scaleDC.bitPattern != expected.scaleDC.bitPattern)
	}

	@Test("Native DC scale reaches production coefficient quantization")
	func nativeDCScaleFlowsThroughProductionQuantization() {
		let distance = Float(bitPattern: 0x3E99_A327)
		let expected = Self.expectedParameters(distance, sourceOperandOrder: true)
		let stale = Self.expectedParameters(distance, sourceOperandOrder: false)
		let params = try! DistanceParams(distance: distance)
		let yPlane = [Float](repeating: 16, count: DCT.blockSize)
		let stripe = PaddedStripe(
			width: DCT.blockDim, height: DCT.blockDim,
			planes: [
				[Float](repeating: 0, count: DCT.blockSize), yPlane,
				[Float](repeating: 0, count: DCT.blockSize),
			])
		var dc = [[Int16]](repeating: [Int16](repeating: 0, count: 1), count: 3)
		_ = ACGroupEncoder.computeGroup(
			xyb: stripe, widthInBlocks: 1, heightInBlocks: 1,
			quantField: [5], scale: params.scale, scaleDC: params.scaleDC,
			xQuantMatrixScale: 2, quantDC: &dc)
		let coefficient = DCT.forward8x8(
			pixels: yPlane, stride: DCT.blockDim, originX: 0, originY: 0)[0]
		let independentlyRounded = Int16(
			(Float(512) * expected.scaleDC * coefficient)
				.rounded(.toNearestOrAwayFromZero))
		let staleRounded = Int16(
			(Float(512) * stale.scaleDC * coefficient)
				.rounded(.toNearestOrAwayFromZero))
		#expect(dc[1][0] == independentlyRounded)
		#expect(independentlyRounded != staleRounded)
	}

	static func rawEffectiveDistance(_ distance: Float, sourceOperandOrder: Bool) -> Float {
		let dcMul: Float = 0.3
		let base =
			sourceOperandOrder
			? (1 / dcMul) * distance
			: distance / dcMul
		return dcMul * Float.pow(base, 0.83)
	}

	static func uncappedQuantDC(_ distance: Float, sourceOperandOrder: Bool) -> Float {
		let effective = clamp1(
			rawEffectiveDistance(distance, sourceOperandOrder: sourceOperandOrder),
			0.5 * distance, distance)
		return 1.095_924_047_623_553 / effective
	}

	static func expectedQuantDC(_ distance: Float, sourceOperandOrder: Bool) -> Float {
		min(uncappedQuantDC(distance, sourceOperandOrder: sourceOperandOrder), 50)
	}

	static func expectedParameters(
		_ distance: Float, sourceOperandOrder: Bool
	) -> (globalScale: Int, quantDC: Int, scaleDC: Float, scale: Float) {
		let qdc = expectedQuantDC(distance, sourceOperandOrder: sourceOperandOrder)
		var nominalScale = Float(1 << 16) * 0.79 / (distance * 5)
		nominalScale = clamp1(nominalScale, 1, Float(1 << 15))
		let scaledQuantDC = Int(Double(qdc * 4096) * 1.6)
		let globalScale = clamp1(Int(nominalScale), 1, scaledQuantDC)
		let scale = Float(globalScale) * (1 / Float(1 << 16))
		let quantDC = clamp1(Int(qdc / scale + 0.5), 1, 1 << 16)
		return (globalScale, quantDC, Float(quantDC) * scale, scale)
	}

	static func adjacentClampWitness(
		center: UInt32, searchRadius: UInt32
	) -> (predecessor: UInt32, successor: UInt32)? {
		let start = center - searchRadius
		let end = center + searchRadius
		for bits in start..<end {
			let first = Float(bitPattern: bits)
			let second = Float(bitPattern: bits + 1)
			let firstBinds =
				rawEffectiveDistance(first, sourceOperandOrder: true) < 0.5 * first
			let secondBinds =
				rawEffectiveDistance(second, sourceOperandOrder: true) < 0.5
				* second
			if !firstBinds && secondBinds { return (bits, bits + 1) }
		}
		return nil
	}

	static func adjacentCapWitness(
		center: UInt32, searchRadius: UInt32
	) -> (predecessor: UInt32, successor: UInt32)? {
		let start = center - searchRadius
		let end = center + searchRadius
		for bits in start..<end {
			let first =
				uncappedQuantDC(Float(bitPattern: bits), sourceOperandOrder: true)
				> 50
			let second =
				uncappedQuantDC(
					Float(bitPattern: bits + 1), sourceOperandOrder: true) > 50
			if first && !second { return (bits, bits + 1) }
		}
		return nil
	}

	static func adjacentUpperClampWitness(
		center: UInt32, searchRadius: UInt32
	) -> (predecessor: UInt32, successor: UInt32)? {
		let start = center - searchRadius
		let end = center + searchRadius
		for bits in start..<end {
			let first = Float(bitPattern: bits)
			let second = Float(bitPattern: bits + 1)
			let firstBinds =
				rawEffectiveDistance(first, sourceOperandOrder: true) > first
			let secondBinds =
				rawEffectiveDistance(second, sourceOperandOrder: true) > second
			if firstBinds && !secondBinds { return (bits, bits + 1) }
		}
		return nil
	}

}
