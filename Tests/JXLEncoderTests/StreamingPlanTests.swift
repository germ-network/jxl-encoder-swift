import Testing

@testable import JXLEncoder

/// libjxl streams a frame with more than eight AC groups unless it is
/// resampled, and then gives each DC group its own AC histogram set. Every
/// pixel driver has to reach the same layout.
@Suite("Streaming frame plan")
struct StreamingPlanTests {
	// MARK: Eligibility, on both sides of the eight-group boundary

	@Test("eight groups stay one-shot")
	func eightGroupsAreOneShot() {
		let plan = FramePlan(dim: ImageDim(width: 2048, height: 256), upsampling: 1)
		#expect(plan == .oneShot)
		#expect(plan.histogramSetCount == 1)
		#expect(plan.selectorBits == 0)
		#expect(plan.dcGroups.isEmpty)
	}

	@Test("nine groups in one DC group stream with one set")
	func nineGroupsInOneDCGroupStreamWithOneSet() {
		let plan = FramePlan(dim: ImageDim(width: 768, height: 768), upsampling: 1)
		#expect(plan.dcGroups.count == 1)
		#expect(plan.histogramSetCount == 1)
		#expect(plan.selectorBits == 0)
	}

	@Test("nine groups across two DC groups use two sets")
	func nineGroupsAcrossTwoDCGroupsUseTwoSets() {
		let plan = FramePlan(dim: ImageDim(width: 2304, height: 256), upsampling: 1)
		#expect(plan.dcGroups.count == 2)
		#expect(plan.histogramSetCount == 2)
		#expect(plan.selectorBits == 1)
	}

	@Test("a resampled frame stays one-shot above eight groups")
	func resampledFrameIsOneShot() {
		let plan = FramePlan(dim: ImageDim(width: 2304, height: 256), upsampling: 2)
		#expect(plan == .oneShot)
	}

	@Test("selector width is the ceiling log2 of the set count")
	func selectorWidthIsCeilLog2OfSetCount() {
		// 3x2 DC groups.
		let plan = FramePlan(dim: ImageDim(width: 4097, height: 2049), upsampling: 1)
		#expect(plan.histogramSetCount == 6)
		#expect(plan.selectorBits == 3)
		#expect(plan.histogramIndex(groupX: 16, groupY: 8) == 5)
		#expect(plan.histogramIndex(groupX: 8, groupY: 7) == 1)
	}

	// MARK: Set assignment and lifecycle, against the reference

	@Test("AC groups select their containing DC group's set")
	func histogramIndexIsContainingDCGroup() {
		let dim = ImageDim(width: 2057, height: 257)
		let plan = FramePlan(dim: dim, upsampling: 1)
		let selectors = (0..<dim.groupCount).map {
			plan.histogramIndex(
				groupX: $0 % dim.widthInGroups, groupY: $0 / dim.widthInGroups)
		}
		// Reference selectors from reference_2057x257.layout.sem.
		#expect(selectors == [0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1])
	}

	@Test("one-shot frames select set 0")
	func oneShotSelectsSetZero() {
		let plan = FramePlan(dim: ImageDim(width: 2048, height: 256), upsampling: 1)
		#expect(plan.histogramIndex(groupX: 7, groupY: 0) == 0)
	}

	static func lifecycleRecord(_ plan: FramePlan) -> [Int64] {
		plan.dcGroups.flatMap { group -> [Int64] in
			[
				group.index, group.initializesGlobalState ? 1 : 0,
				group.patch.x0, group.patch.y0, group.patch.width,
				group.patch.height, group.paddedWidth, group.paddedHeight,
				group.groupRect.x0, group.groupRect.y0, group.widthInBlocks,
				group.heightInBlocks,
			].map(Int64.init)
		}
	}

	@Test(
		"DC group lifecycle matches the reference record",
		arguments: [
			("pixel_lifecycle_2057x521", 2057, 521), ("flower_1024", 1024, 1024),
		])
	func lifecycleMatchesReference(fixture: String, width: Int, height: Int) throws {
		let plan = FramePlan(dim: ImageDim(width: width, height: height), upsampling: 1)
		let reference = try SemanticDump(fixture: fixture + ".stages")
		#expect(
			reference.fields["pixel_stages.dc_group_lifecycle"]
				== .integers(Self.lifecycleRecord(plan)))
	}

	@Test("the vertical lifecycle mirrors the horizontal one")
	func transposedLifecycleMirrorsReference() {
		// 2057x521 transposed: the border now clips along y, where the
		// reference frame never has a second DC group.
		let plan = FramePlan(dim: ImageDim(width: 521, height: 2057), upsampling: 1)
		#expect(
			Self.lifecycleRecord(plan) == [
				0, 1, 0, 0, 521, 2056, 528, 2056, 0, 0, 66, 256,
				1, 0, 0, 2040, 521, 17, 528, 24, 0, 8, 66, 2,
			])
	}

	// MARK: AC layout signalling

	@Test("AC global signals the set count less one")
	func acGlobalSignalsSetCountMinusOne() throws {
		func firstByte(sets: Int) throws -> UInt8 {
			var writer = BitWriter()
			try FrameAssembly.writeACGlobal(
				groupCount: 18, code: .staticAC, histogramSetCount: sets,
				writer: &writer)
			return writer.bytes[0]
		}
		// Bit 0 is the default-quant-matrices flag; the next ceil(log2(18)) = 5
		// bits are num_histograms - 1.
		#expect((try firstByte(sets: 1) >> 1) & 0x1F == 0)
		#expect((try firstByte(sets: 2) >> 1) & 0x1F == 1)
	}

	@Test("the selector stays outside the staged token stream")
	func selectorStaysOutsideStagedTokens() {
		var writer = SectionWriter(mode: .staging(.staticAC), contextOffset: 1980)
		writer.writeUnstaged(1, 1)
		writer.write(token: Token(context: 3, value: 0))
		#expect(writer.bitsWritten == 1)
		#expect(writer.staged.count == 1)
		guard case .token(let context, _) = writer.staged.first else {
			Issue.record("expected a staged token")
			return
		}
		#expect(context == 1983)
	}

	@Test("a direct-mode selector precedes the tokens")
	func directSelectorPrecedesTokens() {
		var withSelector = SectionWriter(mode: .direct(.staticAC), contextOffset: 0)
		withSelector.writeUnstaged(1, 1)
		var bare = SectionWriter(mode: .direct(.staticAC))
		for index in 0..<4 {
			let token = Token(context: UInt32(index), value: UInt32(index))
			withSelector.write(token: token)
			bare.write(token: token)
		}
		#expect(withSelector.bitsWritten == bare.bitsWritten + 1)
		let selected = withSelector.finished()
		let plain = bare.finished()
		#expect(Self.bit(selected, 0) == 1)
		for index in 0..<plain.bitsWritten {
			#expect(Self.bit(selected, index + 1) == Self.bit(plain, index))
		}
	}

	private static func bit(_ writer: BitWriter, _ index: Int) -> UInt8 {
		(writer.bytes[index / 8] >> UInt8(index % 8)) & 1
	}

	@Test("the selector still leads the section after an ANS flush")
	func selectorLeadsSectionAfterANSFlush() throws {
		func section(selector: Bool) -> SectionWriter {
			var writer = SectionWriter(mode: .staging(.staticAC), contextOffset: 0)
			if selector { writer.writeUnstaged(1, 1) }
			for index in 0..<400 {
				writer.write(
					token: Token(
						context: UInt32(index % 5), value: UInt32(index % 7)
					))
			}
			return writer
		}
		var sections = [section(selector: true), section(selector: false)]
		let code = SectionOptimizer.optimize(
			sections: &sections, range: 0..<2, baseCode: .staticAC, allowANS: true)
		#expect(code.ansInfoTables != nil)
		let selected = sections[0].finished()
		let bare = sections[1].finished()
		#expect(selected.bitsWritten == bare.bitsWritten + 1)
		#expect(Self.bit(selected, 0) == 1)
		for index in 0..<bare.bitsWritten {
			#expect(Self.bit(selected, index + 1) == Self.bit(bare, index))
		}
	}

	static func frame(width: Int, height: Int) throws -> (
		pixelFrame: Encoder.PixelFrameInput, params: DistanceParams
	) {
		let image = try ConcurrentEncodeTests.image(width: width, height: height)
		let params = try DistanceParams(distance: 1)
		let pixelFrame = Encoder.preparePixelFrame(
			stripeAt: Encoder.linearizingStripeSource(image),
			width: width, height: height, params: params)
		return (pixelFrame, params)
	}

	@Test("a streaming frame's AC code spans every set", arguments: [true, false])
	func streamingACCodeSpansEverySet(optimize: Bool) throws {
		let (pixelFrame, params) = try Self.frame(
			width: 2304, height: 256)
		let dim = pixelFrame.dim
		let computes = (0..<dim.groupCount).map {
			Encoder.computeACGroup(
				xybAt: pixelFrame.xybAt, dim: dim, groupX: $0 % dim.widthInGroups,
				groupY: $0 / dim.widthInGroups, params: params)
		}
		let analysis = Encoder.analyzePixelFrame(
			computes: computes, dim: dim, params: params, optimizeCodes: optimize)
		#expect(analysis.plan.histogramSetCount == 2)
		#expect(analysis.acCode.contextCount == 2 * analysis.acContextsPerSet)
		#expect(analysis.acCode.contextCount > analysis.acContextsPerSet)
		if !optimize {
			#expect(analysis.acContextsPerSet == ACContext.totalCount)
			#expect(
				Array(analysis.acCode.contextMap[ACContext.totalCount...])
					== EntropyCode.staticAC.contextMap)
		}
	}

	@Test("a streaming frame's optimized sections keep ANS")
	func streamingFrameKeepsANS() throws {
		let (pixelFrame, params) = try Self.frame(width: 2304, height: 256)
		let dim = pixelFrame.dim
		let computes = (0..<dim.groupCount).map {
			Encoder.computeACGroup(
				xybAt: pixelFrame.xybAt, dim: dim, groupX: $0 % dim.widthInGroups,
				groupY: $0 / dim.widthInGroups, params: params)
		}
		let analysis = Encoder.analyzePixelFrame(
			computes: computes, dim: dim, params: params, optimizeCodes: true)
		var sections = computes.map {
			Encoder.tokenizeACGroup(
				$0, analysis: analysis, mode: .staging(analysis.acCode)
			)
			.section
		}
		let code = SectionOptimizer.optimize(
			sections: &sections, range: 0..<sections.count, baseCode: analysis.acCode,
			allowANS: true)
		#expect(code.ansInfoTables != nil)
	}

	@Test("AC groups write their set's selector and context offset")
	func acGroupsWriteSelectorAndOffset() throws {
		let (pixelFrame, params) = try Self.frame(
			width: 2057, height: 257)
		let dim = pixelFrame.dim
		let analysis = Encoder.analyzePixelFrame(
			computes: [], dim: dim, params: params, optimizeCodes: false)
		let perSet = analysis.acContextsPerSet
		for (group, set) in [(0, 0), (8, 1)] {
			let compute = Encoder.computeACGroup(
				xybAt: pixelFrame.xybAt, dim: dim,
				groupX: group % dim.widthInGroups,
				groupY: group / dim.widthInGroups, params: params)
			let output = Encoder.tokenizeACGroup(
				compute, analysis: analysis, mode: .staging(analysis.acCode))
			#expect(output.section.writer.bitsWritten == 1)
			#expect(Int(output.section.writer.bytes[0] & 1) == set)
			let contexts = output.section.staged.compactMap { record -> Int? in
				if case .token(let context, _) = record { return Int(context) }
				return nil
			}
			#expect(!contexts.isEmpty)
			#expect(contexts.allSatisfy { $0 / perSet == set })
		}
	}

	// MARK: Every driver agrees above the boundary

	private struct InlineRunner: ParallelRunner {
		let maximumWorkers = 3
		func run(iterations: Int, _ operation: @Sendable (Int) -> Void) {
			for index in 0..<iterations { operation(index) }
		}
	}

	@Test(
		"parallel and concurrent drivers match serial above eight groups",
		arguments: [(2304, 256), (2057, 257)], [true, false])
	func driversMatchSerialAboveEightGroups(
		size: (Int, Int), optimize: Bool
	) async throws {
		let image = try ConcurrentEncodeTests.image(width: size.0, height: size.1)
		let serial = try Encoder.encode(image, distance: 1, optimizeCodes: optimize)
		let concurrent = try await Encoder.encodeConcurrently(
			image, distance: 1, optimizeCodes: optimize)
		#expect(serial == concurrent)
		if #available(iOS 18, macOS 15, *) {
			let parallel = try Encoder.encode(
				image, distance: 1, optimizeCodes: optimize,
				runner: InlineRunner())
			#expect(serial == parallel)
		}
	}

	@Test("the semantic replica matches production above eight groups")
	func replicaMatchesProductionAboveEightGroups() throws {
		let image = try ConcurrentEncodeTests.image(width: 2057, height: 257)
		let replica = try SwiftSemanticEncoding.encode(image, distance: 1)
		#expect(replica.codestream == (try Encoder.encode(image, distance: 1)))
	}
}
