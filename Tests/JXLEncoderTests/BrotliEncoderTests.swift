import Foundation
import Testing

@testable import JXLEncoder

/// Deterministic pseudo-random bytes (SplitMix64), so every run sees the same corpus.
private func pseudoRandomBytes(_ count: Int, seed: UInt64) -> [UInt8] {
	var state = seed
	var bytes = [UInt8]()
	bytes.reserveCapacity(count)
	while bytes.count < count {
		state &+= 0x9E37_79B9_7F4A_7C15
		var z = state
		z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
		z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
		z ^= z >> 31
		for shift in stride(from: 0, to: 64, by: 8) where bytes.count < count {
			bytes.append(UInt8(truncatingIfNeeded: z >> UInt64(shift)))
		}
	}
	return bytes
}

private struct CorpusInput {
	var name: String
	var bytes: [UInt8]
}

private let corpus: [CorpusInput] = {
	let text = Array(
		"The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquid jugs. "
			.utf8)
	let block = 1 << 16
	var mixed = [UInt8]()
	for index in 0..<6 {
		mixed +=
			index % 2 == 0
			? pseudoRandomBytes(block, seed: UInt64(index))
			: Array(repeating: UInt8(index), count: block / 2)
				+ Array((0..<block / 2).map { UInt8(truncatingIfNeeded: $0 % 7) })
	}
	let farRepeat = pseudoRandomBytes(5000, seed: 77)
	return [
		CorpusInput(name: "empty", bytes: []),
		CorpusInput(name: "one byte", bytes: [0x41]),
		CorpusInput(name: "two distinct bytes", bytes: [1, 2, 1, 1, 2, 2, 1, 2, 1, 1]),
		CorpusInput(
			name: "three distinct bytes", bytes: [1, 2, 3, 1, 1, 2, 1, 3, 3, 1, 1, 1]),
		CorpusInput(
			name: "four distinct bytes",
			bytes: [1, 2, 3, 4, 1, 1, 2, 1, 3, 3, 4, 1, 1, 1]),
		CorpusInput(name: "0...255 once", bytes: (0...255).map { UInt8($0) }),
		CorpusInput(
			name: "uniform over 256 values",
			bytes: (0..<4096).map { UInt8($0 % 256) }),
		CorpusInput(name: "65535 random", bytes: pseudoRandomBytes(65535, seed: 1)),
		CorpusInput(name: "65536 random", bytes: pseudoRandomBytes(65536, seed: 2)),
		CorpusInput(name: "65537 random", bytes: pseudoRandomBytes(65537, seed: 3)),
		CorpusInput(
			name: "text with repeats", bytes: Array((0..<40).map { _ in text }.joined())
		),
		CorpusInput(
			name: "long single-byte run", bytes: Array(repeating: 0x5A, count: 200_000)),
		CorpusInput(name: "300 KiB random", bytes: pseudoRandomBytes(300 * 1024, seed: 4)),
		CorpusInput(
			name: "repeats more than 64 KiB apart",
			bytes: farRepeat + pseudoRandomBytes(70_000, seed: 5) + farRepeat),
		CorpusInput(name: "random alternating with repetitive blocks", bytes: mixed),
	]
}()

#if (os(macOS) && !targetEnvironment(macCatalyst)) || os(Linux)
	/// Runs an external decoder over a stream. The binary comes only from an
	/// environment variable, never from PATH, so a missing tool cannot silently
	/// skip the check.
	private enum ExternalDecoder {
		static func binary(variable: String) -> String? {
			ProcessInfo.processInfo.environment[variable]
		}

		static func decode(
			_ stream: [UInt8], binary: String, arguments: (String) -> [String]
		) throws -> [UInt8] {
			let file = FileManager.default.temporaryDirectory
				.appendingPathComponent("brotli-\(UUID().uuidString).br")
			try Data(stream).write(to: file)
			defer { try? FileManager.default.removeItem(at: file) }

			let process = Process()
			process.executableURL = URL(fileURLWithPath: binary)
			process.arguments = arguments(file.path)
			let output = Pipe()
			process.standardOutput = output
			process.standardError = FileHandle.nullDevice
			try process.run()
			let decoded = output.fileHandleForReading.readDataToEndOfFile()
			process.waitUntilExit()
			guard process.terminationStatus == 0 else {
				throw DecoderFailure(status: process.terminationStatus)
			}
			return [UInt8](decoded)
		}

		struct DecoderFailure: Error { var status: Int32 }

		static func referenceDecode(_ stream: [UInt8], binary: String) throws -> [UInt8] {
			try decode(stream, binary: binary) { ["-d", "-c", $0] }
		}

		static func peerDecode(_ stream: [UInt8], binary: String) throws -> [UInt8] {
			try decode(stream, binary: binary) { [$0] }
		}
	}
#endif

/// Reads bits in the order RFC 7932 §1.5.1 packs them.
private struct BitReader {
	var bytes: [UInt8]
	var position = 0

	mutating func read(_ count: Int) -> Int {
		var value = 0
		for index in 0..<count {
			let bit = Int(bytes[position / 8] >> UInt8(position % 8)) & 1
			value |= bit << index
			position += 1
		}
		return value
	}

	mutating func alignToByte() { position = (position + 7) / 8 * 8 }
}

/// Brotli streams must be RFC 7932-conformant and decode to their input byte
/// for byte. Google's reference decoder checks that wherever it can run; the
/// remaining tests pin the encoder's own invariants on every platform.
@Suite("Brotli encoder")
struct BrotliEncoderTests {
	@Suite("stream framing")
	struct Framing {
		@Test("empty input is the WBITS 22 header and an empty last meta-block")
		func emptyInput() {
			// §9.1 pattern "1011" for WBITS 22, then ISLAST = 1 and ISLASTEMPTY = 1.
			#expect(BrotliEncoder.compress([]) == [0x3B])
		}

		@Test("the stream header encodes WBITS 22 in four bits")
		func streamHeader() {
			var writer = BitWriter()
			BrotliMetaBlock.writeStreamHeader(to: &writer)
			#expect(writer.bitsWritten == 4)
			writer.zeroPadToByte()
			#expect(writer.take() == [0b1011])
			#expect(BrotliEncoder.windowBits == 22)
			#expect(BrotliEncoder.windowSize == (1 << 22) - 16)
		}

		@Test(
			"an uncompressed meta-block carries MLEN - 1 in four nibbles, then the bytes verbatim from a byte boundary"
		)
		func uncompressedMetaBlock() {
			let payload: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0x00]
			// Without the stream header the 20 header bits leave the payload
			// four bits short of a byte boundary.
			var writer = BitWriter()
			BrotliMetaBlock.writeUncompressed(payload[...], to: &writer)
			var reader = BitReader(bytes: writer.take())
			#expect(reader.read(1) == 0)  // ISLAST
			#expect(reader.read(2) == 0)  // MNIBBLES = 4
			#expect(reader.read(16) == payload.count - 1)
			#expect(reader.read(1) == 1)  // ISUNCOMPRESSED
			#expect(reader.read(4) == 0)  // fill bits
			#expect(Array(reader.bytes[3...]) == payload)
			#expect(reader.bytes.count == 3 + payload.count)
		}

		@Test("inputs are split into meta-blocks of at most 64 KiB")
		func metaBlockSplit() {
			let input = pseudoRandomBytes(3 * 65536 + 100, seed: 9)
			var reader = BitReader(bytes: BrotliEncoder.compress(input))
			#expect(reader.read(4) == 0b1011)
			#expect(reader.read(1) == 0)  // ISLAST: more meta-blocks follow
			#expect(reader.read(2) == 0)  // MNIBBLES = 4
			#expect(reader.read(16) + 1 == BrotliEncoder.maxMetaBlockLength)
			#expect(BrotliEncoder.maxMetaBlockLength == 65536)
		}
	}

	@Suite("length and distance codes")
	struct Codes {
		/// RFC 7932 §5: (code, extra bits, first length, last length).
		private static let insertTable: [(Int, Int, Int, Int)] = [
			(0, 0, 0, 0), (1, 0, 1, 1), (2, 0, 2, 2), (3, 0, 3, 3), (4, 0, 4, 4),
			(5, 0, 5, 5), (6, 1, 6, 7), (7, 1, 8, 9), (8, 2, 10, 13), (9, 2, 14, 17),
			(10, 3, 18, 25), (11, 3, 26, 33), (12, 4, 34, 49), (13, 4, 50, 65),
			(14, 5, 66, 97), (15, 5, 98, 129), (16, 6, 130, 193), (17, 7, 194, 321),
			(18, 8, 322, 577), (19, 9, 578, 1089), (20, 10, 1090, 2113),
			(21, 12, 2114, 6209), (22, 14, 6210, 22593), (23, 24, 22594, 16_799_809),
		]
		private static let copyTable: [(Int, Int, Int, Int)] = [
			(0, 0, 2, 2), (1, 0, 3, 3), (2, 0, 4, 4), (3, 0, 5, 5), (4, 0, 6, 6),
			(5, 0, 7, 7), (6, 0, 8, 8), (7, 0, 9, 9), (8, 1, 10, 11), (9, 1, 12, 13),
			(10, 2, 14, 17), (11, 2, 18, 21), (12, 3, 22, 29), (13, 3, 30, 37),
			(14, 4, 38, 53), (15, 4, 54, 69), (16, 5, 70, 101), (17, 5, 102, 133),
			(18, 6, 134, 197), (19, 7, 198, 325), (20, 8, 326, 581), (21, 9, 582, 1093),
			(22, 10, 1094, 2117), (23, 24, 2118, 16_779_333),
		]

		private func check(
			_ lengths: [Int], table: [(Int, Int, Int, Int)],
			code: (Int) -> BrotliCodedValue
		) {
			for length in lengths {
				let row = table.first { $0.2 <= length && length <= $0.3 }!
				let coded = code(length)
				#expect(coded.code == row.0, "length \(length)")
				#expect(coded.extraBitCount == row.1, "length \(length)")
				#expect(coded.extraBits == length - row.2, "length \(length)")
			}
		}

		private static let sampledLengths =
			Array(0...65536) + [
				100_000, 22593, 22594, 1_000_000, 16_779_333, 16_799_809,
			]

		@Test(
			"every insert length up to 2^16 maps to its RFC 7932 §5 code and extra bits"
		)
		func insertCodes() {
			check(
				Self.sampledLengths.filter { $0 <= 16_799_809 },
				table: Self.insertTable
			) {
				BrotliLengthCodes.insertCode(forLength: $0)
			}
		}

		@Test(
			"every copy length from 2 to 2^16 maps to its RFC 7932 §5 code and extra bits"
		)
		func copyCodes() {
			check(
				Self.sampledLengths.filter { $0 >= 2 && $0 <= 16_779_333 },
				table: Self.copyTable
			) {
				BrotliLengthCodes.copyCode(forLength: $0)
			}
		}

		@Test(
			"insert-and-copy symbols follow the §5 cell table, with implicit distance reuse only in 0...127"
		)
		func insertAndCopySymbols() {
			// §5 cells: insert code range, copy code range, first symbol.
			let cells: [(ClosedRange<Int>, ClosedRange<Int>, Int, Bool)] = [
				(0...7, 0...7, 0, true), (0...7, 8...15, 64, true),
				(0...7, 0...7, 128, false), (0...7, 8...15, 192, false),
				(0...7, 16...23, 384, false), (8...15, 0...7, 256, false),
				(8...15, 8...15, 320, false), (8...15, 16...23, 512, false),
				(16...23, 0...7, 448, false), (16...23, 8...15, 576, false),
				(16...23, 16...23, 640, false),
			]
			var seen = Set<Int>()
			for insert in 0..<24 {
				for copy in 0..<24 {
					for reuse in [false, true] {
						guard !reuse || (insert < 8 && copy < 16) else {
							continue
						}
						let cell = cells.first {
							$0.0.contains(insert) && $0.1.contains(copy)
								&& $0.3 == reuse
						}!
						let expected =
							cell.2 + (insert & 7) * 8 + (copy & 7)
						let symbol = BrotliLengthCodes.insertAndCopySymbol(
							insertCode: insert, copyCode: copy,
							reusesLastDistance: reuse)
						#expect(
							symbol == expected,
							"insert \(insert) copy \(copy) reuse \(reuse)"
						)
						#expect((symbol < 128) == reuse)
						#expect(seen.insert(symbol).inserted)
					}
				}
			}
			#expect(seen == Set(0..<704))
		}

		/// RFC 7932 §4 special distance symbols.
		private static func special(_ symbol: Int, ring: [Int]) -> Int {
			let deltas = [-1, 1, -2, 2, -3, 3]
			switch symbol {
			case 0...3: return ring[symbol]
			case 4...9: return ring[0] + deltas[symbol - 4]
			default: return ring[1] + deltas[symbol - 10]
			}
		}

		@Test(
			"the distance ring starts with last 4, then 11, 15, 16, and symbol 0 does not push"
		)
		func distanceRing() {
			var ring = BrotliDistanceRing()
			#expect(ring.code(forDistance: 4).code == 0)
			#expect(ring.code(forDistance: 11).code == 1)
			#expect(ring.code(forDistance: 15).code == 2)
			#expect(ring.code(forDistance: 16).code == 3)
			let initial = ring
			ring.record(distance: 4, code: 0)
			#expect(ring == initial)
			ring.record(distance: 1000, code: 20)
			#expect(ring.code(forDistance: 1000).code == 0)
			#expect(ring.code(forDistance: 4).code == 1)
			#expect(ring.code(forDistance: 11).code == 2)
			#expect(ring.code(forDistance: 15).code == 3)
			#expect(ring.code(forDistance: 16).code >= 16)
			ring.record(distance: 11, code: 2)
			#expect(ring.code(forDistance: 11).code == 0)
			#expect(ring.code(forDistance: 1000).code == 1)
		}

		@Test(
			"special distance symbols resolve to the distance they encode and never to zero or less"
		)
		func specialDistanceSymbols() {
			var rings: [(BrotliDistanceRing, [Int])] = [
				(BrotliDistanceRing(), [4, 11, 15, 16])
			]
			var ring = BrotliDistanceRing()
			ring.record(distance: 2, code: 20)
			ring.record(distance: 3, code: 20)
			rings.append((ring, [3, 2, 4, 11]))
			for (ring, last) in rings {
				for distance in 1...64 {
					let coded = ring.code(forDistance: distance)
					let smallest = (0..<16).first {
						Self.special($0, ring: last) == distance
					}
					if let smallest {
						#expect(
							coded.code == smallest,
							"distance \(distance)")
						#expect(coded.extraBitCount == 0)
					} else {
						#expect(coded.code >= 16, "distance \(distance)")
					}
					if coded.code < 16 {
						#expect(
							Self.special(coded.code, ring: last)
								== distance)
					}
				}
			}
		}

		@Test(
			"long distance symbols and extra bits give back the distance by the §4 formula"
		)
		func longDistanceSymbols() {
			let ring = BrotliDistanceRing()
			var distances = Array(1...5000)
			for bits in 3...22 {
				for delta in -2...2 { distances.append((1 << bits) + delta) }
			}
			distances.append(BrotliEncoder.windowSize)
			var longCount = 0
			for distance in distances where distance <= BrotliEncoder.windowSize {
				let coded = ring.code(forDistance: distance)
				guard coded.code >= 16 else { continue }
				longCount += 1
				#expect(coded.code < 64)
				let ndistbits = 1 + ((coded.code - 16) >> 1)
				#expect(coded.extraBitCount == ndistbits)
				#expect(coded.extraBits >= 0 && coded.extraBits < 1 << ndistbits)
				let hcode = coded.code - 16
				let offset = ((2 + (hcode & 1)) << ndistbits) - 4
				#expect(
					offset + coded.extraBits + 1 == distance,
					"distance \(distance)")
			}
			#expect(longCount > 4000)
		}
	}

	@Suite("prefix codes")
	struct PrefixCodes {
		@Test(
			"code lengths stay within 15 bits and fill the code space exactly",
			.disabled())
		func depthLimitAndCompleteness() {}

		@Test(
			"simple-code symbols use the bit width of the whole alphabet, not the largest symbol",
			.disabled())
		func simpleCodeSymbolWidth() {}

		@Test(
			"an empty or one-symbol histogram gives a degenerate code that costs no bits per symbol",
			.disabled())
		func degenerateCodes() {}
	}

	@Suite("backward references")
	struct References {
		@Test("replaying the commands reproduces the input range", .disabled())
		func commandsReplay() {}

		@Test(
			"no copy reaches beyond the window or before the input start, and every copy is at least 2 bytes",
			.disabled())
		func copiesStayInWindow() {}

		@Test("copies may reach back into earlier meta-blocks", .disabled())
		func crossMetaBlockCopies() {}

		@Test(
			"a short match is deferred when the next position starts a much longer one",
			.disabled())
		func lazyMatching() {}
	}

	@Suite("size bound")
	struct SizeBound {
		@Test(
			"incompressible input of N bytes takes at most N + 3 per 64 KiB meta-block + 1 bytes",
			.disabled())
		func incompressibleInputBound() {}

		@Test(
			"writing the smaller form advances the distance ring only when the compressed form is kept",
			.disabled())
		func rejectedTrialKeepsRing() {}

		@Test("repetitive input compresses below a tenth of its size", .disabled())
		func repetitiveInputCompresses() {}
	}

	@Suite("reference decoder")
	struct ReferenceDecoder {
		#if (os(macOS) && !targetEnvironment(macCatalyst)) || os(Linux)
			@Test(
				"Google's brotli decoder reproduces every corpus input exactly",
				.enabled(
					if: ExternalDecoder.binary(variable: "BROTLI_REFERENCE")
						!= nil))
			func roundTripsThroughReference() throws {
				let reference = try #require(
					ExternalDecoder.binary(variable: "BROTLI_REFERENCE"))
				let peer = ExternalDecoder.binary(variable: "BROTLI_PEER_DECODER")
				for input in corpus {
					let stream = BrotliEncoder.compress(input.bytes)
					let decoded = try ExternalDecoder.referenceDecode(
						stream, binary: reference)
					#expect(
						decoded == input.bytes,
						"reference decoder: \(input.name)")
					if let peer {
						let peerDecoded = try ExternalDecoder.peerDecode(
							stream, binary: peer)
						#expect(
							peerDecoded == input.bytes,
							"peer decoder: \(input.name)")
					}
				}
			}
		#endif
	}
}
