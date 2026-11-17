/// Synchronously schedules independent encoding workers.
@available(iOS 18, macOS 15, *)
public protocol ParallelRunner: Sendable {
	/// The positive limit on simultaneously active operations within each run.
	///
	/// Concurrent calls have separate limits; this is not a runner-wide worker budget.
	var maximumWorkers: Int { get }

	/// Runs every iteration exactly once and waits for all operations to finish.
	///
	/// Operations may execute in any order. None may remain running after return.
	/// Zero iterations invokes no operation. `iterations` must be nonnegative.
	func run(iterations: Int, _ operation: @Sendable (Int) -> Void)
}

extension Encoder {
	/// Encodes pixels synchronously using bounded internal parallelism.
	///
	/// Blocks the calling thread until encoding finishes. Produces the same bytes as
	/// serial encoding. The runner bounds active work, not total frame storage.
	@available(iOS 18, macOS 15, *)
	public static func encode(
		_ image: ImageBuffer,
		distance: Float,
		transferFunction: TransferFunction = .sRGB,
		optimizeCodes: Bool = true,
		runner: any ParallelRunner
	) throws -> [UInt8] {
		fatalError("Synchronous parallel encoding is not implemented")
	}
}
