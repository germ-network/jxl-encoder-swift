import Testing

@testable import JXLEncoder

/// The admitted family is v4 'mntr' RGB with an XYZ connection space, matrix
/// colorants and 'para' TRCs that skcms and libjxl's CMS both accept;
/// everything else declines with a named reason.
@Suite("ICCProfile")
struct ICCProfileTests {
	@Test(
		"the committed Display P3 profile is admitted",
		.disabled("pending implementation"))
	func displayP3Accepted() {}

	@Test(
		"'para' TRC types 0 through 4 are admitted",
		.disabled("pending implementation"))
	func paraTypesZeroThroughFourAccepted() {}

	@Test(
		"'para' type 5 is rejected as an unsupported parametric type",
		.disabled("pending implementation"))
	func paraTypeFiveRejected() {}

	@Test(
		"a 'para' tag shorter than its type's parameters is rejected",
		.disabled("pending implementation"))
	func truncatedParaRejected() {}

	@Test(
		"a 'para' type 1 or 2 with zero slope is rejected",
		.disabled("pending implementation"))
	func paraZeroSlopeRejected() {}

	@Test(
		"a 'para' function skcms does not call sRGB-ish is rejected",
		.disabled("pending implementation"))
	func nonSRGBishParaRejected() {}

	@Test(
		"a sampled 'curv' TRC is rejected as an unsupported curve type",
		.disabled("pending implementation"))
	func sampledCurveRejected() {}

	@Test(
		"a version 2 profile is rejected",
		.disabled("pending implementation"))
	func version2Rejected() {}

	@Test(
		"a device class other than 'mntr' is rejected",
		.disabled("pending implementation"))
	func nonDisplayClassRejected() {}

	@Test(
		"a gray data colour space is rejected",
		.disabled("pending implementation"))
	func grayColorSpaceRejected() {}

	@Test(
		"a Lab connection space is rejected",
		.disabled("pending implementation"))
	func labPCSRejected() {}

	@Test(
		"an illuminant more than 0.01 from D50 is rejected",
		.disabled("pending implementation"))
	func nonD50IlluminantRejected() {}

	@Test(
		"a missing r/g/bXYZ colorant is rejected naming the tag",
		.disabled("pending implementation"))
	func missingColorantRejected() {}

	@Test(
		"a colorant that is not an 'XYZ ' of at least 20 bytes is rejected",
		.disabled("pending implementation"))
	func malformedColorantRejected() {}

	@Test(
		"a missing r/g/bTRC is rejected naming the tag",
		.disabled("pending implementation"))
	func missingTRCRejected() {}

	@Test(
		"a missing 'wtpt' tag is rejected",
		.disabled("pending implementation"))
	func missingWhitePointRejected() {}

	@Test(
		"a non-'sf32' or short 'chad' is treated as absent",
		.disabled("pending implementation"))
	func malformedChadTreatedAsAbsent() {}

	@Test(
		"a non-invertible 'chad' matrix is rejected",
		.disabled("pending implementation"))
	func singularChadRejected() {}

	@Test(
		"a white point with zero x or y is rejected",
		.disabled("pending implementation"))
	func degenerateWhitePointRejected() {}

	@Test(
		"a primary with zero x or y is rejected",
		.disabled("pending implementation"))
	func degeneratePrimariesRejected() {}

	@Test(
		"TRCs that are 0 at 1 give NaN primaries and are rejected",
		.disabled("pending implementation"))
	func zeroTRCAtOnePrimariesRejected() {}

	@Test(
		"a white point outside libjxl's custom xy range is rejected",
		.disabled("pending implementation"))
	func outOfRangeWhitePointRejected() {}

	@Test(
		"an A2B0, A2B1, B2A0 or B2A1 tag is rejected",
		.disabled("pending implementation"))
	func lutProfileRejected() {}

	@Test(
		"a cicp tag is rejected",
		.disabled("pending implementation"))
	func cicpTagRejected() {}

	@Test(
		"big-endian intents 0 through 3 are admitted",
		.disabled("pending implementation"))
	func bigEndianIntentsAccepted() {}

	@Test(
		"an intent valid only when read little-endian is rejected",
		.disabled("pending implementation"))
	func byteReversedIntentRejected() {}

	@Test(
		"a tag running past the profile end is rejected",
		.disabled("pending implementation"))
	func tagOutOfBoundsRejected() {}

	@Test(
		"a tag smaller than 4 bytes is rejected",
		.disabled("pending implementation"))
	func tagSmallerThanFourBytesRejected() {}

	@Test(
		"a profile shorter than its 132-byte header and tag count is rejected",
		.disabled("pending implementation"))
	func truncatedHeaderRejected() {}

	@Test(
		"a declared size beyond the byte count is rejected",
		.disabled("pending implementation"))
	func declaredSizeBeyondDataRejected() {}

	@Test(
		"bytes after the declared size are accepted",
		.disabled("pending implementation"))
	func trailingBytesAccepted() {}

	@Test(
		"a profile without the 'acsp' signature is rejected",
		.disabled("pending implementation"))
	func missingAcspSignatureRejected() {}
}
