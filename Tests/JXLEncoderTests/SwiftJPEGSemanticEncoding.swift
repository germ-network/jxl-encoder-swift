@testable import JXLEncoder

enum SwiftJPEGSemanticEncoding {
	struct Result {
		let codestream: [UInt8]
		let decisions: SwiftJPEGFrameDecisions
	}

	static func encode(_ transcode: JPEGTranscode) throws -> Result {
		let alignment = (
			x: 1 << transcode.subsampling.maxHorizontalShift,
			y: 1 << transcode.subsampling.maxVerticalShift
		)
		let dim = ImageDim(
			width: transcode.width, height: transcode.height,
			blockAlignment: alignment)
		let blockContextMap = JPEGBlockContextMap.compute(transcode)
		var counts = [CoeffOrder.ZeroCounts](repeating: .init(), count: 3)
		for gy in 0..<dim.heightInGroups {
			for gx in 0..<dim.widthInGroups {
				let rect = dim.pixelRect(ix: gx, iy: gy, dim: Geometry.groupDim)
				let groupDim = ImageDim(
					width: rect.width, height: rect.height,
					blockAlignment: alignment)
				ACGroupEncoder.countZerosJPEG(
					transcode: transcode,
					blockX0: gx * Geometry.groupDimInBlocks,
					blockY0: gy * Geometry.groupDimInBlocks,
					widthInBlocks: groupDim.widthInBlocks,
					heightInBlocks: groupDim.heightInBlocks, into: &counts)
			}
		}
		let coeffOrder = CoeffOrder.compute(
			counts: counts, widthInBlocks: dim.widthInBlocks,
			heightInBlocks: dim.heightInBlocks)
		let baseCode = EntropyCode(
			contextMap: [UInt8](
				repeating: 0,
				count: blockContextMap.numContexts
					* (ACContext.nonZeroBuckets + ACContext.zeroDensityCount)),
			prefixCodes: [])
		var acGroups = [[StagedRecord]]()
		for gy in 0..<dim.heightInGroups {
			for gx in 0..<dim.widthInGroups {
				let rect = dim.pixelRect(ix: gx, iy: gy, dim: Geometry.groupDim)
				let groupDim = ImageDim(
					width: rect.width, height: rect.height,
					blockAlignment: alignment)
				var section = SectionWriter(mode: .staging(baseCode))
				var quantDC = (0..<3).map { channel in
					[Int16](
						repeating: 0,
						count:
							transcode.subsampling.blocksAcross(
								channel: channel,
								fullWidthInBlocks: groupDim
									.widthInBlocks)
							* transcode.subsampling.blocksDown(
								channel: channel,
								fullHeightInBlocks: groupDim
									.heightInBlocks))
				}
				ACGroupEncoder.encodeJPEG(
					transcode: transcode,
					blockX0: gx * Geometry.groupDimInBlocks,
					blockY0: gy * Geometry.groupDimInBlocks,
					widthInBlocks: groupDim.widthInBlocks,
					heightInBlocks: groupDim.heightInBlocks,
					quantDC: &quantDC, blockContextMap: blockContextMap,
					order: coeffOrder.orders, writer: &section)
				for record in section.staged {
					if case .rawBits = record {
						throw JPEGSemanticCaptureError.nonTokenACRecord(
							group: acGroups.count)
					}
				}
				acGroups.append(section.staged)
			}
		}
		var writer = BitWriter()
		let codes = try Encoder.encodeJPEGFrame(
			transcode, optimizeCodes: true, writer: &writer)
		let decisions = SwiftJPEGFrameDecisions(
			transcode: transcode, coeffOrder: coeffOrder,
			blockContextMap: blockContextMap, dcCode: codes.dc, acCode: codes.ac,
			acGroups: acGroups)
		return Result(codestream: try recompose(decisions), decisions: decisions)
	}

	static func recompose(_ d: SwiftJPEGFrameDecisions) throws -> [UInt8] {
		let t = d.transcode
		let alignment = (
			x: 1 << t.subsampling.maxHorizontalShift,
			y: 1 << t.subsampling.maxVerticalShift
		)
		let dim = ImageDim(width: t.width, height: t.height, blockAlignment: alignment)
		var dcData = (0..<dim.dcGroupCount).map { index in
			let rect = dim.pixelRect(
				ix: index % dim.widthInDCGroups, iy: index / dim.widthInDCGroups,
				dim: Geometry.dcGroupDim)
			let groupDim = ImageDim(
				width: rect.width, height: rect.height, blockAlignment: alignment)
			return DCGroupData(
				widthInBlocks: groupDim.widthInBlocks,
				heightInBlocks: groupDim.heightInBlocks, subsampling: t.subsampling)
		}
		for by in 0..<dim.heightInBlocks {
			for bx in 0..<dim.widthInBlocks {
				for channel in 0..<3
				where t.subsampling.codesBlock(
					channel: channel, blockX: bx, blockY: by)
				{
					if t.isGrayscale && channel != 1 { continue }
					let sx = t.subsampling.subsampledX(
						channel: channel, blockX: bx)
					let sy = t.subsampling.subsampledY(
						channel: channel, blockY: by)
					let component = t.component(channel)
					guard sx < component.blocksPerLine,
						sy < component.blocksPerColumn
					else {
						continue
					}
					let groupX = bx / (Geometry.dcGroupDim / Geometry.blockDim)
					let groupY = by / (Geometry.dcGroupDim / Geometry.blockDim)
					let index = groupY * dim.widthInDCGroups + groupX
					let localX = t.subsampling.subsampledX(
						channel: channel,
						blockX: bx - groupX
							* (Geometry.dcGroupDim / Geometry.blockDim))
					let localY = t.subsampling.subsampledY(
						channel: channel,
						blockY: by - groupY
							* (Geometry.dcGroupDim / Geometry.blockDim))
					guard localX < dcData[index].planeWidths[channel],
						localY < dcData[index].planeHeights[channel]
					else { continue }
					dcData[index].quantDC[channel][
						localY * dcData[index].planeWidths[channel] + localX
					] =
						Int16(
							clamping: t.dc(
								channel: channel, x: sx, y: sy))
				}
			}
		}

		let acRange = (2 + dim.dcGroupCount)..<(2 + dim.dcGroupCount + dim.groupCount)
		var sections = [SectionWriter](
			repeating: SectionWriter(mode: .staging(d.dcCode)),
			count: 2 + dim.dcGroupCount + dim.groupCount)
		for i in 0..<dim.groupCount {
			sections[acRange.lowerBound + i].staged = d.acGroups[i]
		}
		for i in 0..<dim.dcGroupCount {
			DCGroupEncoder.write(data: dcData[i], writer: &sections[1 + i])
			sections[1 + i].flush(code: d.dcCode)
		}
		for i in acRange { sections[i].flush(code: d.acCode) }
		var dcGlobal = BitWriter()
		try FrameAssembly.writeDCGlobal(
			params: try DistanceParams(distance: 1), dcGroupCount: dim.dcGroupCount,
			code: d.dcCode,
			dcQuantization: (0..<3).map { t.dcQuantization(channel: $0) },
			globalScale: FrameAssembly.jpegGlobalScale, quantDC: 1,
			blockContextMap: d.blockContextMap, allowContextMapANS: true,
			writer: &dcGlobal)
		sections[0] = SectionWriter(prewritten: dcGlobal)
		var acGlobal = BitWriter()
		try FrameAssembly.writeACGlobal(
			groupCount: dim.groupCount, code: d.acCode,
			quantTables: (0..<3).map { t.quantTable(channel: $0) },
			coeffOrder: d.coeffOrder, allowContextMapANS: true, writer: &acGlobal)
		sections[1 + dim.dcGroupCount] = SectionWriter(prewritten: acGlobal)
		var writer = BitWriter()
		try ImageHeader.write(
			width: t.width, height: t.height, transferFunction: .sRGB,
			xybEncoded: false, to: &writer)
		FrameAssembly.writeFrameHeader(
			colorMode: .ycbcr(subsampling: t.subsampling), epfIterations: 0,
			writer: &writer)
		FrameAssembly.combineSections(sections.map { $0.finished() }, writer: &writer)
		writer.zeroPadToByte()
		return writer.take()
	}

	static func contextWitness(
		_ transcode: JPEGTranscode, reference: SemanticDump
	) throws -> SemanticDump {
		func integers(_ name: String) throws -> [Int] {
			guard case .integers(let values)? = reference.fields[name] else {
				throw JPEGSemanticCaptureError.invalidReference(name)
			}
			return values.map(Int.init)
		}
		let thresholds = try integers("block_context.dc_thresholds.c1")
		let contextMap = try integers("block_context.ctx_map")
		let contextCountValues = try integers("block_context.num_ctxs")
		guard contextCountValues.count == 1,
			let contextCount = contextCountValues.first, contextCount > 0,
			contextMap.count == 3 * JPEGBlockContextMap.numOrders
				* (thresholds.count + 1),
			contextMap.allSatisfy({ (0...Int(UInt8.max)).contains($0) })
		else {
			throw JPEGSemanticCaptureError.invalidReference("block_context")
		}
		guard transcode.image.components.count == 3,
			!transcode.subsampling.is444,
			thresholds.count >= 1,
			transcode.blocksPerLine(channel: 1) >= 1,
			transcode.blocksPerColumn(channel: 1) >= 1
		else {
			throw JPEGSemanticCaptureError.unsupportedWitnessConfiguration
		}
		let orders = try (0..<3).map { channel in
			try integers("coeff_order.dct8.c\(channel)")
		}
		guard orders.allSatisfy({ $0.count == 64 && Set($0) == Set(0..<64) }) else {
			throw JPEGSemanticCaptureError.invalidReference("coeff_order.dct8")
		}
		let map = JPEGBlockContextMap.Result(
			thresholds: thresholds, contextMap: contextMap.map(UInt8.init),
			numContexts: contextCount)
		let dim = ImageDim(
			width: transcode.width, height: transcode.height,
			blockAlignment: (
				x: 1 << transcode.subsampling.maxHorizontalShift,
				y: 1 << transcode.subsampling.maxVerticalShift
			))
		let order = orders
		let baseCode = EntropyCode(
			contextMap: [UInt8](
				repeating: 0,
				count: contextCount
					* (ACContext.nonZeroBuckets + ACContext.zeroDensityCount)),
			prefixCodes: [])
		var dump = SemanticDump()
		let bucketCount = thresholds.count + 1
		var buckets = [Int64]()
		buckets.reserveCapacity(dim.widthInBlocks * dim.heightInBlocks)
		for y in 0..<dim.heightInBlocks {
			for x in 0..<dim.widthInBlocks {
				guard x < transcode.blocksPerLine(channel: 1),
					y < transcode.blocksPerColumn(channel: 1)
				else { throw JPEGSemanticCaptureError.invalidGeometry }
				buckets.append(
					Int64(map.bucket(dc: transcode.dc(channel: 1, x: x, y: y))))
			}
		}
		dump.record(
			"jpeg_context.size",
			.integers([
				Int64(dim.widthInBlocks), Int64(dim.heightInBlocks),
			]))
		dump.record("jpeg_context.group_count", .integers([Int64(dim.groupCount)]))
		dump.record("jpeg_context.buckets", .integers(buckets))
		dump.record("jpeg_context.bucket_count", .integers([Int64(bucketCount)]))
		var distinguishing = 0
		var equalities = 0
		for y in 0..<dim.heightInBlocks {
			for x in 0..<dim.widthInBlocks {
				let luma = transcode.dc(channel: 1, x: x, y: y)
				if thresholds.contains(where: { Int32($0) == luma }) {
					equalities += 1
				}
				for channel in [0, 2]
				where transcode.subsampling.codesBlock(
					channel: channel, blockX: x, blockY: y)
				{
					let wrongX = transcode.subsampling.subsampledX(
						channel: channel, blockX: x)
					let wrongY = transcode.subsampling.subsampledY(
						channel: channel, blockY: y)
					let wrongDC = transcode.dc(channel: 1, x: wrongX, y: wrongY)
					let correctContext = map.category(
						channel: channel, dcBucket: map.bucket(dc: luma))
					let wrongContext = map.category(
						channel: channel, dcBucket: map.bucket(dc: wrongDC))
					distinguishing += correctContext != wrongContext ? 1 : 0
				}
			}
		}
		dump.record(
			"jpeg_context.distinguishing_chroma_positions",
			.integers([Int64(distinguishing)]))
		dump.record("jpeg_context.threshold_equalities", .integers([Int64(equalities)]))
		for gy in 0..<dim.heightInGroups {
			for gx in 0..<dim.widthInGroups {
				let group = gy * dim.widthInGroups + gx
				let rect = dim.pixelRect(ix: gx, iy: gy, dim: Geometry.groupDim)
				let groupDim = ImageDim(
					width: rect.width, height: rect.height,
					blockAlignment: (
						x: 1 << transcode.subsampling.maxHorizontalShift,
						y: 1 << transcode.subsampling.maxVerticalShift
					))
				var quantDC = (0..<3).map { channel in
					[Int16](
						repeating: 0,
						count: transcode.subsampling.blocksAcross(
							channel: channel,
							fullWidthInBlocks: groupDim.widthInBlocks)
							* transcode.subsampling.blocksDown(
								channel: channel,
								fullHeightInBlocks: groupDim
									.heightInBlocks))
				}
				var section = SectionWriter(mode: .staging(baseCode))
				ACGroupEncoder.encodeJPEG(
					transcode: transcode,
					blockX0: gx * Geometry.groupDimInBlocks,
					blockY0: gy * Geometry.groupDimInBlocks,
					widthInBlocks: groupDim.widthInBlocks,
					heightInBlocks: groupDim.heightInBlocks,
					quantDC: &quantDC, blockContextMap: map,
					order: order, writer: &section)
				var tokens = [Int64]()
				for record in section.staged {
					guard case .token(let context, let value) = record else {
						throw JPEGSemanticCaptureError.nonTokenACRecord(
							group: group)
					}
					tokens.append(Int64(context))
					tokens.append(Int64(value))
				}
				let prefix = "jpeg_context.g\(group)"
				dump.record(
					"\(prefix).geometry",
					.integers([
						Int64(group), 0,
						Int64(gx * Geometry.groupDimInBlocks),
						Int64(gy * Geometry.groupDimInBlocks),
						Int64(groupDim.widthInBlocks),
						Int64(groupDim.heightInBlocks),
					]))
				dump.record(
					"\(prefix).token_count",
					.integers([Int64(tokens.count / 2)]))
				dump.record("\(prefix).tokens", .integers(tokens))
			}
		}
		return dump
	}

	static func dcBoundaryWitness(
		thresholds: [Int], dc: [Int32]
	) throws -> SemanticDump {
		let map = JPEGBlockContextMap.Result(
			thresholds: thresholds,
			contextMap: [UInt8](
				repeating: 0,
				count: 3 * JPEGBlockContextMap.numOrders * (thresholds.count + 1)),
			numContexts: 1)
		var dump = SemanticDump()
		dump.record(
			"jpeg_context.boundary",
			.integers(
				zip(dc, dc.map { Int32(map.bucket(dc: $0)) })
					.flatMap { [Int64($0.0), Int64($0.1)] }))
		return dump
	}
}

struct SwiftJPEGFrameDecisions {
	let transcode: JPEGTranscode
	let coeffOrder: CoeffOrder.Result
	let blockContextMap: JPEGBlockContextMap.Result
	let dcCode: EntropyCode
	let acCode: EntropyCode
	let acGroups: [[StagedRecord]]
}

enum JPEGSemanticCaptureError: Error {
	case invalidReference(String)
	case invalidGeometry
	case unsupportedWitnessConfiguration
	case nonTokenACRecord(group: Int)
}

extension SemanticDump {
	init(swiftJPEGDecisions d: SwiftJPEGFrameDecisions) throws {
		self.init()
		let t = d.transcode
		let dim = ImageDim(
			width: t.width, height: t.height,
			blockAlignment: (
				x: 1 << t.subsampling.maxHorizontalShift,
				y: 1 << t.subsampling.maxVerticalShift
			))
		try recordACEntropyCode(d.acCode)
		let map =
			d.acCode.originalContextMap?.map {
				d.acCode.contextMap[Int($0)]
			} ?? d.acCode.contextMap
		let tableCount = d.acCode.ansInfoTables?.count ?? d.acCode.prefixCodes.count
		let numACContexts =
			d.blockContextMap.numContexts
			* (ACContext.nonZeroBuckets + ACContext.zeroDensityCount)
		let histogramSetCount = 1
		guard map.count == histogramSetCount * numACContexts,
			map.allSatisfy({ Int($0) < tableCount })
		else {
			throw JPEGSemanticCaptureError.invalidReference(
				"JPEG AC context map shape or label range")
		}
		record("image_header.size", .integers([Int64(t.width), Int64(t.height)]))
		record("image_header.transfer_function", .integers([13]))
		record("image_header.color_space", .integers([t.isGrayscale ? 1 : 0]))
		record("image_header.white_point", .integers([1]))
		record("image_header.primaries", .integers([1]))
		record("image_header.rendering_intent", .integers([1]))
		record("image_header.xyb", .integers([0]))
		record("image_header.num_extra_channels", .integers([0]))
		record("image_sample_format.floating_point", .integers([0]))
		record("image_sample_format.bits_per_sample", .integers([8]))
		record("image_sample_format.exponent_bits_per_sample", .integers([0]))
		record("frame.encoding", .integers([0]))
		record("frame.groups", .integers([Int64(dim.groupCount)]))
		record("frame.dc_groups", .integers([Int64(dim.dcGroupCount)]))
		record("frame.passes", .integers([1]))
		record("frame_flags.flags", .integers([128]))
		record("gaborish.enabled", .integers([0]))
		record("epf.iterations", .integers([0]))
		record("x_matrix_scale.value", .integers([2]))
		record("b_matrix_scale.value", .integers([2]))
		for c in 0..<3 {
			record(
				"coeff_order.dct8.c\(c)",
				.integers(d.coeffOrder.orders[c].map(Int64.init)))
			record(
				"block_context.dc_thresholds.c\(c)",
				.integers(
					(c == 1 ? d.blockContextMap.thresholds : []).map(Int64.init)
				))
		}
		record(
			"coeff_order.nondefault_orders",
			.integers([
				d.coeffOrder.isCustom ? 1 : 0
			]))
		record("block_context.qf_thresholds", .integers([]))
		record(
			"block_context.ctx_map",
			.integers(d.blockContextMap.contextMap.map(Int64.init)))
		record("block_context.num_ctxs", .integers([Int64(d.blockContextMap.numContexts)]))
		record("context_map.num_histograms", .integers([1]))
		record("context_map.ac", .integers(map.map(Int64.init)))
		let quantCount = dim.widthInBlocks * dim.heightInBlocks
		record("quant_field.raw", .integers([Int64](repeating: 1, count: quantCount)))
		record(
			"quant_field.global_scale",
			.integers([Int64(FrameAssembly.jpegGlobalScale)]))
		record("quant_field.quant_dc", .integers([1]))
	}
}
