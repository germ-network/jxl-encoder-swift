import Testing

@testable import JXLEncoderDispatch

@Suite("Dispatch parallel encoding")
struct DispatchParallelRunnerTests {
	@Test(.disabled("Implementation pending"))
	func dispatchEncodingMatchesSerial() throws { Issue.record("Not implemented") }

	@Test(.disabled("Implementation pending"))
	func dispatchRunnerVisitsEachIterationExactlyOnce() throws {
		Issue.record("Not implemented")
	}

	@Test(.disabled("Implementation pending"))
	func dispatchRunnerJoinsBeforeReturn() throws { Issue.record("Not implemented") }

	@Test(.disabled("Implementation pending"))
	func dispatchRunnerRejectsNonpositiveWorkerCount() throws {
		Issue.record("Not implemented")
	}
}
