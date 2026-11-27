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
	@available(iOS 18, macOS 15, *)
	static func computePixelGroups(
		pixelFrame: PixelFrameInput, params: DistanceParams,
		runner: any ParallelRunner, maximumWorkers: Int
	) -> [ACGroupCompute] {
		let dim = pixelFrame.dim
		return ParallelWork.drain(
			Array(0..<dim.groupCount), maximumWorkers: maximumWorkers,
			runner: runner
		) { index in
			computeACGroup(
				xybAt: pixelFrame.xybAt, dim: dim,
				groupX: index % dim.widthInGroups,
				groupY: index / dim.widthInGroups, params: params)
		}
	}

	@available(iOS 18, macOS 15, *)
	static func tokenizePixelGroups(
		computes: consuming [ACGroupCompute], dim: ImageDim,
		analysis: PixelFrameAnalysis,
		runner: any ParallelRunner, maximumWorkers: Int
	) -> [ACGroupOutput] {
		let mode = SectionWriter.Mode.staging(analysis.acCode)
		return ParallelWork.drain(
			consume computes, maximumWorkers: maximumWorkers, runner: runner
		) { compute in
			tokenizeACGroup(compute, analysis: analysis, mode: mode)
		}
	}

	/// Encodes pixels synchronously using bounded internal parallelism.
	///
	/// Blocks the calling thread until encoding finishes. Produces the same bytes as
	/// serial encoding. The runner bounds active work, not total frame storage.
	@available(iOS 18, macOS 15, *)
	public static func encode(
		_ image: ImageBuffer,
		distance: Float,
		transferFunction: TransferFunction = .sRGB,
		runner: any ParallelRunner
	) throws -> [UInt8] {
		let maximumWorkers = runner.maximumWorkers
		guard maximumWorkers > 0 else {
			throw EncoderError.invalidWorkerCount(maximumWorkers)
		}
		let params = try DistanceParams(distance: distance)
		let pixelFrame = preparePixelFrame(
			stripeAt: linearizingStripeSource(image),
			width: image.width, height: image.height, params: params)
		let dim = pixelFrame.dim

		var writer = BitWriter()
		try ImageHeader.write(
			width: image.width, height: image.height,
			transferFunction: transferFunction, to: &writer)
		var sections = initialPixelSections(dim: dim)
		let computes = Self.computePixelGroups(
			pixelFrame: pixelFrame, params: params, runner: runner,
			maximumWorkers: maximumWorkers)
		let analysis = analyzePixelFrame(
			computes: computes, dim: dim, params: params)
		let outputs = Self.tokenizePixelGroups(
			computes: consume computes, dim: dim, analysis: analysis,
			runner: runner, maximumWorkers: maximumWorkers)
		try finishPixelFrame(
			outputs: outputs, dim: dim, params: params, analysis: analysis,
			sections: &sections, writer: &writer)
		writer.zeroPadToByte()
		return writer.take()
	}
}
