import Foundation
import Testing

@Suite("Selected JPEG configuration")
struct SelectedJPEGConfigurationTests {
	@Test("selected JPEG reconstruction and box obligations remain inventoried", .disabled())
	func selectedJPEGObligationsRemainInventoried() throws {}

	@Test("selected JPEG source proof has pinned consumed provenance", .disabled())
	func selectedJPEGProofHasPinnedProvenance() throws {}

	@Test("JPEG source proof distinguishes pixel stripping and decoded meaning", .disabled())
	func selectedJPEGProofDistinguishesPixelPath() throws {}
}
