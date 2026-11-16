#if (os(macOS) && !targetEnvironment(macCatalyst)) || os(Linux)
	import Foundation
	import Testing

	@testable import JXLEncoder

	@Suite("Selected modular DC native integration")
	struct ModularDCNativeIntegrationTests {
		static let nativeHarnessPath = ProcessInfo.processInfo.environment[
			"JXL_HARNESS_PATH"]
		static var nativeDecoderPath: String? {
			guard let nativeHarnessPath else { return nil }
			return URL(fileURLWithPath: nativeHarnessPath)
				.deletingLastPathComponent()
				.appendingPathComponent("libjxl/tools/djxl").path
		}

		static func readPFM(_ data: Data) throws -> (
			width: Int, height: Int, samples: [Float]
		) {
			let bytes = [UInt8](data)
			var offset = 0
			func token() throws -> String {
				while offset < bytes.count && bytes[offset] <= 32 { offset += 1 }
				let start = offset
				while offset < bytes.count && bytes[offset] > 32 { offset += 1 }
				guard start < offset else { throw SemanticDumpError.unimplemented }
				return String(decoding: bytes[start..<offset], as: UTF8.self)
			}
			guard try token() == "PF", let width = Int(try token()),
				let height = Int(try token()), let scale = Float(try token()),
				scale != 0
			else { throw SemanticDumpError.unimplemented }
			offset += 1
			let pixelCount = width * height * 3
			guard bytes.count - offset == pixelCount * MemoryLayout<Float>.size else {
				throw SemanticDumpError.unimplemented
			}
			let output = (0..<pixelCount).map { index -> Float in
				let byte = offset + index * 4
				let bits: UInt32
				if scale < 0 {
					bits =
						UInt32(bytes[byte]) | UInt32(bytes[byte + 1]) << 8
						| UInt32(bytes[byte + 2]) << 16 | UInt32(
							bytes[byte + 3])
						<< 24
				} else {
					bits =
						UInt32(bytes[byte]) << 24 | UInt32(bytes[byte + 1])
						<< 16
						| UInt32(bytes[byte + 2]) << 8
						| UInt32(bytes[byte + 3])
				}
				return Float(bitPattern: bits) * abs(scale)
			}
			var topDown = [Float](repeating: 0, count: pixelCount)
			for y in 0..<height {
				let sourceY = height - y - 1
				topDown.replaceSubrange(
					y * width * 3..<(y + 1) * width * 3,
					with: output[
						sourceY * width * 3..<(sourceY + 1) * width * 3])
			}
			return (width, height, topDown)
		}
		@Test(
			"independent modular payloads decode in either order with final ANS state",
			.enabled(if: nativeHarnessPath != nil))
		func modularPayloadsUseIndependentANSStates() throws {
			let fixture = try EntropyReferenceFixture.load("stream_shared_ans")
			guard
				case .integers(let contextMap)? = fixture.input.fields[
					"input.streams.context_map"],
				case .integers(let logAlpha)? = fixture.input.fields[
					"input.streams.log_alpha_size"],
				case .integers(let frequencies)? = fixture.input.fields[
					"input.streams.frequencies"],
				case .integers(let lengths)? = fixture.input.fields[
					"input.streams.lengths"],
				case .integers(let tokenValues)? = fixture.input.fields[
					"input.streams.tokens"]
			else { throw SemanticDumpError.unimplemented }
			var offset = 0
			let streams = lengths.map { length in
				(0..<Int(length)).map { _ -> Token in
					defer { offset += 2 }
					return Token(
						context: UInt32(tokenValues[offset]),
						value: UInt32(tokenValues[offset + 1]))
				}
			}
			let table = ANSInfoTable.build(
				distribution: frequencies.map(Int.init),
				alphabetSize: frequencies.count,
				logAlphaSize: Int(logAlpha[0]))
			let code = EntropyCode(
				contextMap: contextMap.map(UInt8.init), prefixCodes: [],
				ansInfoTables: [table])
			let dump = SwiftEntropySemanticEncoding.tokenStreams(
				tokens: streams, code: code)
			#expect(dump.differences(from: fixture.expected).isEmpty)
			let directory = FileManager.default.temporaryDirectory
				.appendingPathComponent(
					"jxl-ans-payload-witness-\(UUID().uuidString)")
			try FileManager.default.createDirectory(
				at: directory, withIntermediateDirectories: true)
			defer { try? FileManager.default.removeItem(at: directory) }
			let inputURL = directory.appendingPathComponent("streams.sem")
			try dump.serialized.write(to: inputURL, atomically: true, encoding: .utf8)
			let process = Process()
			process.executableURL = URL(
				fileURLWithPath: try #require(Self.nativeHarnessPath))
			process.arguments = ["entropy-verify-streams", inputURL.path]
			let output = Pipe()
			let errors = Pipe()
			process.standardOutput = output
			process.standardError = errors
			try process.run()
			let data = output.fileHandleForReading.readDataToEndOfFile()
			process.waitUntilExit()
			let errorText = String(
				decoding: errors.fileHandleForReading.readDataToEndOfFile(),
				as: UTF8.self)
			guard process.terminationStatus == 0 else {
				Issue.record("independent stream decode failed: \(errorText)")
				return
			}
			let receipt = try SemanticDump(
				parsing: String(decoding: data, as: UTF8.self))
			#expect(
				receipt.fields["entropy.stream_receipt.code_is_ans"]
					== .integers([1]))
			#expect(
				receipt.fields["entropy.stream_receipt.stream_count"]
					== .integers([2]))
			#expect(
				receipt.fields["entropy.stream_receipt.order_passes"]
					== .integers([0, 1, 1, 0]))
			#expect(
				receipt.fields["entropy.stream_receipt.decoded_token_count"]
					== .integers([16]))
			guard
				case .integers(let readers)? = receipt.fields[
					"entropy.stream_receipt.readers"]
			else {
				Issue.record("missing independent decoder receipts")
				return
			}
			#expect(readers == [32, 1, 32, 1, 32, 1, 32, 1])
		}

		@Test(
			"JPEG codestream decodes and preserves source coefficient semantics",
			.enabled(if: nativeHarnessPath != nil))
		func encodedJPEGRecoversExactCoefficients() throws {
			let fixture = try JPEGParserTests.fixture("hopper_420_restart")
			let transcode = try JPEGTranscode(JPEGParser.parse(fixture))
			let codestream = try Encoder.encodeJPEG(transcode)
			let directory = FileManager.default.temporaryDirectory
				.appendingPathComponent("jxl-jpeg-witness-\(UUID().uuidString)")
			try FileManager.default.createDirectory(
				at: directory, withIntermediateDirectories: true)
			defer { try? FileManager.default.removeItem(at: directory) }
			let sourceURL = directory.appendingPathComponent("source.jpg")
			let codestreamURL = directory.appendingPathComponent("encoded.jxl")
			try Data(fixture).write(to: sourceURL)
			try Data(codestream).write(to: codestreamURL)

			let process = Process()
			process.executableURL = URL(
				fileURLWithPath: try #require(Self.nativeHarnessPath))
			process.arguments = [
				"jpeg-witness", sourceURL.path, codestreamURL.path,
			]
			let output = Pipe()
			process.standardOutput = output
			process.standardError = FileHandle.nullDevice
			try process.run()
			let data = output.fileHandleForReading.readDataToEndOfFile()
			process.waitUntilExit()
			#expect(process.terminationStatus == 0)
			let witness = try SemanticDump(
				parsing: String(decoding: data, as: UTF8.self))
			#expect(witness.fields["jpeg_context.size"] == .integers([26, 26]))
			#expect(
				witness.fields["jpeg_context.reconstructed_coefficients_exact"]
					== .integers([1]))
			#expect(witness.fields["jpeg_context.group_count"] == .integers([1]))
			#expect(witness.fields["jpeg_context.g0.token_count"] == .integers([19068]))
		}

		@Test(
			"encoded multi-group pixels decode with meaningful reconstruction and clean seams",
			.enabled(if: nativeHarnessPath != nil))
		func encodedPixelDCDecodesAcrossGroups() throws {
			let size = 600
			var source = [UInt8](repeating: 0, count: size * size * 3)
			for y in 0..<size {
				for x in 0..<size {
					let i = (y * size + x) * 3
					source[i] = UInt8(x * 255 / (size - 1))
					source[i + 1] = UInt8(y * 255 / (size - 1))
					source[i + 2] = UInt8((x + y) * 255 / (2 * (size - 1)))
				}
			}
			let encoded = try Encoder.encode(
				ImageBuffer(width: size, height: size, samples: source),
				distance: 1.0)
			let directory = FileManager.default.temporaryDirectory
				.appendingPathComponent("jxl-pixel-witness-\(UUID().uuidString)")
			try FileManager.default.createDirectory(
				at: directory, withIntermediateDirectories: true)
			defer { try? FileManager.default.removeItem(at: directory) }
			let inputURL = directory.appendingPathComponent("encoded.jxl")
			let outputURL = directory.appendingPathComponent("decoded.pfm")
			try Data(encoded).write(to: inputURL)
			let process = Process()
			process.executableURL = URL(
				fileURLWithPath: try #require(Self.nativeDecoderPath))
			process.arguments = [inputURL.path, outputURL.path, "--quiet"]
			try process.run()
			process.waitUntilExit()
			#expect(process.terminationStatus == 0)
			let outputData = try Data(contentsOf: outputURL)
			let decoded = try Self.readPFM(outputData)
			#expect(decoded.width == size && decoded.height == size)
			#expect(decoded.samples.count == size * size * 3)
			for channel in 0..<3 {
				let values = stride(from: channel, to: decoded.samples.count, by: 3)
					.map { Int(decoded.samples[$0] * 1000) }
				#expect(Set(values).count > 128)
			}
			func meanError(_ xRange: Range<Int>) -> Double {
				var total = 0
				for y in 0..<size {
					for x in xRange {
						let i = (y * size + x) * 3
						for channel in 0..<3 {
							let expected =
								Double(source[i + channel]) / 255
							let actual = Double(
								decoded.samples[i + channel])
							total += Int(abs(expected - actual) * 255)
						}
					}
				}
				return Double(total) / Double(size * xRange.count * 3)
			}
			let overall = meanError(0..<size)
			#expect(overall < 12)
			for boundary in [256, 512] {
				#expect(
					meanError((boundary - 8)..<(boundary + 8)) < overall * 2 + 4
				)
			}
		}
	}
#endif
