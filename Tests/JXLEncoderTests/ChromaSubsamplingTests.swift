import Testing

@testable import JXLEncoder

/// Subsampling only arises from JPEG recompression, so the mapping from JPEG
/// sampling factors is the part that matters. JPEG components run Y, Cb, Cr
/// while JXL channels run X, Y, B — components 0 and 1 swap.
@Suite("Chroma subsampling")
struct ChromaSubsamplingTests {
	@Test("4:4:4 is the identity")
	func fullResolution() {
		let cs = try! #require(
			ChromaSubsampling.fromJPEG(
				horizontalSampling: [1, 1, 1], verticalSampling: [1, 1, 1]))
		#expect(cs.is444)
		for channel in 0..<3 {
			#expect(cs.horizontalShift(channel) == 0)
			#expect(cs.verticalShift(channel) == 0)
		}
		#expect(cs == ChromaSubsampling.none)
	}

	@Test("4:2:0 halves chroma on both axes, luma stays full")
	func fourTwoZero() {
		let cs = try! #require(
			ChromaSubsampling.fromJPEG(
				horizontalSampling: [2, 1, 1], verticalSampling: [2, 1, 1]))
		#expect(!cs.is444)
		// channel 1 is luma
		#expect(cs.horizontalShift(1) == 0)
		#expect(cs.verticalShift(1) == 0)
		for chroma in [0, 2] {
			#expect(cs.horizontalShift(chroma) == 1)
			#expect(cs.verticalShift(chroma) == 1)
		}
	}

	@Test("4:2:2 halves chroma horizontally only")
	func fourTwoTwo() {
		let cs = try! #require(
			ChromaSubsampling.fromJPEG(
				horizontalSampling: [2, 1, 1], verticalSampling: [1, 1, 1]))
		#expect(cs.horizontalShift(0) == 1)
		#expect(cs.verticalShift(0) == 0)
		#expect(cs.horizontalShift(1) == 0)
	}

	@Test("4:4:0 halves chroma vertically only")
	func fourFourZero() {
		let cs = try! #require(
			ChromaSubsampling.fromJPEG(
				horizontalSampling: [1, 1, 1], verticalSampling: [2, 1, 1]))
		#expect(cs.horizontalShift(0) == 0)
		#expect(cs.verticalShift(0) == 1)
	}

	@Test("rejects sampling factors with no matching mode")
	func rejectsUnsupported() {
		// 3x sampling has no representation in the four modes
		#expect(
			ChromaSubsampling.fromJPEG(
				horizontalSampling: [3, 1, 1], verticalSampling: [1, 1, 1]) == nil)
	}

	/// A 2x-subsampled channel codes one block for every two full-resolution
	/// positions, on the even ones.
	@Test("subsampled channels code only on aligned blocks")
	func codingPattern() {
		let cs = try! #require(
			ChromaSubsampling.fromJPEG(
				horizontalSampling: [2, 1, 1], verticalSampling: [2, 1, 1]))
		var lumaBlocks = 0
		var chromaBlocks = 0
		for by in 0..<8 {
			for bx in 0..<8 {
				if cs.codesBlock(channel: 1, blockX: bx, blockY: by) {
					lumaBlocks += 1
				}
				if cs.codesBlock(channel: 0, blockX: bx, blockY: by) {
					chromaBlocks += 1
				}
			}
		}
		#expect(lumaBlocks == 64)
		#expect(chromaBlocks == 16, "2x2 subsampling should code a quarter as many")
	}

	@Test("block counts round up per channel")
	func blockCounts() {
		let cs = try! #require(
			ChromaSubsampling.fromJPEG(
				horizontalSampling: [2, 1, 1], verticalSampling: [2, 1, 1]))
		// odd counts must round up, not truncate
		#expect(cs.blocksAcross(channel: 1, fullWidthInBlocks: 7) == 7)
		#expect(cs.blocksAcross(channel: 0, fullWidthInBlocks: 7) == 4)
		#expect(cs.blocksDown(channel: 0, fullHeightInBlocks: 5) == 3)
	}

	@Test("serializes as three 2-bit mode fields")
	func serialization() {
		let cs = try! #require(
			ChromaSubsampling.fromJPEG(
				horizontalSampling: [2, 1, 1], verticalSampling: [2, 1, 1]))
		var writer = BitWriter()
		cs.write(to: &writer)
		#expect(writer.bitsWritten == 6)
		// channel modes are 0 (Cb), 1 (Y), 0 (Cr), written low bits first
		writer.zeroPadToByte()
		#expect(writer.take() == [0b000100])
	}

	/// The real assets: one 4:2:0, one 4:4:4.
	@Test("maps the sampling factors of real JPEGs")
	func realJPEGs() throws {
		let fourTwoZero = try #require(
			ChromaSubsampling.fromJPEG(
				horizontalSampling: [2, 1, 1], verticalSampling: [2, 1, 1]))
		#expect(!fourTwoZero.is444)
		let fourFourFour = try #require(
			ChromaSubsampling.fromJPEG(
				horizontalSampling: [1, 1, 1], verticalSampling: [1, 1, 1]))
		#expect(fourFourFour.is444)
	}
}

/// Exercises the encoder with per-channel resolutions. The bitstream cannot be
/// verified against a reference yet — subsampling is only reachable through
/// JPEG recompression, which also needs YCbCr signalling and custom quant
/// matrices — so these assert the structural consequences instead.
@Suite("Subsampled encoding")
struct SubsampledEncodingTests {
	static func planes(
		fullWidth: Int, fullHeight: Int, subsampling: ChromaSubsampling
	) -> ChannelPlanes {
		var data: [[Float]] = []
		var widths: [Int] = []
		var heights: [Int] = []
		for channel in 0..<3 {
			let w = fullWidth >> subsampling.horizontalShift(channel)
			let h = fullHeight >> subsampling.verticalShift(channel)
			var plane = [Float](repeating: 0, count: w * h)
			for y in 0..<h {
				for x in 0..<w {
					plane[y * w + x] =
						Float((x &* 7 &+ y &* 13) % 64) / 64 - 0.5
				}
			}
			data.append(plane)
			widths.append(w)
			heights.append(h)
		}
		return ChannelPlanes(planes: data, widths: widths, heights: heights)
	}

	static func encode(subsampling: ChromaSubsampling) -> (bits: Int, dc: [[Int16]]) {
		let blocks = 8
		let full = blocks * DCT.blockDim
		let planes = planes(fullWidth: full, fullHeight: full, subsampling: subsampling)
		var quantDC = (0..<3).map { channel in
			[Int16](
				repeating: 0,
				count: subsampling.blocksAcross(
					channel: channel, fullWidthInBlocks: blocks)
					* subsampling.blocksDown(
						channel: channel, fullHeightInBlocks: blocks))
		}
		var writer = BitWriter()
		ACGroupEncoder.encode(
			planes: planes, widthInBlocks: blocks, heightInBlocks: blocks,
			subsampling: subsampling,
			quantField: [UInt8](repeating: 5, count: blocks * blocks),
			scale: 0.112_075_805_664_062_5, scaleDC: 1.0, xQuantMatrixScale: 2,
			code: .staticAC, quantDC: &quantDC, writer: &writer)
		return (writer.bitsWritten, quantDC)
	}

	@Test("chroma DC arrays hold a quarter as many entries at 4:2:0")
	func dcExtent() {
		let cs = ChromaSubsampling.fromJPEG(
			horizontalSampling: [2, 1, 1], verticalSampling: [2, 1, 1])!
		let (_, dc) = Self.encode(subsampling: cs)
		#expect(dc[1].count == 64, "luma stays full resolution")
		#expect(dc[0].count == 16)
		#expect(dc[2].count == 16)
	}

	@Test("every chroma DC slot is written, none left at the initial value")
	func everySlotWritten() {
		let cs = ChromaSubsampling.fromJPEG(
			horizontalSampling: [2, 1, 1], verticalSampling: [2, 1, 1])!
		let blocks = 8
		let full = blocks * DCT.blockDim
		let planes = Self.planes(fullWidth: full, fullHeight: full, subsampling: cs)
		// a value the encoder cannot produce, so an unwritten slot is visible
		// rather than hiding behind a plausible zero
		let sentinel = Int16.min

		var quantDC = (0..<3).map { channel in
			[Int16](
				repeating: sentinel,
				count: cs.blocksAcross(channel: channel, fullWidthInBlocks: blocks)
					* cs.blocksDown(
						channel: channel, fullHeightInBlocks: blocks))
		}
		var writer = BitWriter()
		ACGroupEncoder.encode(
			planes: planes, widthInBlocks: blocks, heightInBlocks: blocks,
			subsampling: cs,
			quantField: [UInt8](repeating: 5, count: blocks * blocks),
			scale: 0.112_075_805_664_062_5, scaleDC: 1.0, xQuantMatrixScale: 2,
			code: .staticAC, quantDC: &quantDC, writer: &writer)

		for channel in 0..<3 {
			let unwritten = quantDC[channel].filter { $0 == sentinel }.count
			#expect(
				unwritten == 0,
				"channel \(channel) left \(unwritten) slots unwritten")
		}
	}

	@Test("subsampling shrinks the bitstream")
	func fewerBits() {
		let full = Self.encode(subsampling: .none).bits
		let cs420 = ChromaSubsampling.fromJPEG(
			horizontalSampling: [2, 1, 1], verticalSampling: [2, 1, 1])!
		let cs422 = ChromaSubsampling.fromJPEG(
			horizontalSampling: [2, 1, 1], verticalSampling: [1, 1, 1])!
		let bits420 = Self.encode(subsampling: cs420).bits
		let bits422 = Self.encode(subsampling: cs422).bits

		#expect(bits420 < bits422, "4:2:0 codes fewer chroma blocks than 4:2:2")
		#expect(bits422 < full, "4:2:2 codes fewer chroma blocks than 4:4:4")
	}

	/// The 4:4:4 path must be untouched by the restructure — the whole-file
	/// byte-exact tests depend on it.
	@Test("4:4:4 through the per-channel entry point matches the simple one")
	func degenerateCaseUnchanged() {
		let blocks = 8
		let full = blocks * DCT.blockDim
		let stripe = PaddedStripe(
			width: full, height: full,
			planes: Self.planes(
				fullWidth: full, fullHeight: full, subsampling: .none
			).planes)
		let quantField = [UInt8](repeating: 5, count: blocks * blocks)

		var dcA = [[Int16]](repeating: [Int16](repeating: 0, count: 64), count: 3)
		var writerA = BitWriter()
		ACGroupEncoder.encode(
			xyb: stripe, widthInBlocks: blocks, heightInBlocks: blocks,
			quantField: quantField, scale: 0.112_075_805_664_062_5, scaleDC: 1.0,
			xQuantMatrixScale: 2, code: .staticAC, quantDC: &dcA, writer: &writerA)

		var dcB = [[Int16]](repeating: [Int16](repeating: 0, count: 64), count: 3)
		var writerB = BitWriter()
		ACGroupEncoder.encode(
			planes: stripe.channelPlanes, widthInBlocks: blocks, heightInBlocks: blocks,
			subsampling: .none, quantField: quantField, scale: 0.112_075_805_664_062_5,
			scaleDC: 1.0, xQuantMatrixScale: 2, code: .staticAC, quantDC: &dcB,
			writer: &writerB)

		#expect(writerA.bitsWritten == writerB.bitsWritten)
		writerA.zeroPadToByte()
		writerB.zeroPadToByte()
		#expect(writerA.take() == writerB.take())
		#expect(dcA == dcB)
	}
}
