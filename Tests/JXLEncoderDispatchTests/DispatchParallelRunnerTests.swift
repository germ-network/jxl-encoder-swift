import Dispatch
import JXLEncoder
import Synchronization
import Testing

@testable import JXLEncoderDispatch

@Suite("Dispatch parallel encoding")
struct DispatchParallelRunnerTests {
	@Test
	func dispatchEncodingMatchesSerial() throws {
		guard #available(iOS 18, macOS 15, *) else { return }
		let image = try ImageBuffer(
			width: 257, height: 257,
			samples: (0..<(257 * 257 * 3)).map { UInt8($0 % 256) }, channels: 3)
		let runner = try DispatchParallelRunner(maximumWorkers: 2)
		#expect(
			try Encoder.encode(image, distance: 1)
				== Encoder.encode(image, distance: 1, runner: runner))
	}

	@Test
	func dispatchRunnerVisitsEachIterationExactlyOnce() throws {
		guard #available(iOS 18, macOS 15, *) else { return }
		let runner = try DispatchParallelRunner(maximumWorkers: 2)
		for iterations in [0, 1, 17] {
			let visits = Mutex([Int](repeating: 0, count: iterations))
			runner.run(iterations: iterations) { index in
				visits.withLock { $0[index] += 1 }
			}
			#expect(visits.withLock { $0 } == [Int](repeating: 1, count: iterations))
		}
	}

	@Test
	func dispatchRunnerBoundsDirectCalls() throws {
		guard #available(iOS 18, macOS 15, *) else { return }
		let runner = try DispatchParallelRunner(maximumWorkers: 2)
		#expect(
			DispatchParallelRunner.concurrentWorkerCount(
				iterations: 19, maximumWorkers: runner.maximumWorkers) == 2)
		#expect(
			DispatchParallelRunner.concurrentWorkerCount(
				iterations: 1, maximumWorkers: runner.maximumWorkers) == 1)
		#expect(
			DispatchParallelRunner.concurrentWorkerCount(
				iterations: 0, maximumWorkers: runner.maximumWorkers) == 0)
	}

	@Test
	func dispatchRunnerJoinsBeforeReturn() throws {
		guard #available(iOS 18, macOS 15, *) else { return }
		let runner = try DispatchParallelRunner(maximumWorkers: 2)
		let gate = DispatchSemaphore(value: 0)
		let started = Mutex(0)
		let completed = Mutex(0)
		runner.run(iterations: 2) { _ in
			let count = started.withLock { value -> Int in
				value += 1
				return value
			}
			if count == 2 {
				gate.signal()
				gate.signal()
			}
			gate.wait()
			completed.withLock { $0 += 1 }
		}
		#expect(completed.withLock { $0 } == 2)
	}

	@Test
	func dispatchRunnerRejectsNonpositiveWorkerCount() throws {
		guard #available(iOS 18, macOS 15, *) else { return }
		for workers in [0, -1, Int.min] {
			#expect(throws: EncoderError.invalidWorkerCount(workers)) {
				try DispatchParallelRunner(maximumWorkers: workers)
			}
		}
	}
}
