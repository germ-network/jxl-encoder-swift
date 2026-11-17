import Testing

@testable import JXLEncoder

@Suite("Synchronous parallel encoding")
struct SynchronousParallelEncodeTests {
	@Test(.disabled("Implementation pending"))
	func parallelEncodingMatchesSerial() throws { Issue.record("Not implemented") }

	@Test(.disabled("Implementation pending"))
	func parallelWorkerCountOneMatchesSerial() throws { Issue.record("Not implemented") }

	@Test(.disabled("Implementation pending"))
	func parallelRejectsNonpositiveWorkerCount() throws { Issue.record("Not implemented") }

	@Test(.disabled("Implementation pending"))
	func parallelClampsWorkerCountToGroupCount() throws { Issue.record("Not implemented") }

	@Test(.disabled("Implementation pending"))
	func parallelWorkerBoundAndJoinHold() throws { Issue.record("Not implemented") }

	@Test(.disabled("Implementation pending"))
	func parallelComputeBarrierPrecedesGlobalAnalysis() throws {
		Issue.record("Not implemented")
	}

	@Test(.disabled("Implementation pending"))
	func parallelTokenizationDrainsOwnedComputes() throws { Issue.record("Not implemented") }
}
