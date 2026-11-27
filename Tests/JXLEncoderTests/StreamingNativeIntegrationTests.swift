#if (os(macOS) && !targetEnvironment(macCatalyst)) || os(Linux)
	import Foundation
	import Testing

	@testable import JXLEncoder

	/// libjxl's own decoder accepts the streaming layout Swift writes.
	@Suite("Streaming independent decoding")
	struct StreamingNativeIntegrationTests {
		static var decoder: String? { FiniteDistanceNativeIntegrationTests.decoder }

		@Test(
			.enabled(if: decoder != nil),
			arguments: [(2048, 256), (2304, 256), (2057, 257)])
		func streamingOutputDecodesWithDjxl(size: (Int, Int)) throws {
			let decoder = try #require(Self.decoder)
			let (width, height) = size
			let image = try ConcurrentEncodeTests.image(width: width, height: height)
			let directory = FileManager.default.temporaryDirectory
				.appendingPathComponent("streaming-decode-\(UUID().uuidString)")
			try FileManager.default.createDirectory(
				at: directory, withIntermediateDirectories: true)
			defer { try? FileManager.default.removeItem(at: directory) }
			let codestream = directory.appendingPathComponent("encoded.jxl")
			let decodedPath = directory.appendingPathComponent("decoded.pfm")
			try Data(Encoder.encode(image, distance: 1))
				.write(to: codestream)
			let process = Process()
			process.executableURL = URL(fileURLWithPath: decoder)
			process.arguments = [codestream.path, decodedPath.path, "--quiet"]
			try process.run()
			process.waitUntilExit()
			#expect(process.terminationStatus == 0)
			let decoded = try ModularDCNativeIntegrationTests.readPFM(
				Data(contentsOf: decodedPath))
			#expect(decoded.width == width)
			#expect(decoded.height == height)
			#expect(decoded.samples.allSatisfy { $0.isFinite })
		}
	}
#endif
