import Testing

@testable import JXLEncoder

/// `StagedRecord`'s stride is load-bearing for encode memory: a frame stages
/// millions of them, and the enum's fat `rawBits` case sets the stride for the
/// far more numerous `token` case too. The `rawBits` payload is declared
/// `value: UInt64` before `count: UInt8` specifically so the case packs into
/// 16 bytes — with `count` first it silently widens back to 24, doubling the
/// per-record overhead with no compiler complaint. This pins the layout so
/// that regression fails here rather than as an unexplained memory bump.
@Suite("Staged record layout")
struct StagedRecordLayoutTests {
	@Test("StagedRecord stays 16 bytes")
	func stride() {
		#expect(MemoryLayout<StagedRecord>.stride == 16)
	}
}
