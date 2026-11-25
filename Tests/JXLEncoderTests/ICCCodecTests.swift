import Testing

@testable import JXLEncoder

/// Structural invariants of libjxl `PredictICC`, `ICCANSContext` and the
/// `WriteICC` LZ77 choice; byte exactness is proven by an independent decoder
/// recovering the profile.
@Suite("ICCCodec")
struct ICCCodecTests {
	typealias Builder = ICCProfileTests.Builder

	static func profile(_ fixture: String) throws -> [UInt8] {
		try #require(try JPEGParser.parse(JPEGParserTests.fixture(fixture)).iccProfile)
	}

	static func displayP3() throws -> [UInt8] { try profile("display_p3_profile") }

	/// Points table entries `targets` at entry `source`'s offset and size.
	static func aliasing(_ bytes: [UInt8], _ targets: [Int], to source: Int) -> [UInt8] {
		var bytes = bytes
		for target in targets {
			bytes.replaceSubrange(
				136 + 12 * target..<144 + 12 * target,
				with: bytes[136 + 12 * source..<144 + 12 * source])
		}
		return bytes
	}

	static func curv(_ count: Int) -> [UInt8] {
		Builder.ascii("curv") + [0, 0, 0, 0] + Builder.be32(UInt32(count))
			+ (0..<count).flatMap { [UInt8($0 * 9 / 256), UInt8($0 * 9 % 256)] }
	}

	/// A command-stream reading written from the format's description of
	/// `UnpredictICC` (icc_codec.cc:119-337), sharing no code with `ICCCodec`.
	struct Decoded {
		var bytes: [UInt8] = []
		var commandCount = 0
		var headerResidual: [UInt8] = []
		var tagCodes: [UInt8] = []
		var contentCommands: [UInt8] = []
		var predictions: [Prediction] = []
	}

	struct Prediction: Equatable {
		var flags: UInt8
		var stride: Int?
	}

	static let tagStrings = [
		"cprt", "wtpt", "bkpt", "rXYZ", "gXYZ", "bXYZ", "kXYZ", "rTRC", "gTRC", "bTRC",
		"kTRC",
		"chad", "desc", "chrm", "dmnd", "dmdd", "lumi",
	]
	static let typeStrings = ["XYZ ", "desc", "text", "mluc", "para", "curv", "sf32", "gbd "]

	static func headerPrediction(_ i: Int, size: Int, decoded: [UInt8]) -> UInt8 {
		let fixed: [Int: String] = [8: "\u{4}", 12: "mntrRGB XYZ ", 36: "acsp"]
		let numeric: [Int: UInt8] = [70: 246, 71: 214, 73: 1, 78: 211, 79: 45]
		func ascii(_ text: String, from start: Int) -> UInt8 { Array(text.utf8)[i - start] }
		switch i {
		case 0..<4: return Builder.be32(UInt32(size))[i]
		case 80..<84: return decoded[i - 76]
		case 41..<44 where decoded[40] == UInt8(ascii: "A"): return ascii("PPL", from: 41)
		case 41..<44 where decoded[40] == UInt8(ascii: "M"): return ascii("SFT", from: 41)
		case 42..<44 where decoded[40..<42].elementsEqual("SG".utf8):
			return ascii("I ", from: 42)
		case 42..<44 where decoded[40..<42].elementsEqual("SU".utf8):
			return ascii("NW", from: 42)
		default:
			if let (start, text) = fixed.first(where: {
				i >= $0.key && i < $0.key + $0.value.utf8.count
			}) {
				return ascii(text, from: start)
			}
			return numeric[i] ?? 0
		}
	}

	static func decode(_ stream: [UInt8]) throws -> Decoded {
		var decoded = Decoded()
		var cursor = 0
		func varint() throws -> Int {
			var value = 0
			var shift = 0
			while true {
				let byte = try #require(
					cursor < stream.count ? stream[cursor] : nil)
				cursor += 1
				value |= Int(byte & 127) << shift
				shift += 7
				if byte < 128 { return value }
			}
		}
		let size = try varint()
		decoded.commandCount = try varint()
		let commandsEnd = cursor + decoded.commandCount
		var dataCursor = commandsEnd
		func take(_ count: Int) throws -> [UInt8] {
			try #require(dataCursor + count <= stream.count)
			defer { dataCursor += count }
			return Array(stream[dataCursor..<dataCursor + count])
		}
		func next() -> UInt8 {
			defer { cursor += 1 }
			return stream[cursor]
		}

		decoded.headerResidual = try take(min(128, size))
		for (i, residual) in decoded.headerResidual.enumerated() {
			decoded.bytes.append(
				residual &+ headerPrediction(i, size: size, decoded: decoded.bytes))
		}

		let tagListLength = size > 128 ? try varint() : 0
		if tagListLength > 0 {
			let tagCount = tagListLength - 1
			decoded.bytes += Builder.be32(UInt32(tagCount))
			var previousStart = 128 + 12 * tagCount
			var previousSize = 0
			while cursor < commandsEnd {
				let command = next()
				let code = command & 63
				if code == 0 { break }
				decoded.tagCodes.append(code)
				let tag: [UInt8] =
					switch code {
					case 1: try take(4)
					case 2: Builder.ascii("rTRC")
					case 3: Builder.ascii("rXYZ")
					default: Builder.ascii(tagStrings[Int(code) - 4])
					}
				let twenty = [
					"rXYZ", "gXYZ", "bXYZ", "kXYZ", "wtpt", "bkpt", "lumi",
				]
				var tagSize =
					twenty.contains(String(decoding: tag, as: UTF8.self))
					? 20 : previousSize
				let tagStart =
					command & 64 != 0
					? try varint() : previousStart + previousSize
				if command & 128 != 0 { tagSize = try varint() }
				var entries = [(tag, tagStart)]
				if code == 2 {
					entries += [
						(Builder.ascii("gTRC"), tagStart),
						(Builder.ascii("bTRC"), tagStart),
					]
				}
				if code == 3 {
					entries += [
						(Builder.ascii("gXYZ"), tagStart + tagSize),
						(Builder.ascii("bXYZ"), tagStart + 2 * tagSize),
					]
				}
				for (signature, start) in entries {
					decoded.bytes +=
						signature + Builder.be32(UInt32(start))
						+ Builder.be32(UInt32(tagSize))
				}
				previousStart = tagStart
				previousSize = tagSize
			}
		}

		while cursor < commandsEnd {
			let command = next()
			decoded.contentCommands.append(command)
			switch command {
			case 1:
				decoded.bytes += try take(varint())
			case 2:
				decoded.bytes += interleave(try take(varint()), width: 2)
			case 4:
				let flags = next()
				let width = Int(flags & 3) + 1
				let order = Int(flags >> 2 & 3)
				let signalledStride = flags & 16 != 0 ? try varint() : nil
				decoded.predictions.append(
					Prediction(flags: flags, stride: signalledStride))
				let stride = signalledStride ?? width
				let residuals = interleave(try take(varint()), width: width)
				let start = decoded.bytes.count
				for (i, residual) in residuals.enumerated() {
					let row = start + i - i % width
					let p = (1...3).map { k in
						decoded.bytes[
							row - stride * k..<row - stride * k + width
						]
						.reduce(0) { $0 << 8 | Int($1) }
					}
					let prediction = [
						p[0], 2 * p[0] - p[1], 3 * p[0] - 3 * p[1] + p[2],
					][order]
					let byte = UInt8(
						truncatingIfNeeded: prediction
							>> (8 * (width - 1 - i % width)))
					decoded.bytes.append(byte &+ residual)
				}
			case 10:
				decoded.bytes +=
					Builder.ascii("XYZ ") + [0, 0, 0, 0] + (try take(12))
			case 16..<24:
				decoded.bytes +=
					Builder.ascii(typeStrings[Int(command) - 16]) + [
						0, 0, 0, 0,
					]
			default:
				Issue.record("unknown command \(command)")
				return decoded
			}
		}
		#expect(dataCursor == stream.count, "all data consumed")
		#expect(decoded.bytes.count == size)
		return decoded
	}

	/// The decoder's `Shuffle` (icc_codec.cc:34-53): output byte `i` reads
	/// input `j`, stepping by the row count and restarting one column on when
	/// `j` passes the end, so a short last row is not plain column-major.
	static func interleave(_ columns: [UInt8], width: Int) -> [UInt8] {
		let height = (columns.count + width - 1) / width
		var restart = 0
		var j = 0
		return columns.indices.map { _ in
			defer {
				j += height
				if j >= columns.count {
					restart += 1
					j = restart
				}
			}
			return columns[j]
		}
	}

	@Test("an independent decoder recovers every profile byte from the stream")
	func independentDecodeRecoversProfile() throws {
		var curved = Builder()
		curved.setTRCs(Self.curv(20))
		var state: UInt32 = 1
		let noise = (0..<700).map { _ in
			state = state &* 1_103_515_245 &+ 12_345
			return UInt8(truncatingIfNeeded: state >> 16)
		}
		// mAB layout: in/out channel counts at 8-9, CLUT offset at 24.
		var lut = Builder()
		let grid: [UInt8] = [3, 3, 3] + [UInt8](repeating: 0, count: 13) + [1, 0, 0, 0]
		lut.setTag(
			"A2B2",
			Builder.ascii("mAB ") + [0, 0, 0, 0, 3, 3, 0, 0]
				+ [UInt8](repeating: 0, count: 12)
				+ Builder.be32(84) + [0, 0, 0, 0] + Self.curv(20) + grid
				+ (0..<81).map { UInt8($0 * 3 % 256) })
		var gamut = Builder()
		gamut.setTag(
			"gbdx",
			Builder.ascii("gbd ") + [0, 0, 0, 0] + (0..<42).map { UInt8($0 * 5) })
		let profiles = [
			try Self.displayP3(), Builder().bytes,
			Self.aliasing(Builder().bytes, [5, 6], to: 4),
			curved.bytes, Array(try Self.displayP3().prefix(100)), noise, lut.bytes,
			gamut.bytes,
		]
		for profile in profiles {
			#expect(try Self.decode(ICCCodec.predict(profile)).bytes == profile)
		}
		let libjxlSizes = [
			"display_p3_profile": 390, "p3_desc4_profile": 450,
			"p3_desc1000_profile_420": 20_378, "p3_random40000_profile_420": 80_378,
			"p3_desc3300_profile_420": 66_378,
		]
		for (fixture, transformedSize) in libjxlSizes {
			let stream = ICCCodec.predict(try Self.profile(fixture))
			#expect(stream.count == transformedSize, "pinned libjxl PredictICC size")
			#expect(try Self.decode(stream).bytes == Self.profile(fixture))
		}
		// Flags are order << 2 | (width - 1), plus 16 when a stride follows
		// (enc_icc_codec.cc:319, 340, 367-368, 387).
		let expected: [([UInt8], [Prediction])] = [
			(curved.bytes, Array(repeating: Prediction(flags: 5), count: 3)),
			(lut.bytes, [Prediction(flags: 5), Prediction(flags: 20, stride: 3)]),
			(gamut.bytes, [Prediction(flags: 3)]),
		]
		for (profile, predictions) in expected {
			#expect(
				try Self.decode(ICCCodec.predict(profile)).predictions
					== predictions)
		}
		// desc and cprt are mluc, then four XYZ, para with its parameters
		// inserted, and sf32 with its matrix inserted (enc_icc_codec.cc:293, 401, 415, 425).
		#expect(
			try Self.decode(ICCCodec.predict(Self.displayP3())).contentCommands == [
				19, 2, 19, 2, 10, 10, 10, 10, 20, 1, 22, 1,
			])
	}

	@Test("the stream opens with varint profile size then varint command count")
	func predictionStartsWithVarintSizeAndCommandCount() throws {
		let profile = try Self.displayP3()
		#expect(profile.count == 536)
		let stream = ICCCodec.predict(profile)
		#expect(Array(stream.prefix(2)) == [0x98, 0x04])
		let decoded = try Self.decode(stream)
		#expect(stream[3] == 11, "the first command is the varint tag count + 1")
		#expect(stream.count > 3 + decoded.commandCount)

		let short = Array(profile.prefix(100))
		#expect(Array(ICCCodec.predict(short).prefix(2)) == [100, 0])
		#expect(ICCCodec.predict(short).count == 102)
	}

	@Test("header fields matching the initial prediction leave zero residuals")
	func headerResidualIsZeroForPredictedFields() throws {
		let profile = try Self.displayP3()
		let residual = try Self.decode(ICCCodec.predict(profile)).headerResidual
		#expect(residual.count == 128)
		for range in [0..<4, 8..<9, 12..<24, 36..<40, 41..<44, 68..<84] {
			#expect(residual[range].allSatisfy { $0 == 0 }, "bytes \(range)")
		}
		#expect(
			profile[80..<84].elementsEqual("appl".utf8),
			"creator predicted from the CMM")
		#expect(residual[40] == UInt8(ascii: "A"), "platform's first byte is unpredicted")
	}

	@Test("a TRC shared by all three channels collapses to the shared-tag command")
	func sharedTRCCollapsesToCommand() throws {
		let separate = try Self.decode(ICCCodec.predict(Builder().bytes))
		#expect(separate.tagCodes == [5, 3, 11, 12, 13, 15])
		let shared = Self.aliasing(Builder().bytes, [5, 6], to: 4)
		#expect(try Self.decode(ICCCodec.predict(shared)).tagCodes == [5, 3, 2, 15])
		#expect(
			try Self.decode(ICCCodec.predict(Self.displayP3())).tagCodes.contains(11),
			"Display P3's rTRC is followed by chad, so it is not collapsed")
	}

	@Test("contiguous r/g/bXYZ tags use the XYZ command")
	func contiguousXYZUsesXYZCommand() throws {
		let decoded = try Self.decode(ICCCodec.predict(Self.displayP3()))
		#expect(decoded.tagCodes == [16, 4, 5, 3, 11, 15, 13, 12])
		#expect(decoded.contentCommands.filter { $0 == 10 }.count == 4)
		let overlapping = Self.aliasing(Builder().bytes, [2], to: 1)
		#expect(
			try Self.decode(ICCCodec.predict(overlapping)).tagCodes == [
				5, 7, 8, 9, 11, 12, 13, 15,
			])
	}

	@Test("transformed bytes 0 through 128 use context 0 and byte 129 does not")
	func contextIsZeroThroughIndex128() {
		for index in [0, 1, 2, 128] {
			#expect(
				ICCCodec.context(
					index: index, previous: 0x80, previousPrevious: 0x80) == 0)
		}
		#expect(ICCCodec.context(index: 129, previous: 0x80, previousPrevious: 0x80) == 40)
		#expect(
			ICCCodec.context(
				index: 129, previous: UInt8(ascii: "a"), previousPrevious: 0x41)
				== 1)
	}

	@Test("later contexts are 1 + ByteKind1(previous) + 8 × ByteKind2(previousPrevious)")
	func contextClassifiesByteKinds() {
		func letterOrDigit(_ b: UInt8) -> Int? {
			if (0x61...0x7A).contains(b) || (0x41...0x5A).contains(b) { return 0 }
			if (0x30...0x39).contains(b) || b == 0x2E || b == 0x2C { return 1 }
			return nil
		}
		func byteKind1(_ b: UInt8) -> Int {
			letterOrDigit(b)
				?? (b == 0
					? 2
					: b == 1 ? 3 : b < 16 ? 4 : b == 255 ? 6 : b > 240 ? 5 : 7)
		}
		func byteKind2(_ b: UInt8) -> Int {
			letterOrDigit(b) ?? (b < 16 ? 2 : b > 240 ? 3 : 4)
		}
		var seen = Set<Int>()
		for previous in UInt8.min...UInt8.max {
			for previousPrevious in UInt8.min...UInt8.max {
				let context = ICCCodec.context(
					index: 129, previous: previous,
					previousPrevious: previousPrevious)
				#expect(
					context == 1 + byteKind1(previous) + 8
						* byteKind2(previousPrevious))
				seen.insert(context)
			}
		}
		#expect(seen == Set(1..<ICCCodec.contextCount))
	}

	@Test("16,383 transformed bytes select optimal LZ77 and 16,384 select greedy")
	func lz77MethodSwitchesAt16384() {
		#expect(ICCCodec.lz77Method(transformedSize: 16_383) == .optimal)
		#expect(ICCCodec.lz77Method(transformedSize: 16_384) == .lz77)
		#expect(ICCCodec.lz77Method(transformedSize: 390) == .optimal)
	}

	/// Forced prefix codes put LZ77 lengths at min_symbol 512, U32 selector 1
	/// (enc_ans.cc:1090, dec_ans.cc:304-315).
	@Test("coded ICC enables LZ77 with the forced-prefix min_symbol")
	func writeEnablesLZ77WithForcedPrefixMinSymbol() throws {
		for (fixture, method) in [
			("p3_desc4_profile", LZ77.Method.optimal),
			("p3_desc1000_profile_420", .lz77),
		] {
			let profile = try ICCProfile(validating: Self.profile(fixture))
			let size = ICCCodec.predict(profile.bytes).count
			#expect(ICCCodec.lz77Method(transformedSize: size) == method)
			var w = BitWriter()
			ICCCodec.write(profile, to: &w)
			w.zeroPadToByte()
			var bits = ImageHeaderTests.HeaderBits(bytes: w.take())
			#expect(bits.u64() == UInt64(size))
			#expect(bits.read(1) == 1, "\(fixture) LZ77 enabled")
			#expect(bits.read(2) == 1, "\(fixture) min_symbol 512")
			#expect(bits.read(2) == 0, "\(fixture) min_length 3")
		}
	}

	@Test("each token's context follows the two bytes before it, in that order")
	func tokensUseTheReadersContexts() throws {
		let stream = ICCCodec.predict(try Self.displayP3())
		let tokens = ICCCodec.tokens(stream)
		#expect(tokens.count == stream.count)
		var differsWhenSwapped = false
		for i in 129..<stream.count {
			let expected = ICCCodec.context(
				index: i, previous: stream[i - 1], previousPrevious: stream[i - 2])
			#expect(Int(tokens[i].context) == expected, "index \(i)")
			#expect(tokens[i].value == UInt32(stream[i]))
			differsWhenSwapped =
				differsWhenSwapped
				|| expected
					!= ICCCodec.context(
						index: i, previous: stream[i - 2],
						previousPrevious: stream[i - 1])
		}
		#expect(differsWhenSwapped, "the input distinguishes the two orders")
		#expect(tokens.prefix(129).allSatisfy { $0.context == 0 })
	}

	@Test("write codes the stream with the LZ77 method its size selects")
	func writeUsesTheSizeSelectedLZ77Method() throws {
		func coded(_ stream: [UInt8], _ method: LZ77.Method) -> BitWriter {
			var writer = BitWriter()
			writer.writeU64(UInt64(stream.count))
			let prepared = EntropyCodeWriter.prepare(
				ICCCodec.tokens(stream), contextCount: 41,
				parameters: HistogramParameters(
					lz77Method: method, forcesPrefixCodes: true))
			EntropyCodeWriter.write(prepared.code, writer: &writer)
			EntropyCodeWriter.writeTokens(
				prepared.tokens, code: prepared.code, writer: &writer)
			return writer
		}
		// kOptimal's parse is quadratic on repeated input, so the greedy case is
		// only compared with its own method.
		for (fixture, selected) in [
			("p3_desc4_profile", LZ77.Method.optimal),
			("p3_desc1000_profile_420", .lz77),
		] {
			let profile = try ICCProfile(validating: Self.profile(fixture))
			let stream = ICCCodec.predict(profile.bytes)
			var written = BitWriter()
			#expect(ICCCodec.write(profile, to: &written))
			var expected = coded(stream, selected)
			#expect(written.bitsWritten == expected.bitsWritten, "\(fixture)")
			written.zeroPadToByte()
			expected.zeroPadToByte()
			let writtenBytes = written.take()
			#expect(writtenBytes == expected.take(), "\(fixture)")
			if selected == .optimal {
				var greedy = coded(stream, .lz77)
				greedy.zeroPadToByte()
				#expect(
					writtenBytes != greedy.take(),
					"\(fixture) differs from greedy")
			}
		}
	}

	/// The reader checks at multiples of 65,536 decoded bytes, so the edge is
	/// 256 coded bytes there (icc_codec.cc:399-403).
	@Test("the reader's 256:1 check passes at exactly 256 coded bytes")
	func readerAcceptanceBoundary() {
		#expect(ICCCodec.readerAccepts(symbols: 65_536, bits: 2_048))
		#expect(!ICCCodec.readerAccepts(symbols: 65_536, bits: 2_047))
		#expect(ICCCodec.readerAccepts(symbols: 131_072, bits: 4_096))
		#expect(!ICCCodec.readerAccepts(symbols: 131_072, bits: 4_095))
	}

	/// "below" and "above" differ by a seeded character, a few coded bits on
	/// either side of the limit at the first checkpoint; "late" is under it
	/// there and over it by the end of the stream.
	@Test(
		"write declines exactly the streams the reader rejects and leaves the writer untouched"
	)
	func writeDeclinesOvercompressedProfile() throws {
		for fixture in [
			"p3_desc3300_profile_420", "p3_ratio_below_420", "p3_ratio_late_420",
		] {
			let declined = try ICCProfile(validating: Self.profile(fixture))
			var writer = BitWriter()
			writer.write(3, 5)
			#expect(!ICCCodec.write(declined, to: &writer), "\(fixture)")
			#expect(writer.bitsWritten == 3, "\(fixture)")
		}
		for fixture in [
			"p3_random40000_profile_420", "p3_desc1000_profile_420",
			"p3_ratio_above_420",
		] {
			let accepted = try ICCProfile(validating: Self.profile(fixture))
			var fresh = BitWriter()
			#expect(ICCCodec.write(accepted, to: &fresh), "\(fixture)")
			#expect(fresh.bitsWritten > 0, "\(fixture)")
		}
	}
}
