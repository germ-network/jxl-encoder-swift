#if (os(macOS) && !targetEnvironment(macCatalyst)) || os(Linux)
	import Foundation
	import Testing

	@testable import JXLEncoder

	@Suite("Finite distance independent decoding")
	struct FiniteDistanceNativeIntegrationTests {
		static let harness = ProcessInfo.processInfo.environment["JXL_HARNESS_PATH"]
		static var decoder: String? {
			guard let harness else { return nil }
			return URL(fileURLWithPath: harness)
				.deletingLastPathComponent()
				.appendingPathComponent("libjxl/tools/djxl").path
		}

		@Test(.enabled(if: decoder != nil))
		func extremeFiniteCodestreamsDecodeWithFiniteSamples() async throws {
			let decoder = try #require(Self.decoder)
			let width = 9
			let height = 7
			var rgb = [UInt8](repeating: 0, count: width * height * 3)
			var grayRGB = rgb
			for pixel in 0..<(width * height) {
				let value = UInt8((pixel * 37) % 256)
				grayRGB.replaceSubrange(
					pixel * 3..<(pixel + 1) * 3, with: [value, value, value])
				for channel in 0..<3 {
					rgb[pixel * 3 + channel] = UInt8(
						(pixel * (channel * 11 + 7)) % 256)
				}
			}
			let images = [
				try ImageBuffer(width: width, height: height, samples: rgb),
				try ImageBuffer(width: width, height: height, samples: grayRGB),
			]
			let directory = FileManager.default.temporaryDirectory
				.appendingPathComponent(
					"finite-distance-decode-\(UUID().uuidString)")
			try FileManager.default.createDirectory(
				at: directory, withIntermediateDirectories: true)
			defer { try? FileManager.default.removeItem(at: directory) }
			let boundary = Float(bitPattern: 0x4760_70FC)
			for distance in [boundary, Float.greatestFiniteMagnitude] {
				for (index, image) in images.enumerated() {
					let codestream = directory.appendingPathComponent(
						"encoded-\(index)-\(distance).jxl")
					let decodedPath = directory.appendingPathComponent(
						"decoded-\(index)-\(distance).pfm")
					let bytes = try Encoder.encode(image, distance: distance)
					try Data(bytes).write(to: codestream)
					let process = Process()
					process.executableURL = URL(fileURLWithPath: decoder)
					process.arguments = [
						codestream.path, decodedPath.path, "--quiet",
					]
					try process.run()
					process.waitUntilExit()
					#expect(process.terminationStatus == 0)
					let decoded = try ModularDCNativeIntegrationTests.readPFM(
						Data(contentsOf: decodedPath))
					#expect(decoded.width == width)
					#expect(decoded.height == height)
					#expect(decoded.samples.count == width * height * 3)
					#expect(decoded.samples.allSatisfy { $0.isFinite })
				}
			}
		}
	}
#endif
