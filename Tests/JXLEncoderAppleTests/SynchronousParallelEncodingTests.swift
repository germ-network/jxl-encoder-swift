#if canImport(ImageIO)

	import CoreGraphics
	import Foundation
	import ImageIO
	import JXLEncoder
	import Synchronization
	import Testing
	import UniformTypeIdentifiers

	@testable import JXLEncoderApple

	@available(iOS 18, macOS 15, *)
	private final class RunnerCallCounter: Sendable {
		let value = Mutex(0)
	}

	@available(iOS 18, macOS 15, *)
	private struct CountingRunner: ParallelRunner {
		let maximumWorkers: Int
		let calls = RunnerCallCounter()

		func run(iterations: Int, _ operation: @Sendable (Int) -> Void) {
			calls.value.withLock { $0 += 1 }
			for index in 0..<iterations { operation(index) }
		}
	}

	@Suite("Synchronous parallel Apple encoding")
	struct SynchronousParallelEncodingTests {
		@Test
		func parallelImageEncodingMatchesSerial() throws {
			guard #available(iOS 18, macOS 15, *) else { return }
			let image = JXLEncoderAppleTests.gradient(width: 301, height: 301)
			let runner = CountingRunner(maximumWorkers: 2)
			#expect(
				try JXLEncoderApple.encode(image: image, distance: 1)
					== JXLEncoderApple.encode(
						image: image, distance: 1, runner: runner))
			#expect(runner.calls.value.withLock { $0 } == 2)
		}

		@Test
		func parallelDataEncodingPreservesDecodePolicies() throws {
			guard #available(iOS 18, macOS 15, *) else { return }
			let source = try JPEGRecompressionTests.orientedJPEG(orientation: 6)
			let runner = CountingRunner(maximumWorkers: 2)
			let encoded = try JXLEncoderApple.encode(data: source, runner: runner)
			let decoded = try #require(JXLEncoderAppleTests.decodeSamples(encoded))
			#expect(decoded.width == 120 && decoded.height == 200)

			let thumbnail = try JXLEncoderApple.encode(
				data: source, maxPixelSize: 64, runner: runner)
			let thumbnailImage = try #require(
				JXLEncoderAppleTests.decodeSamples(thumbnail))
			#expect(max(thumbnailImage.width, thumbnailImage.height) == 64)

			#expect(throws: JXLEncoderAppleError.self) {
				try JXLEncoderApple.encode(
					data: source, maxSourceBytes: 1, runner: runner)
			}
			#expect(throws: JXLEncoderAppleError.alphaNotSupported) {
				try JXLEncoderApple.encode(
					image: JXLEncoderAppleTests.gradient(),
					alphaPolicy: .preserve,
					runner: runner)
			}

			let transparent = JXLEncoderAppleTests.makeImage(
				width: 64, height: 64, alpha: true
			) { context, width, height in
				context.clear(CGRect(x: 0, y: 0, width: width, height: height))
			}
			let png = NSMutableData()
			let destination = CGImageDestinationCreateWithData(
				png, UTType.png.identifier as CFString, 1, nil)!
			CGImageDestinationAddImage(destination, transparent, nil)
			#expect(CGImageDestinationFinalize(destination))
			let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
			let flattened = try JXLEncoderApple.encode(
				data: png as Data, alphaPolicy: .flatten(background: red),
				runner: runner)
			let flattenedSamples = try #require(
				JXLEncoderAppleTests.decodeSamples(flattened))
			#expect(flattenedSamples.rgb[0] > 200)
			#expect(flattenedSamples.rgb[1] < 50)
			#expect(flattenedSamples.rgb[2] < 50)
			#expect(runner.calls.value.withLock { $0 } > 0)
		}

		@Test
		func eligibleJPEGRemainsSerialAndCoefficientPreserving() throws {
			guard #available(iOS 18, macOS 15, *) else { return }
			let source = try JPEGRecompressionTests.fixture("hopper_444")
			let runner = CountingRunner(maximumWorkers: 2)
			let serial = try JXLEncoderApple.encode(data: source)
			let parallel = try JXLEncoderApple.encode(data: source, runner: runner)
			#expect(parallel == serial)
			#expect(runner.calls.value.withLock { $0 } == 0)
		}

		@Test
		func parallelEntryPointsRejectInvalidRunnerBeforeInputWork() throws {
			guard #available(iOS 18, macOS 15, *) else { return }
			let source = try JPEGRecompressionTests.fixture("hopper_444")
			let runner = CountingRunner(maximumWorkers: 0)
			#expect(throws: EncoderError.invalidWorkerCount(0)) {
				try JXLEncoderApple.encode(
					image: JXLEncoderAppleTests.gradient(),
					alphaPolicy: .preserve,
					runner: runner)
			}
			#expect(throws: EncoderError.invalidWorkerCount(0)) {
				try JXLEncoderApple.encode(data: Data([0, 1, 2]), runner: runner)
			}
			#expect(throws: EncoderError.invalidWorkerCount(0)) {
				try JXLEncoderApple.encode(data: source, runner: runner)
			}
			#expect(runner.calls.value.withLock { $0 } == 0)
		}
	}

#endif
