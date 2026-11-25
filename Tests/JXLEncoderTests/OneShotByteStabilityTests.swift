import Foundation
import Testing

@testable import JXLEncoder

/// Frames libjxl encodes in one shot, and every JPEG transcode, must keep their
/// exact bytes while streaming frames change how they are coded.
@Suite("One-shot byte stability")
struct OneShotByteStabilityTests {
	@Test(
		"frames at or below eight groups keep their bytes",
		.disabled("pending implementation"))
	func eightGroupFrameBytesAreUnchanged() throws {}

	@Test(
		"a resampled frame coded above eight groups keeps its bytes",
		.disabled("pending implementation"))
	func resampledFrameAboveEightGroupsBytesAreUnchanged() throws {}

	@Test(
		"colour and grayscale JPEG transcodes keep their bytes",
		.disabled("pending implementation"))
	func jpegTranscodeBytesAreUnchanged() throws {}
}
