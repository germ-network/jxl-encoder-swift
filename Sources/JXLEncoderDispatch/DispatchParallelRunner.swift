import Dispatch
import Foundation
import JXLEncoder

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
		fatalError("Dispatch worker execution is not implemented")
	}
}
