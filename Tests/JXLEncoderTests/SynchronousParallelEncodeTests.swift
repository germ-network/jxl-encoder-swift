import Dispatch
import Synchronization
import Testing

@testable import JXLEncoder

@available(iOS 18, macOS 15, *)
private struct RunnerMetrics: Sendable {
	var calls: [Int] = []
	var active = 0
	var maximumActive = 0
	var completed = 0
	var completedRuns: [Int] = []
}

@available(iOS 18, macOS 15, *)
private final class RunnerMetricsBox: Sendable {
	let state = Mutex(RunnerMetrics())
}

@available(iOS 18, macOS 15, *)
private struct InlineRunner: ParallelRunner {
	let maximumWorkers: Int
	let metrics = RunnerMetricsBox()

	func run(iterations: Int, _ operation: @Sendable (Int) -> Void) {
		precondition(iterations >= 0)
		metrics.state.withLock { $0.calls.append(iterations) }
		for index in 0..<iterations {
			metrics.state.withLock {
				$0.active += 1
				$0.maximumActive = max($0.maximumActive, $0.active)
			}
			operation(index)
			metrics.state.withLock {
				$0.active -= 1
				$0.completed += 1
			}
		}
	}
}

@available(iOS 18, macOS 15, *)
private struct ConcurrentRunner: ParallelRunner {
	let maximumWorkers: Int
	let metrics = RunnerMetricsBox()

	func run(iterations: Int, _ operation: @Sendable (Int) -> Void) {
		precondition(iterations >= 0 && iterations <= maximumWorkers)
		metrics.state.withLock { $0.calls.append(iterations) }
		DispatchQueue.concurrentPerform(iterations: iterations) { index in
			metrics.state.withLock {
				$0.active += 1
				$0.maximumActive = max($0.maximumActive, $0.active)
			}
			operation(index)
			metrics.state.withLock {
				$0.active -= 1
				$0.completed += 1
			}
		}
		metrics.state.withLock { $0.completedRuns.append(iterations) }
	}
}

@available(iOS 18, macOS 15, *)
private struct ReleaseLedger: Sendable {
	var released: [Int] = []
	var observations: [Int] = []
}

@available(iOS 18, macOS 15, *)
private final class ReleaseLog: Sendable {
	let state = Mutex(ReleaseLedger())
}

@available(iOS 18, macOS 15, *)
private final class DrainProbe: Sendable {
	let id: Int
	let ledger: ReleaseLog

	init(id: Int, ledger: ReleaseLog) {
		self.id = id
		self.ledger = ledger
	}

	deinit {
		ledger.state.withLock { $0.released.append(id) }
	}
}

@Suite("Synchronous parallel encoding")
struct SynchronousParallelEncodeTests {
	private func image(
		width: Int, height: Int, channels: Int = 3, grayscale: Bool = false
	) throws -> ImageBuffer {
		var samples = [UInt8](repeating: 0, count: width * height * channels)
		for y in 0..<height {
			for x in 0..<width {
				let offset = (y * width + x) * channels
				let gray = UInt8((x * 17 + y * 29) % 256)
				samples[offset] = grayscale ? gray : UInt8((x * 7 + y * 3) % 256)
				samples[offset + 1] =
					grayscale ? gray : UInt8((x * 3 + y * 11) % 256)
				samples[offset + 2] = grayscale ? gray : UInt8((x &* y) % 256)
				if channels == 4 { samples[offset + 3] = UInt8((x + y) % 256) }
			}
		}
		return try ImageBuffer(
			width: width, height: height, samples: samples, channels: channels)
	}

	@Test
	func parallelEncodingMatchesSerial() throws {
		guard #available(iOS 18, macOS 15, *) else { return }
		let cases:
			[(
				Int, Int, Int, Bool, Float, TransferFunction
			)] = [
				(64, 64, 3, false, 1, .sRGB),
				(256, 256, 3, false, 1, .linear),
				(301, 301, 3, false, 0.5, .linear),
				(257, 257, 4, false, 3, .sRGB),
				(257, 257, 3, true, 10, .linear),
			]
		for (width, height, channels, grayscale, distance, transferFunction) in cases {
			let source = try image(
				width: width, height: height, channels: channels,
				grayscale: grayscale)
			let runner = InlineRunner(maximumWorkers: 3)
			let serial = try Encoder.encode(
				source, distance: distance, transferFunction: transferFunction)
			let parallel = try Encoder.encode(
				source, distance: distance, transferFunction: transferFunction,
				runner: runner)
			#expect(parallel == serial)
			#expect(runner.metrics.state.withLock { $0.calls.count } == 2)
		}
	}

	@Test
	func parallelWorkerCountOneMatchesSerial() throws {
		guard #available(iOS 18, macOS 15, *) else { return }
		let source = try image(width: 301, height: 301)
		let runner = InlineRunner(maximumWorkers: 1)
		#expect(
			try Encoder.encode(source, distance: 1)
				== Encoder.encode(source, distance: 1, runner: runner))
		#expect(runner.metrics.state.withLock { $0.calls } == [1, 1])
	}

	@Test
	func parallelRejectsNonpositiveWorkerCount() throws {
		guard #available(iOS 18, macOS 15, *) else { return }
		let source = try image(width: 1, height: 1)
		for workers in [0, -1, Int.min] {
			let runner = InlineRunner(maximumWorkers: workers)
			#expect(throws: EncoderError.invalidWorkerCount(workers)) {
				try Encoder.encode(source, distance: 1, runner: runner)
			}
			#expect(runner.metrics.state.withLock { $0.calls.isEmpty })
		}
	}

	@Test
	func parallelClampsWorkerCountToGroupCount() throws {
		guard #available(iOS 18, macOS 15, *) else { return }
		let single = try image(width: 64, height: 64)
		let oneRunner = InlineRunner(maximumWorkers: Int.max)
		_ = try Encoder.encode(single, distance: 1, runner: oneRunner)
		#expect(oneRunner.metrics.state.withLock { $0.calls } == [1, 1])

		let multiple = try image(width: 257, height: 257)
		let manyRunner = InlineRunner(maximumWorkers: Int.max)
		_ = try Encoder.encode(multiple, distance: 1, runner: manyRunner)
		#expect(manyRunner.metrics.state.withLock { $0.calls } == [4, 4])
	}

	@Test
	func parallelWorkerBoundAndJoinHold() throws {
		guard #available(iOS 18, macOS 15, *) else { return }
		let source = try image(width: 257, height: 257)
		let runner = ConcurrentRunner(maximumWorkers: 2)
		_ = try Encoder.encode(source, distance: 1, runner: runner)
		let metrics = runner.metrics.state.withLock { $0 }
		#expect(metrics.calls == [2, 2])
		#expect(metrics.maximumActive <= runner.maximumWorkers)
		#expect(metrics.active == 0)
		#expect(metrics.completed == 4)
		#expect(metrics.completedRuns == [2, 2])

		let operationState = Mutex((active: 0, maximumActive: 0))
		let results = ParallelWork.drain(
			Array(0..<4), maximumWorkers: 2, runner: runner
		) { value in
			operationState.withLock { state in
				state.active += 1
				state.maximumActive = max(state.maximumActive, state.active)
			}
			for step in 0..<100 { _ = step &* value }
			operationState.withLock { $0.active -= 1 }
			return value
		}
		#expect(results.sorted() == Array(0..<4))
		let operationMetrics = operationState.withLock { $0 }
		#expect(operationMetrics.maximumActive <= 2)
		#expect(operationMetrics.active == 0)

		let serialRunner = InlineRunner(maximumWorkers: 2)
		let serialResults = ParallelWork.drain(
			Array(0..<4), maximumWorkers: 2, runner: serialRunner
		) { $0 }
		#expect(serialResults.sorted() == Array(0..<4))
		let serialMetrics = serialRunner.metrics.state.withLock { $0 }
		#expect(serialMetrics.completed == 2)
		#expect(serialMetrics.active == 0)
	}

	@Test
	func parallelComputeBarrierPrecedesGlobalAnalysis() throws {
		guard #available(iOS 18, macOS 15, *) else { return }
		let source = try image(width: 301, height: 301)
		let params = try DistanceParams(distance: 1)
		let pixelFrame = Encoder.preparePixelFrame(
			stripeAt: Encoder.linearizingStripeSource(source),
			width: source.width, height: source.height, params: params)
		let runner = ConcurrentRunner(maximumWorkers: Int.max)
		_ = try Encoder.encode(source, distance: 1, runner: runner)
		let groupCount = pixelFrame.dim.groupCount
		let encodeMetrics = runner.metrics.state.withLock { $0 }
		#expect(encodeMetrics.calls == [groupCount, groupCount])
		#expect(encodeMetrics.completedRuns == [groupCount, groupCount])
		#expect(encodeMetrics.active == 0)

		let computeRunner = ConcurrentRunner(maximumWorkers: Int.max)
		let computes = Encoder.computePixelGroups(
			pixelFrame: pixelFrame, params: params, runner: computeRunner,
			maximumWorkers: computeRunner.maximumWorkers)
		#expect(computes.count == pixelFrame.dim.groupCount)
		#expect(
			computeRunner.metrics.state.withLock { $0.calls }
				== [pixelFrame.dim.groupCount])
		let analysis = Encoder.analyzePixelFrame(
			computes: computes, dim: pixelFrame.dim, params: params)
		#expect(analysis.coeffOrder.orders.count == 3)
		#expect(analysis.coeffOrder.isCustom)
	}

	@Test
	func parallelTokenizationDrainsOwnedComputes() throws {
		guard #available(iOS 18, macOS 15, *) else { return }
		let ledger = ReleaseLog()
		let probes = (0..<4).map { DrainProbe(id: $0, ledger: ledger) }
		let runner = InlineRunner(maximumWorkers: 1)
		let results = ParallelWork.drain(
			consume probes, maximumWorkers: 1, runner: runner
		) { probe in
			ledger.state.withLock { $0.observations.append($0.released.count) }
			return probe.id
		}
		#expect(results == [3, 2, 1, 0])
		let final = ledger.state.withLock { $0 }
		#expect(final.observations == [0, 1, 2, 3])
		#expect(final.released.sorted() == [0, 1, 2, 3])
	}
}
