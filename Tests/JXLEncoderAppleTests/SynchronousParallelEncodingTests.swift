#if canImport(ImageIO)
	import Testing

	@testable import JXLEncoderApple

	@Suite("Synchronous parallel Apple encoding")
	struct SynchronousParallelEncodingTests {
		@Test(.disabled("Implementation pending"))
		func parallelImageEncodingMatchesSerial() throws { Issue.record("Not implemented") }

		@Test(.disabled("Implementation pending"))
		func parallelDataEncodingPreservesDecodePolicies() throws {
			Issue.record("Not implemented")
		}

		@Test(.disabled("Implementation pending"))
		func eligibleJPEGRemainsSerialAndCoefficientPreserving() throws {
			Issue.record("Not implemented")
		}

		@Test(.disabled("Implementation pending"))
		func parallelEntryPointsRejectInvalidRunnerBeforeInputWork() throws {
			Issue.record("Not implemented")
		}
	}
#endif
