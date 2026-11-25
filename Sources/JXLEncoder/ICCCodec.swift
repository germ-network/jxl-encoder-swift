//
//  ICCCodec.swift
//  JXLEncoder
//
//  The codestream's compressed ICC profile: libjxl's predictive transform
//  (enc_icc_codec.cc `PredictICC`), its byte contexts (icc_codec_common.cc
//  `ICCANSContext`) and the header field that carries both
//  (enc_icc_codec.cc `WriteICC`). A decoder inverts it to the exact source
//  bytes.
//

enum ICCCodec {
	/// `kNumICCContexts` (icc_codec_common.h).
	static let contextCount = 41

	/// The transformed stream a decoder's `UnpredictICC` maps back to `icc`
	/// byte for byte: varint size, varint command count, commands, then data.
	/// Ports `PredictICC` (enc_icc_codec.cc:119-446).
	static func predict(_ icc: [UInt8]) -> [UInt8] {
		precondition(icc.count <= sizeLimit, "ICC profile is too large")
		let size = icc.count
		var commands: [UInt8] = []
		var data: [UInt8] = []

		var header = initialHeaderPrediction(size: size)
		for i in 0..<min(headerSize, size) {
			predictHeader(icc, &header, i)
			data.append(icc[i] &- header[i])
		}
		guard size > headerSize else { return varint(size) + varint(0) + data }

		func u32(_ at: Int) -> Int { at + 4 > size ? 0 : beInt(icc, at, 4) }
		func keyword(_ at: Int) -> UInt32 {
			at + 4 > size ? 0x2020_2020 : UInt32(beInt(icc, at, 4))
		}

		var tagStarts: [Int] = []
		var tagSizes: [Int] = []
		var tagMap: [Int: Int] = [:]
		var pos = headerSize
		if pos + 4 <= size {
			let tagCount = u32(pos)
			pos += 4
			commands += varint(tagCount + 1)
			var previousStart = headerSize + tagCount * 12
			var previousSize = 0
			var i = 0
			while i < tagCount, pos + 12 <= size {
				let tag = keyword(pos)
				let tagStart = u32(pos + 4)
				let tagSize = u32(pos + 8)
				pos += 12
				tagStarts.append(tagStart)
				tagSizes.append(tagSize)
				tagMap[tagStart] = tagStarts.count - 1

				var tagCode =
					tagStrings.firstIndex(of: tag).map { UInt8($0) + 4 } ?? 1
				if tag == Signature.rTRC, pos + 24 < size,
					keyword(pos) == Signature.gTRC,
					keyword(pos + 12) == Signature.bTRC,
					(0..<8).allSatisfy({
						icc[pos - 8 + $0] == icc[pos + 4 + $0]
							&& icc[pos - 8 + $0] == icc[pos + 16 + $0]
					})
				{
					tagCode = 2
					pos += 24
					i += 2
				}
				if tag == Signature.rXYZ, pos + 24 < size,
					keyword(pos) == Signature.gXYZ,
					keyword(pos + 12) == Signature.bXYZ, tagSize == 20,
					u32(pos + 8) == 20,
					u32(pos + 20) == 20,
					u32(pos + 4) == (tagStart + 20) & 0xFFFF_FFFF,
					u32(pos + 16) == (tagStart + 40) & 0xFFFF_FFFF
				{
					tagCode = 3
					pos += 24
					i += 2
				}

				var command = tagCode
				if previousStart + previousSize != tagStart {
					command |= flagBitOffset
				}
				let predictedSize = twentyByteTags.contains(tag) ? 20 : previousSize
				if predictedSize != tagSize { command |= flagBitSize }
				commands.append(command)
				if tagCode == 1 { data += bytes(of: tag) }
				if command & flagBitOffset != 0 { commands += varint(tagStart) }
				if command & flagBitSize != 0 { commands += varint(tagSize) }
				previousStart = tagStart
				previousSize = tagSize
				i += 1
			}
		}
		commands.append(0)

		var tag: UInt32 = 0
		var tagStart = 0
		var tagSize = 0
		var clutStart = 0
		var tagSane: Bool { tagSize > 8 && tagSize < sizeLimit }
		var last0 = pos
		while pos <= size {
			var last1 = pos
			var commandsAdd: [UInt8] = []
			var dataAdd: [UInt8] = []
			var added: Bool { !commandsAdd.isEmpty || !dataAdd.isEmpty }

			if pos > tagStart + tagSize, tagSize < sizeLimit { tag = 0 }

			if let index = tagMap[pos], pos + 4 <= size {
				tag = keyword(pos)
				tagStart = tagStarts[index]
				tagSize = tagSizes[index]
				let typeOnly = tagSane && pos + tagSize <= size && u32(pos + 4) == 0
				if tag == Signature.mluc, typeOnly {
					let count = tagSize - 8
					commandsAdd +=
						[typeStartFirst + 3, commandShuffle2]
						+ varint(count)
					pos += 8
					dataAdd += unshuffle(icc[pos..<pos + count], width: 2)
					pos += count
				}
				if tag == Signature.curv, typeOnly {
					let count = tagSize - 8
					if count > 16, count < 1 << 28, pos + count <= size, pos > 0
					{
						commandsAdd += [typeStartFirst + 5]
						pos += 8
						commandsAdd +=
							[commandPredict, 1 << 2 | 1] + varint(count)
						dataAdd += predictAndShuffle(
							icc, &pos, count, stride: 2, width: 2,
							order: 1)
					}
				}
			}

			if tag == Signature.mAB || tag == Signature.mBA {
				let subTag = keyword(pos)
				if pos + 12 < size,
					subTag == Signature.curv || subTag == Signature.vcgt,
					u32(pos + 4) == 0
				{
					let count = Int(UInt32(u32(pos + 8)) &* 2)
					if count > 16, count < 1 << 28, pos + 12 + count <= size {
						pos += 12
						last1 = pos
						commandsAdd +=
							[commandPredict, 1 << 2 | 1] + varint(count)
						dataAdd += predictAndShuffle(
							icc, &pos, count, stride: 2, width: 2,
							order: 1)
					}
				}
				if pos == tagStart + 24, pos + 4 < size {
					clutStart = tagStart + u32(pos)
				}
				if pos == clutStart, clutStart + 16 < size {
					let inputs = Int(icc[tagStart + 8])
					let width = Int(icc[clutStart + 16])
					let stride = width * Int(icc[tagStart + 9])
					var count = UInt64(stride)
					for i in 0..<inputs where clutStart + i < size {
						count = count &* UInt64(icc[clutStart + i])
					}
					if width == 1 || width == 2, count > 64, count < 1 << 28,
						pos + Int(count) <= size,
						pos > stride * 4
					{
						let flags = UInt8(
							1 << 2 | (width - 1)
								| (stride == width ? 0 : 16))
						commandsAdd += [commandPredict, flags]
						if flags & 16 != 0 { commandsAdd += varint(stride) }
						commandsAdd += varint(Int(count))
						dataAdd += predictAndShuffle(
							icc, &pos, Int(count), stride: stride,
							width: width, order: 1)
					}
				}
			}

			if !added, tag == Signature.gbd, tagSane, pos == tagStart + 8,
				pos + tagSize - 8 <= size, pos > 16
			{
				commandsAdd += [commandPredict, 3] + varint(tagSize - 8)
				dataAdd += predictAndShuffle(
					icc, &pos, tagSize - 8, stride: 4, width: 4, order: 0)
			}

			if !added, pos + 20 <= size, keyword(pos) == Signature.xyz,
				u32(pos + 4) == 0
			{
				commandsAdd.append(commandXYZ)
				dataAdd += icc[pos + 8..<pos + 20]
				pos += 20
			}

			if !added, pos + 8 <= size, u32(pos + 4) == 0,
				let type = typeStrings.firstIndex(of: keyword(pos))
			{
				commandsAdd.append(typeStartFirst + UInt8(type))
				pos += 8
			}

			if added || pos == size {
				if last0 < last1 {
					commands += [commandInsert] + varint(last1 - last0)
					data += icc[last0..<last1]
				}
				commands += commandsAdd
				data += dataAdd
				last0 = pos
			}
			if !added { pos += 1 }
		}

		return varint(size) + varint(commands.count) + commands + data
	}

	/// The context of transformed byte `index` given the two bytes before it:
	/// 0 for `index <= 128` (the first 129 bytes), otherwise a byte-kind pair
	/// in 1..<41. Ports `ICCANSContext` (icc_codec_common.cc:171-174).
	static func context(index: Int, previous: UInt8, previousPrevious: UInt8) -> Int {
		index <= 128 ? 0 : 1 + byteKind1(previous) + 8 * byteKind2(previousPrevious)
	}

	/// Optimal LZ77 below 16,384 transformed bytes and greedy LZ77 from there
	/// (enc_icc_codec.cc:472-473).
	static func lz77Method(transformedSize: Int) -> LZ77.Method {
		transformedSize < 16_384 ? .optimal : .lz77
	}

	/// Writes U64(transformed length) then the transformed bytes as
	/// forced-prefix tokens over `contextCount` contexts, with LZ77 chosen by
	/// `lz77Method(transformedSize:)`. Ports `WriteICC` (enc_icc_codec.cc).
	static func write(_ profile: ICCProfile, to writer: inout BitWriter) {
		let stream = predict(profile.bytes)
		writer.writeU64(UInt64(stream.count))
		let tokens = stream.indices.map { i in
			Token(
				context: UInt32(
					context(
						index: i, previous: i > 0 ? stream[i - 1] : 0,
						previousPrevious: i > 1 ? stream[i - 2] : 0)),
				value: UInt32(stream[i]))
		}
		let prepared = EntropyCodeWriter.prepare(
			tokens, contextCount: contextCount,
			parameters: HistogramParameters(
				lz77Method: lz77Method(transformedSize: stream.count),
				forcesPrefixCodes: true))
		EntropyCodeWriter.write(prepared.code, writer: &writer)
		EntropyCodeWriter.writeTokens(prepared.tokens, code: prepared.code, writer: &writer)
	}

	private static let headerSize = 128
	private static let sizeLimit = Int(UInt32.max >> 2)
	private static let flagBitOffset: UInt8 = 64
	private static let flagBitSize: UInt8 = 128
	private static let commandInsert: UInt8 = 1
	private static let commandShuffle2: UInt8 = 2
	private static let commandPredict: UInt8 = 4
	private static let commandXYZ: UInt8 = 10
	private static let typeStartFirst: UInt8 = 16

	private enum Signature {
		static let rTRC = fourCC("rTRC")
		static let gTRC = fourCC("gTRC")
		static let bTRC = fourCC("bTRC")
		static let rXYZ = fourCC("rXYZ")
		static let gXYZ = fourCC("gXYZ")
		static let bXYZ = fourCC("bXYZ")
		static let mluc = fourCC("mluc")
		static let curv = fourCC("curv")
		static let mAB = fourCC("mAB ")
		static let mBA = fourCC("mBA ")
		static let vcgt = fourCC("vcgt")
		static let gbd = fourCC("gbd ")
		static let xyz = fourCC("XYZ ")
	}

	/// `kTagStrings` (icc_codec_common.h:57-60): tag code 4 + index.
	private static let tagStrings = [
		"cprt", "wtpt", "bkpt", "rXYZ", "gXYZ", "bXYZ", "kXYZ", "rTRC", "gTRC", "bTRC",
		"kTRC",
		"chad", "desc", "chrm", "dmnd", "dmdd", "lumi",
	].map(fourCC)

	/// `kTypeStrings` (icc_codec_common.h:69-71): command 16 + index.
	private static let typeStrings = [
		"XYZ ", "desc", "text", "mluc", "para", "curv", "sf32", "gbd ",
	]
	.map(fourCC)

	/// Tags whose size is predicted as 20 (enc_icc_codec.cc:225-229).
	private static let twentyByteTags = Set(
		["rXYZ", "gXYZ", "bXYZ", "kXYZ", "wtpt", "bkpt", "lumi"].map(fourCC))

	private static func fourCC(_ text: String) -> UInt32 {
		text.utf8.reduce(0) { $0 << 8 | UInt32($1) }
	}

	private static func bytes(of value: UInt32) -> [UInt8] {
		[24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
	}

	private static func beInt(_ bytes: [UInt8], _ at: Int, _ width: Int) -> Int {
		bytes[at..<at + width].reduce(0) { $0 << 8 | Int($1) }
	}

	/// `EncodeVarInt` (enc_icc_codec.cc:88-109).
	private static func varint(_ value: Int) -> [UInt8] {
		var value = value
		var out: [UInt8] = []
		while value > 127 {
			out.append(UInt8(value & 127) | 128)
			value >>= 7
		}
		return out + [UInt8(value)]
	}

	/// `ICCInitialHeaderPrediction` (icc_codec_common.cc:91-106).
	private static func initialHeaderPrediction(size: Int) -> [UInt8] {
		var header =
			bytes(of: UInt32(truncatingIfNeeded: size))
			+ [UInt8](repeating: 0, count: 124)
		header[8] = 4
		header.replaceSubrange(12..<24, with: Array("mntrRGB XYZ ".utf8))
		header.replaceSubrange(36..<40, with: Array("acsp".utf8))
		for (offset, value) in [(70, 246), (71, 214), (73, 1), (78, 211), (79, 45)] {
			header[offset] = UInt8(value)
		}
		return header
	}

	/// `ICCPredictHeader` (icc_codec_common.cc:108-138).
	private static func predictHeader(_ icc: [UInt8], _ header: inout [UInt8], _ i: Int) {
		if i == 8 { header.replaceSubrange(80..<84, with: icc[4..<8]) }
		let vendors: [(String, String)] =
			i == 41
			? [("A", "PPL"), ("M", "SFT")]
			: i == 42 ? [("SG", "I "), ("SU", "NW")] : []
		for (prefix, rest) in vendors where icc[40..<i].elementsEqual(prefix.utf8) {
			header.replaceSubrange(i..<44, with: rest.utf8)
		}
	}

	/// `ByteKind1` (icc_codec_common.cc:19-30).
	private static func byteKind1(_ b: UInt8) -> Int {
		switch b {
		case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"): 0
		case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "."), UInt8(ascii: ","): 1
		case 0: 2
		case 1: 3
		case ..<16: 4
		case 255: 6
		case 241...: 5
		default: 7
		}
	}

	/// `ByteKind2` (icc_codec_common.cc:32-40).
	private static func byteKind2(_ b: UInt8) -> Int {
		switch b {
		case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"): 0
		case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "."), UInt8(ascii: ","): 1
		case ..<16: 2
		case 241...: 3
		default: 4
		}
	}

	/// `LinearPredictICCValue` (icc_codec_common.cc:145-169); a 4-byte
	/// predictor reading past `start + i` sees 0.
	private static func linearPredict(
		_ data: [UInt8], start: Int, _ i: Int, stride: Int, width: Int, order: Int
	) -> UInt8 {
		let base = start + (i & ~(width - 1))
		func value(_ k: Int) -> Int {
			let at = base - stride * k
			return width == 4 && at + 4 > start + i ? 0 : beInt(data, at, width)
		}
		let (p1, p2, p3) = (value(1), value(2), value(3))
		let predicted = [p1, 2 * p1 - p2, 3 * p1 - 3 * p2 + p3][order]
		return UInt8(truncatingIfNeeded: predicted >> ((width - 1 - (i & (width - 1))) * 8))
	}

	/// `PredictAndShuffle` (enc_icc_codec.cc:64-86).
	private static func predictAndShuffle(
		_ icc: [UInt8], _ pos: inout Int, _ count: Int, stride: Int, width: Int, order: Int
	) -> [UInt8] {
		let start = pos
		let residuals = (0..<count).map {
			icc[start + $0]
				&- linearPredict(
					icc, start: start, $0, stride: stride, width: width,
					order: order)
		}
		pos += count
		return width > 1 ? unshuffle(residuals, width: width) : residuals
	}

	/// `Unshuffle` (enc_icc_codec.cc:39-59): transposes `width` columns.
	private static func unshuffle(_ bytes: some Collection<UInt8>, width: Int) -> [UInt8] {
		let height = (bytes.count + width - 1) / width
		var result = [UInt8](repeating: 0, count: bytes.count)
		var column = 0
		var j = 0
		for byte in bytes {
			result[j] = byte
			j += height
			if j >= bytes.count {
				column += 1
				j = column
			}
		}
		return result
	}
}
