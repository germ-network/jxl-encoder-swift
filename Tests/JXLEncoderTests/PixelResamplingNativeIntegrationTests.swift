#if os(macOS) && !targetEnvironment(macCatalyst) || os(Linux)
	import Foundation
	import Testing

	@testable import JXLEncoder

	@Suite("Pixel resampling independent decoding")
	struct PixelResamplingNativeIntegrationTests {
		@Test(
			"decoded odd RGB and gray keep dimensions and channel meaning",
			.enabled(if: ModularDCNativeIntegrationTests.nativeDecoderPath != nil))
		func decodedOddRGBAndGrayKeepOutputDimensionsAndMeaning() async throws {
			let width = 1025
			let height = 257
			let seamX = 512
			for gray in [false, true] {
				let channels = 3
				var samples = [UInt8](
					repeating: 0, count: width * height * channels)
				for y in 0..<height {
					for x in 0..<width {
						let offset = (y * width + x) * channels
						if gray {
							let value = UInt8(
								(x + y) * 255 / (width + height - 2)
							)
							samples[offset] = value
							samples[offset + 1] = value
							samples[offset + 2] = value
						} else {
							samples[offset] = UInt8(
								x * 255 / (width - 1))
							samples[offset + 1] = UInt8(
								y * 255 / (height - 1))
							samples[offset + 2] = UInt8(
								(x + y) * 255 / (width + height - 2)
							)
						}
					}
				}
				let image = try ImageBuffer(
					width: width, height: height, samples: samples,
					channels: channels)
				for concurrent in [false, true] {
					let encoded =
						concurrent
						? try await Encoder.encodeConcurrently(
							image, distance: 10)
						: try Encoder.encode(image, distance: 10)
					let directory = FileManager.default.temporaryDirectory
						.appendingPathComponent(
							"jxl-resample-\(UUID().uuidString)")
					try FileManager.default.createDirectory(
						at: directory, withIntermediateDirectories: true)
					defer { try? FileManager.default.removeItem(at: directory) }
					let inputURL = directory.appendingPathComponent("input.jxl")
					let outputURL = directory.appendingPathComponent(
						"output.pfm")
					try Data(encoded).write(to: inputURL)
					let process = Process()
					process.executableURL = URL(
						fileURLWithPath: try #require(
							ModularDCNativeIntegrationTests
								.nativeDecoderPath))
					process.arguments = [
						inputURL.path, outputURL.path, "--quiet",
					]
					try process.run()
					process.waitUntilExit()
					#expect(process.terminationStatus == 0)
					let decoded = try ModularDCNativeIntegrationTests.readPFM(
						Data(contentsOf: outputURL))
					#expect(decoded.width == width && decoded.height == height)
					#expect(decoded.samples.count == width * height * 3)
					for channel in 0..<3 {
						let values = stride(
							from: channel, to: decoded.samples.count,
							by: 3
						)
						.map { Int(decoded.samples[$0] * 100) }
						#expect(Set(values).count > 20)
					}
					if !gray {
						func sample(_ x: Int, _ y: Int, _ channel: Int)
							-> Float
						{
							decoded.samples[
								(y * width + x) * 3 + channel]
						}
						#expect(
							sample(768, 128, 0) - sample(256, 128, 0)
								> 0.3)
						#expect(
							abs(
								sample(768, 128, 1)
									- sample(256, 128, 1))
								< 0.08)
						#expect(
							sample(768, 128, 2) - sample(256, 128, 2)
								> 0.15)
						#expect(
							sample(512, 192, 1) - sample(512, 64, 1)
								> 0.3)
						#expect(
							abs(
								sample(512, 192, 0)
									- sample(512, 64, 0)) < 0.08
						)
						#expect(
							sample(512, 192, 2) - sample(512, 64, 2)
								> 0.05)
					}
					if gray {
						var maxChannelDifference: Float = 0
						for pixel in 0..<(width * height) {
							let i = pixel * 3
							maxChannelDifference = max(
								maxChannelDifference,
								max(
									abs(
										decoded.samples[i]
											- decoded
											.samples[
												i
													+ 1
											]),
									abs(
										decoded.samples[i]
											- decoded
											.samples[
												i
													+ 2
											])))
						}
						#expect(maxChannelDifference < 0.02)
					}
					var maxSeamStep: Float = 0
					var maxNeighborStep: Float = 0
					for y in 2..<(height - 2) {
						for channel in 0..<3 {
							func sample(_ x: Int) -> Float {
								decoded.samples[
									(y * width + x) * 3
										+ channel]
							}
							maxSeamStep = max(
								maxSeamStep,
								abs(
									sample(seamX)
										- sample(seamX - 1))
							)
							for x in (seamX - 5)..<(seamX - 1) {
								maxNeighborStep = max(
									maxNeighborStep,
									abs(
										sample(x + 1)
											- sample(x))
								)
							}
							for x in (seamX + 1)..<(seamX + 5) {
								maxNeighborStep = max(
									maxNeighborStep,
									abs(
										sample(x + 1)
											- sample(x))
								)
							}
						}
					}
					#expect(maxSeamStep <= maxNeighborStep * 3 + 0.01)
				}
			}
		}
	}
#endif
