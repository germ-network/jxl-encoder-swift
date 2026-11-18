import Dispatch
import Foundation
import JXLEncoder
import Synchronization

/// Runs synchronous encoding workers using Dispatch.
@available(iOS 18, macOS 15, *)
public struct DispatchParallelRunner: ParallelRunner {
	public let maximumWorkers: Int

	/// Creates a runner with a positive per-call limit on active operations.
	public init(maximumWorkers: Int = ProcessInfo.processInfo.activeProcessorCount) throws {
		guard maximumWorkers > 0 else {
			throw EncoderError.invalidWorkerCount(maximumWorkers)
		}
		self.maximumWorkers = maximumWorkers
	}

	public func run(iterations: Int, _ operation: @Sendable (Int) -> Void) {
		precondition(iterations >= 0)
		let workerCount = min(maximumWorkers, iterations)
		guard workerCount > 0 else { return }
		let next = Mutex(0)
		DispatchQueue.concurrentPerform(iterations: workerCount) { _ in
			while true {
				let index = next.withLock { value -> Int? in
					guard value < iterations else { return nil }
					defer { value += 1 }
					return value
				}
				guard let index else { return }
				operation(index)
			}
		}
	}
}
