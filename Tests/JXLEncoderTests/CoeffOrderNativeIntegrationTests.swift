#if (os(macOS) && !targetEnvironment(macCatalyst)) || os(Linux)
	import Foundation
	import Testing

	@testable import JXLEncoder

	@Suite("Coefficient order native integration")
	struct CoeffOrderNativeIntegrationTests {
		@Test(
			"serialized scan-derived frames preserve source coefficients",
			.enabled(if: harness != nil))
		func readerSerializationPreservesSourceCoefficients() throws {
			guard Self.harness != nil else { return }
			for (name, expected) in [
				("scan_420_111", "scan_420_111"),
				("scan_420_111_restart", "scan_420_111_restart"),
				("scan_422_21", "scan_422_21"),
				("scan_440_12", "scan_440_12"),
				("scan_420_111_dqt_redefined", "scan_420_111_dqt_canonical"),
			] {
				let source = try JPEGParserTests.fixture(name)
				let transcode = try JPEGTranscode(JPEGParser.parse(source))
				let witness = try Self.jpegWitness(
					sourceJPEG: Data(JPEGParserTests.fixture(expected)),
					codestream: Data(Encoder.encodeJPEG(transcode)),
					name: name)
				#expect(
					witness.fields[
						"jpeg_context.reconstructed_coefficients_exact"]
						== .integers([1]),
					Comment(rawValue: name))
			}
		}

		@Test(
			"Grayscale JPEG streams declare grayscale sRGB with YCbCr and preserve coefficients and quantizers",
			.enabled(if: harness != nil),
			arguments: ["hopper_gray_odd", "hopper_gray_2x2_odd"], [false, true])
		func actualGrayscaleJPEGSerializationCrossCheck(name: String, optimize: Bool) throws
		{
			guard Self.harness != nil else { return }
			let source = try JPEGParserTests.fixture(name)
			let transcode = try JPEGTranscode(JPEGParser.parse(source))
			let codestream =
				if optimize {
					try #require(Encoder.recompressJPEG(source))
				} else {
					try Encoder.encodeJPEG(transcode, optimizeCodes: false)
				}
			let witness = try Self.jpegWitness(
				sourceJPEG: Data(source), codestream: Data(codestream), name: name)
			#expect(
				witness.fields["jpeg_gray.signaling"]
					== .integers([1, 1, 1, 1, 1, 1, 1, 1]),
				Comment(rawValue: name))
		}

		@Test(
			"grayscale JPEG native decoders preserve pixels",
			.enabled(if: nativePixelDecoders != nil),
			arguments: ["hopper_gray_odd", "hopper_gray_2x2_odd"], [false, true])
		func nativeGrayscalePixels(name: String, optimize: Bool) throws {
			guard let nativePixelDecoders = Self.nativePixelDecoders else { return }
			let source = try JPEGParserTests.fixture(name)
			let transcode = try JPEGTranscode(JPEGParser.parse(source))
			let codestream =
				if optimize {
					try #require(Encoder.recompressJPEG(source))
				} else {
					try Encoder.encodeJPEG(transcode, optimizeCodes: false)
				}
			let directory = FileManager.default.temporaryDirectory
				.appendingPathComponent("jpeg-native-pixels-\(UUID().uuidString)")
			try FileManager.default.createDirectory(
				at: directory, withIntermediateDirectories: true)
			defer { try? FileManager.default.removeItem(at: directory) }
			let sourceURL = directory.appendingPathComponent("source.jpg")
			let codestreamURL = directory.appendingPathComponent("encoded.jxl")
			let sourcePixelsURL = directory.appendingPathComponent("source.pnm")
			let outputPixelsURL = directory.appendingPathComponent("output.pnm")
			try Data(source).write(to: sourceURL)
			try Data(codestream).write(to: codestreamURL)
			try Self.run(
				nativePixelDecoders.jpeg,
				[
					"-pnm", "-outfile", sourcePixelsURL.path, sourceURL.path,
				])
			try Self.run(
				nativePixelDecoders.jxl,
				[
					codestreamURL.path, outputPixelsURL.path,
				])
			let sourcePixels = try Self.pnmSamples(Data(contentsOf: sourcePixelsURL))
			let outputPixels = try Self.pnmSamples(Data(contentsOf: outputPixelsURL))
			#expect(sourcePixels.width == outputPixels.width, Comment(rawValue: name))
			#expect(sourcePixels.height == outputPixels.height, Comment(rawValue: name))
			try #require(sourcePixels.samples.count == outputPixels.samples.count)
			let total = zip(sourcePixels.samples, outputPixels.samples).reduce(0.0) {
				$0 + abs(Double($1.0) - Double($1.1))
			}
			let mae = total / Double(sourcePixels.samples.count)
			let receipt =
				"\(name) optimize=\(optimize) size=\(sourcePixels.width)x\(sourcePixels.height) mae=\(mae)\n"
			if let evidenceDirectory = ProcessInfo.processInfo.environment[
				"JXL_PIXEL_EVIDENCE_DIR"]
			{
				let evidenceURL = URL(fileURLWithPath: evidenceDirectory)
					.appendingPathComponent(
						"\(name)-\(optimize ? "optimized" : "static").txt")
				try Data(receipt.utf8).write(to: evidenceURL, options: .atomic)
			}
			#expect(mae < 2.0, Comment(rawValue: receipt))
		}

		static let harness = ProcessInfo.processInfo.environment["JXL_HARNESS_PATH"]
		static func jpegWitness(
			sourceJPEG: Data, codestream: Data, name: String
		) throws -> SemanticDump {
			guard let harness else { throw NSError(domain: "jpeg-witness", code: 1) }
			let directory = FileManager.default.temporaryDirectory
				.appendingPathComponent("jpeg-witness-\(UUID().uuidString)")
			try FileManager.default.createDirectory(
				at: directory, withIntermediateDirectories: true)
			defer { try? FileManager.default.removeItem(at: directory) }
			let sourceURL = directory.appendingPathComponent("source.jpg")
			let codestreamURL = directory.appendingPathComponent("encoded.jxl")
			let outputURL = directory.appendingPathComponent("witness.sem")
			let errorsURL = directory.appendingPathComponent("witness.err")
			try sourceJPEG.write(to: sourceURL)
			try codestream.write(to: codestreamURL)
			FileManager.default.createFile(atPath: outputURL.path, contents: nil)
			FileManager.default.createFile(atPath: errorsURL.path, contents: nil)
			let output = try FileHandle(forWritingTo: outputURL)
			let errors = try FileHandle(forWritingTo: errorsURL)
			let process = Process()
			process.executableURL = URL(fileURLWithPath: harness)
			process.arguments = ["jpeg-witness", sourceURL.path, codestreamURL.path]
			process.standardOutput = output
			process.standardError = errors
			try process.run()
			process.waitUntilExit()
			try output.close()
			try errors.close()
			let errorText = try String(contentsOf: errorsURL, encoding: .utf8)
			guard process.terminationStatus == 0 else {
				throw NSError(
					domain: "jpeg-witness",
					code: Int(process.terminationStatus),
					userInfo: [
						NSLocalizedDescriptionKey: "\(name): \(errorText)"
					])
			}
			return try SemanticDump(
				parsing: String(contentsOf: outputURL, encoding: .utf8))
		}

		static var nativePixelDecoders: (jpeg: String, jxl: String)? {
			guard let harness,
				let jpeg = ProcessInfo.processInfo.environment["JXL_DJPEG_PATH"]
			else { return nil }
			let jxl = URL(fileURLWithPath: harness)
				.deletingLastPathComponent()
				.appendingPathComponent("libjxl/tools/djxl").path
			guard FileManager.default.isExecutableFile(atPath: jpeg),
				FileManager.default.isExecutableFile(atPath: jxl)
			else { return nil }
			return (jpeg, jxl)
		}

		static func run(_ executable: String, _ arguments: [String]) throws {
			let process = Process()
			process.executableURL = URL(fileURLWithPath: executable)
			process.arguments = arguments
			let errors = Pipe()
			process.standardError = errors
			try process.run()
			process.waitUntilExit()
			let errorText = String(
				decoding: errors.fileHandleForReading.readDataToEndOfFile(),
				as: UTF8.self)
			#expect(process.terminationStatus == 0, Comment(rawValue: errorText))
		}

		static func pnmSamples(_ data: Data) throws -> (
			width: Int, height: Int, samples: [UInt8]
		) {
			let bytes = [UInt8](data)
			var offset = 0
			func token() throws -> String {
				while offset < bytes.count {
					if bytes[offset] == 35 {
						while offset < bytes.count && bytes[offset] != 10 {
							offset += 1
						}
					} else if bytes[offset] == 10 || bytes[offset] == 13
						|| bytes[offset] == 32 || bytes[offset] == 9
					{
						offset += 1
					} else {
						break
					}
				}
				let start = offset
				while offset < bytes.count && bytes[offset] != 10
					&& bytes[offset] != 13 && bytes[offset] != 32
					&& bytes[offset] != 9
				{ offset += 1 }
				guard start < offset,
					let value = String(
						bytes: bytes[start..<offset], encoding: .ascii)
				else {
					throw NSError(domain: "PNM", code: 1)
				}
				return value
			}
			guard try token() == "P5",
				let width = Int(try token()), let height = Int(try token()),
				try token() == "255"
			else { throw NSError(domain: "PNM", code: 2) }
			if offset < bytes.count && bytes[offset] == 13 { offset += 1 }
			if offset < bytes.count && bytes[offset] == 10 { offset += 1 }
			let samples = Array(bytes.dropFirst(offset))
			guard samples.count == width * height else {
				throw NSError(domain: "PNM", code: 3)
			}
			return (width, height, samples)
		}
		static var decoder: String? {
			guard let harness else { return nil }
			return URL(fileURLWithPath: harness)
				.deletingLastPathComponent()
				.appendingPathComponent("libjxl/tools/djxl").path
		}

		@Test(
			"default-order pixel codestream decodes natively",
			.enabled(if: decoder != nil))
		func defaultOrderPixelCodestreamDecodes() throws {
			let width = 32
			let height = 32
			var pixels = [UInt8](repeating: 0, count: width * height * 3)
			for y in 0..<height {
				for x in 0..<width {
					let index = (y * width + x) * 3
					pixels[index] = UInt8(x * 255 / (width - 1))
					pixels[index + 1] = UInt8(y * 255 / (height - 1))
					pixels[index + 2] = UInt8(
						(x + y) * 255 / (width + height - 2))
				}
			}
			let counts = [CoeffOrder.ZeroCounts](
				repeating: CoeffOrder.ZeroCounts(), count: 3)
			#expect(
				!CoeffOrder.compute(
					counts: counts, widthInBlocks: 4, heightInBlocks: 4
				).isCustom)
			let directory = FileManager.default.temporaryDirectory
				.appendingPathComponent("coeff-order-default-\(UUID().uuidString)")
			try FileManager.default.createDirectory(
				at: directory, withIntermediateDirectories: true)
			defer { try? FileManager.default.removeItem(at: directory) }
			let codestream = directory.appendingPathComponent("encoded.jxl")
			let decoded = directory.appendingPathComponent("decoded.pfm")
			try Data(
				Encoder.encode(
					ImageBuffer(width: width, height: height, samples: pixels),
					distance: 1.0)
			).write(to: codestream)
			let process = Process()
			process.executableURL = URL(fileURLWithPath: try #require(Self.decoder))
			process.arguments = [codestream.path, decoded.path, "--quiet"]
			try process.run()
			process.waitUntilExit()
			#expect(process.terminationStatus == 0)
			#expect((try? Data(contentsOf: decoded))?.count ?? 0 > 32 * 32 * 3)
		}

		@Test(
			"custom JPEG orders decode to the source coefficients",
			.enabled(if: harness != nil))
		func coefficientOrderSerializationDecodes() throws {
			guard let harness = Self.harness else { return }
			for (name, expectedCustomChannels) in [
				("small_422", 2), ("hopper_420_odd", 3),
				("hopper_420_restart", 3),
			] {
				let source = try JPEGParserTests.fixture(name)
				let transcode = try JPEGTranscode(JPEGParser.parse(source))
				let alignment = (
					x: 1 << transcode.subsampling.maxHorizontalShift,
					y: 1 << transcode.subsampling.maxVerticalShift
				)
				let dim = ImageDim(
					width: transcode.width, height: transcode.height,
					blockAlignment: alignment)
				var counts = [CoeffOrder.ZeroCounts](
					repeating: CoeffOrder.ZeroCounts(), count: 3)
				var sampler = CoeffOrder.Sampler()
				for gy in 0..<dim.heightInGroups {
					for gx in 0..<dim.widthInGroups {
						let rect = dim.pixelRect(
							ix: gx, iy: gy, dim: Geometry.groupDim)
						let groupDim = ImageDim(
							width: rect.width, height: rect.height,
							blockAlignment: alignment)
						let coefficients =
							ACGroupEncoder.jpegCoefficientsForOrdering(
								transcode: transcode,
								blockX0: gx
									* Geometry.groupDimInBlocks,
								blockY0: gy
									* Geometry.groupDimInBlocks,
								widthInBlocks: groupDim
									.widthInBlocks,
								heightInBlocks: groupDim
									.heightInBlocks)
						CoeffOrder.accumulateGroup(
							coefficients,
							widthInBlocks: groupDim.widthInBlocks,
							heightInBlocks: groupDim.heightInBlocks,
							sampler: &sampler, counts: &counts)
					}
				}
				let order = CoeffOrder.compute(
					counts: counts, widthInBlocks: dim.widthInBlocks,
					heightInBlocks: dim.heightInBlocks)
				#expect(order.isCustom)
				#expect(
					order.orders.filter { $0 != CoeffOrder.natural }.count
						== expectedCustomChannels,
					Comment(rawValue: name))

				let directory = FileManager.default.temporaryDirectory
					.appendingPathComponent("coeff-order-\(UUID().uuidString)")
				try FileManager.default.createDirectory(
					at: directory, withIntermediateDirectories: true)
				defer { try? FileManager.default.removeItem(at: directory) }
				let sourceURL = directory.appendingPathComponent("source.jpg")
				let codestreamURL = directory.appendingPathComponent("encoded.jxl")
				try Data(source).write(to: sourceURL)
				try Data(Encoder.encodeJPEG(transcode)).write(to: codestreamURL)
				let process = Process()
				process.executableURL = URL(fileURLWithPath: harness)
				process.arguments = [
					"jpeg-witness", sourceURL.path, codestreamURL.path,
				]
				let output = Pipe()
				process.standardOutput = output
				let errors = Pipe()
				process.standardError = errors
				try process.run()
				let data = output.fileHandleForReading.readDataToEndOfFile()
				process.waitUntilExit()
				let errorText = String(
					decoding: errors.fileHandleForReading.readDataToEndOfFile(),
					as: UTF8.self)
				#expect(
					process.terminationStatus == 0, Comment(rawValue: errorText)
				)
				guard process.terminationStatus == 0 else { continue }
				let witness = try SemanticDump(
					parsing: String(decoding: data, as: UTF8.self))
				#expect(
					witness.fields[
						"jpeg_context.reconstructed_coefficients_exact"]
						== .integers([1]), Comment(rawValue: name))
			}
		}
	}
#endif
