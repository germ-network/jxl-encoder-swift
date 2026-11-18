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
		for maximumWorkers in [1, 2] {
			let runner = try DispatchParallelRunner(maximumWorkers: maximumWorkers)
			for iterations in [0, 1, 17] {
				let state = Mutex(
					(
						visits: [Int](repeating: 0, count: iterations),
						active: 0, peak: 0, completed: 0
					))
				runner.run(iterations: iterations) { index in
					state.withLock {
						$0.active += 1
						$0.peak = max($0.peak, $0.active)
						$0.visits[index] += 1
					}
					for value in 0..<100 { _ = value &* index }
					state.withLock {
						$0.active -= 1
						$0.completed += 1
					}
				}
				let result = state.withLock { $0 }
				#expect(result.visits == [Int](repeating: 1, count: iterations))
				#expect(result.completed == iterations)
				#expect(result.active == 0)
				#expect(result.peak <= maximumWorkers)
			}
		}
	}

	@Test
	func dispatchRunnerBoundsDirectCalls() throws {
		guard #available(iOS 18, macOS 15, *) else { return }
		for maximumWorkers in [1, 2] {
			let runner = try DispatchParallelRunner(maximumWorkers: maximumWorkers)
			for iterations in [0, 1, 19] {
				let completed = Mutex(0)
				runner.run(iterations: iterations) { _ in
					completed.withLock { $0 += 1 }
				}
				#expect(completed.withLock { $0 } == iterations)
			}
		}
	}

	@Test
	func dispatchRunnerJoinsBeforeReturn() throws {
		guard #available(iOS 18, macOS 15, *) else { return }
		let runner = try DispatchParallelRunner(maximumWorkers: 2)
		let completed = Mutex([Bool](repeating: false, count: 17))
		runner.run(iterations: 17) { index in
			completed.withLock { $0[index] = true }
		}
		#expect(completed.withLock { $0 } == [Bool](repeating: true, count: 17))
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
