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
			guard let harness = Self.harness else { return }
			for name in ["scan_420_111", "scan_422_21", "scan_440_12"] {
				let source = try JPEGParserTests.fixture(name)
				let transcode = try JPEGTranscode(JPEGParser.parse(source))
				let directory = FileManager.default.temporaryDirectory
					.appendingPathComponent("jpeg-reader-\(UUID().uuidString)")
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
				let errors = Pipe()
				process.standardOutput = output
				process.standardError = errors
				try process.run()
				let data = output.fileHandleForReading.readDataToEndOfFile()
				process.waitUntilExit()
				let errorText = String(
					decoding: errors.fileHandleForReading.readDataToEndOfFile(),
					as: UTF8.self)
				#expect(
					process.terminationStatus == 0,
					Comment(rawValue: "\(name): \(errorText)"))
				guard process.terminationStatus == 0 else { continue }
				let witness = try SemanticDump(
					parsing: String(decoding: data, as: UTF8.self))
				#expect(
					witness.fields[
						"jpeg_context.reconstructed_coefficients_exact"]
						== .integers([1]),
					Comment(rawValue: name))
			}
		}

		static let harness = ProcessInfo.processInfo.environment["JXL_HARNESS_PATH"]
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
