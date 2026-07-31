//
//  Encoder.swift
//  JXLEncoder
//
//  Top level: ports `EncodeFrame` and `EncodeFile` from libjxl-tiny's
//  encoder/enc_frame.cc and encoder/enc_file.cc.
//
//  Sections are laid out as DC global, one per DC group, AC global, one per AC
//  group. DC groups are 2048 px and AC groups 256 px, so a DC group holds up to
//  8x8 AC groups.
//

/// An image ready to encode: 8-bit sRGB samples, interleaved.
public struct ImageBuffer: Sendable {
	public let width: Int
	public let height: Int
	/// Row-major, `channels` samples per pixel.
	public let samples: [UInt8]
	/// 3 or 4. A fourth channel is stride only — the encoder ignores it, so
	/// alpha must be flattened before reaching the core (the shim's job).
	public let channels: Int

	public init(width: Int, height: Int, samples: [UInt8], channels: Int = 3) throws {
		guard width > 0, height > 0 else { throw EncoderError.emptyImage }
		guard channels == 3 || channels == 4 else {
			throw EncoderError.unsupportedChannelCount(channels)
		}
		// Overflow here means the dimensions are absurd, not that the count is
		// merely wrong — and a throwing initializer must not trap.
		let (pixels, overflowA) = width.multipliedReportingOverflow(by: height)
		let (expected, overflowB) = pixels.multipliedReportingOverflow(by: channels)
		guard !overflowA, !overflowB else {
			throw EncoderError.imageTooLarge(width: width, height: height)
		}
		guard samples.count == expected else {
			throw EncoderError.pixelCountMismatch(
				expected: expected, actual: samples.count)
		}
		self.width = width
		self.height = height
		self.samples = samples
		self.channels = channels
	}
}

public enum Encoder {
	/// Converts 8-bit sRGB samples to the linear light the transform expects.
	static func linearize(_ image: ImageBuffer) -> [Float] {
		let count = image.width * image.height
		var linear = [Float](repeating: 0, count: count * 3)
		for i in 0..<count {
			for c in 0..<3 {
				linear[i * 3 + c] = SRGBTransfer.linearize(
					image.samples[i * image.channels + c])
			}
		}
		return linear
	}

	/// Encodes one DC group: every AC group inside it, then the DC group itself.
	static func encodeDCGroup(
		linear: [Float],
		dim: ImageDim,
		dcGroupX: Int,
		dcGroupY: Int,
		params: DistanceParams,
		sections: inout [SectionWriter]
	) {
		let dcGroupRect = dim.pixelRect(
			ix: dcGroupX, iy: dcGroupY, dim: Geometry.dcGroupDim)
		let dcGroupDim = ImageDim(width: dcGroupRect.width, height: dcGroupRect.height)

		var data = DCGroupData(
			widthInBlocks: dcGroupDim.widthInBlocks,
			heightInBlocks: dcGroupDim.heightInBlocks)

		for gy in 0..<dcGroupDim.heightInGroups {
			for gx in 0..<dcGroupDim.widthInGroups {
				// A DC group spans kBlockDim AC groups on each axis.
				let imageGX = dcGroupX * Geometry.blockDim + gx
				let imageGY = dcGroupY * Geometry.blockDim + gy
				let acIndex =
					2 + dim.dcGroupCount + imageGY * dim.widthInGroups + imageGX

				let groupRect = dim.pixelRect(
					ix: imageGX, iy: imageGY, dim: Geometry.groupDim)
				let groupDim = ImageDim(
					width: groupRect.width, height: groupRect.height)

				// The quant field is computed stripe by stripe over the group.
				var quantField = [UInt8](
					repeating: 1,
					count: groupDim.widthInBlocks * groupDim.heightInBlocks)
				var xybPlanes = [[Float]](
					repeating: [Float](
						repeating: 0,
						count: groupDim.widthInBlocks * Geometry.blockDim
							* groupDim.heightInBlocks
							* Geometry.blockDim),
					count: 3)
				let paddedWidth = groupDim.widthInBlocks * Geometry.blockDim

				for ty in 0..<groupDim.heightInTiles {
					let stripeRect = Rect(
						x0: groupRect.x0,
						y0: groupRect.y0 + ty * Geometry.tileDim,
						maxWidth: Geometry.groupDim,
						maxHeight: Geometry.tileDim,
						xEnd: dim.width, yEnd: dim.height)
					let padded = PlaneBuffer.copyAndPad(
						source: linear, sourceWidth: dim.width,
						rect: stripeRect)
					let xyb = AdaptiveQuantPipeline.toXYB(padded)

					// Keep the group's XYB so the AC pass sees the same values.
					let rowOffset =
						ty * Geometry.tileDimInBlocks * Geometry.blockDim
					for c in 0..<3 {
						for y in 0..<padded.height {
							let destRow = (rowOffset + y) * paddedWidth
							guard
								destRow + padded.width
									<= xybPlanes[c].count
							else {
								continue
							}
							for x in 0..<padded.width {
								xybPlanes[c][destRow + x] =
									xyb.planes[c][
										y * padded.width + x
									]
							}
						}
					}

					let tilesAcross = Geometry.divCeil(
						padded.width, Geometry.tileDim)
					for tx in 0..<tilesAcross {
						let tileRect = Rect(
							x0: tx * Geometry.tileDimInBlocks, y0: 0,
							maxWidth: Geometry.tileDimInBlocks,
							maxHeight: Geometry.tileDimInBlocks,
							xEnd: padded.width / Geometry.blockDim,
							yEnd: padded.height / Geometry.blockDim)
						let aqMap = AdaptiveQuant.computeTile(
							stripe: xyb, rect: tileRect,
							distance: params.distance)
						let raw = AdaptiveQuant.rawQuantField(
							aqMap: aqMap,
							inverseScale: params.inverseScale)
						for y in 0..<tileRect.height {
							let by = ty * Geometry.tileDimInBlocks + y
							guard by < groupDim.heightInBlocks else {
								continue
							}
							for x in 0..<tileRect.width {
								let bx = tileRect.x0 + x
								guard bx < groupDim.widthInBlocks
								else { continue }
								quantField[
									by * groupDim.widthInBlocks
										+ bx] =
									raw[y * tileRect.width + x]
							}
						}
					}
				}

				// Record the quant field into the DC group's own grid.
				let blockX0 = gx * Geometry.groupDimInBlocks
				let blockY0 = gy * Geometry.groupDimInBlocks
				for by in 0..<groupDim.heightInBlocks {
					for bx in 0..<groupDim.widthInBlocks {
						let target =
							(blockY0 + by) * data.widthInBlocks
							+ blockX0 + bx
						guard target < data.rawQuantField.count else {
							continue
						}
						data.rawQuantField[target] =
							quantField[by * groupDim.widthInBlocks + bx]
					}
				}

				let groupXYB = PaddedStripe(
					width: paddedWidth,
					height: groupDim.heightInBlocks * Geometry.blockDim,
					planes: xybPlanes)
				var groupDC = [[Int16]](
					repeating: [Int16](
						repeating: 0,
						count: groupDim.widthInBlocks
							* groupDim.heightInBlocks),
					count: 3)

				ACGroupEncoder.encode(
					xyb: groupXYB,
					widthInBlocks: groupDim.widthInBlocks,
					heightInBlocks: groupDim.heightInBlocks,
					quantField: quantField,
					scale: params.scale,
					scaleDC: params.scaleDC,
					xQuantMatrixScale: params.xQuantMatrixScale,
					quantDC: &groupDC,
					writer: &sections[acIndex])

				for c in 0..<3 {
					for by in 0..<groupDim.heightInBlocks {
						for bx in 0..<groupDim.widthInBlocks {
							let target =
								(blockY0 + by) * data.widthInBlocks
								+ blockX0 + bx
							guard target < data.quantDC[c].count else {
								continue
							}
							data.quantDC[c][target] =
								groupDC[c][
									by * groupDim.widthInBlocks
										+ bx]
						}
					}
				}
			}
		}

		let dcIndex = 1 + dcGroupY * dim.widthInDCGroups + dcGroupX
		DCGroupEncoder.write(data: data, writer: &sections[dcIndex])
	}

	static func encodeFrame(
		linear: [Float], width: Int, height: Int, params: DistanceParams,
		optimizeCodes: Bool = true,
		writer: inout BitWriter
	) throws {
		let dim = ImageDim(width: width, height: height)
		var dcCode = EntropyCode.staticDC
		var acCode = EntropyCode.staticAC

		// Staging defers entropy coding until the image's own statistics are
		// known. The static tables ship in full on every file otherwise, which
		// dominates small images.
		let mode: SectionWriter.Mode =
			optimizeCodes ? .staging(dcCode) : .direct(dcCode)
		var sections = [SectionWriter](
			repeating: SectionWriter(mode: mode),
			count: 2 + dim.dcGroupCount + dim.groupCount)
		let acRange = (2 + dim.dcGroupCount)..<(2 + dim.dcGroupCount + dim.groupCount)
		if optimizeCodes {
			for i in acRange { sections[i] = SectionWriter(mode: .staging(acCode)) }
		} else {
			for i in acRange { sections[i] = SectionWriter(mode: .direct(acCode)) }
		}

		for i in 0..<dim.dcGroupCount {
			encodeDCGroup(
				linear: linear, dim: dim,
				dcGroupX: i % dim.widthInDCGroups,
				dcGroupY: i / dim.widthInDCGroups,
				params: params, sections: &sections)
		}

		if optimizeCodes {
			let dcRange = 1..<(1 + dim.dcGroupCount)
			dcCode = SectionOptimizer.optimize(
				sections: &sections, range: dcRange, baseCode: dcCode)
			acCode = SectionOptimizer.optimize(
				sections: &sections, range: acRange, baseCode: acCode)
		}

		// The globals carry the codes, so they can only be written once the
		// codes are final.
		var dcGlobal = BitWriter()
		try FrameAssembly.writeDCGlobal(
			params: params, dcGroupCount: dim.dcGroupCount, code: dcCode,
			writer: &dcGlobal)
		sections[0] = SectionWriter(prewritten: dcGlobal)

		var acGlobal = BitWriter()
		FrameAssembly.writeACGlobal(
			groupCount: dim.groupCount, code: acCode, writer: &acGlobal)
		sections[1 + dim.dcGroupCount] = SectionWriter(prewritten: acGlobal)

		FrameAssembly.writeFrameHeader(
			colorMode: .xyb(xQuantMatrixScale: params.xQuantMatrixScale),
			epfIterations: params.epfIterations,
			writer: &writer)
		FrameAssembly.combineSections(
			sections.map { $0.finished() }, writer: &writer)
	}

	/// Encodes an image as a bare JPEG XL codestream.
	///
	/// `distance` is a butteraugli target: lower is higher quality. Lossless is
	/// not supported by this VarDCT-only encoder.
	public static func encode(
		_ image: ImageBuffer,
		distance: Float,
		transferFunction: TransferFunction = .sRGB,
		optimizeCodes: Bool = true
	) throws -> [UInt8] {
		let params = try DistanceParams(distance: distance)
		let linear = linearize(image)

		var writer = BitWriter()
		try ImageHeader.write(
			width: image.width, height: image.height,
			transferFunction: transferFunction, to: &writer)
		try encodeFrame(
			linear: linear, width: image.width, height: image.height,
			params: params, optimizeCodes: optimizeCodes, writer: &writer)
		writer.zeroPadToByte()
		return writer.take()
	}
}
