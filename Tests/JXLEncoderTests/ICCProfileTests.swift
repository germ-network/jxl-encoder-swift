import Testing

@testable import JXLEncoder

/// The admitted family is v4 'mntr' RGB with an XYZ connection space, matrix
/// colorants and 'para' TRCs that skcms and libjxl's CMS both accept;
/// everything else declines with a named reason.
@Suite("ICCProfile")
struct ICCProfileTests {
	/// Lays out an ICC profile from a header and tag list. The default is the
	/// committed Display P3 profile's header and colour tags, so each test
	/// changes one property of an admitted profile.
	struct Builder {
		var header: [UInt8]
		var tags: [(signature: String, data: [UInt8])]

		init() {
			let srgb = Self.rawPara(3, [0x2_6666, 0xF2A7, 0x0D59, 0x13D0, 0x0A5B])
			tags = [
				("wtpt", Self.rawXYZ(0xF6D5, 0x1_0000, 0xD32C)),
				("rXYZ", Self.rawXYZ(0x83DF, 0x3DBF, -0x45)),
				("gXYZ", Self.rawXYZ(0x4ABF, 0xB137, 0x0AB9)),
				("bXYZ", Self.rawXYZ(0x2838, 0x110B, 0xC8B9)),
				("rTRC", srgb), ("gTRC", srgb), ("bTRC", srgb),
				(
					"chad",
					Self.sf32([
						0x1_0C42, 0x05DE, -0x0CDA, 0x0793, 0xFD90, -0x045E,
						-0x025D, 0x03DC,
						0xC06E,
					])
				),
			]
			header = [UInt8](repeating: 0, count: 128)
			setHeader(8, [4, 0x40, 0, 0])
			setHeader(12, Self.ascii("mntr") + Self.ascii("RGB ") + Self.ascii("XYZ "))
			setHeader(36, Self.ascii("acsp"))
			setHeader(68, Self.rawXYZ(0xF6D6, 0x1_0000, 0xD32D).suffix(12))
		}

		var bytes: [UInt8] {
			let tableEnd = 132 + 12 * tags.count
			var table: [UInt8] = Self.be32(UInt32(tags.count))
			var data: [UInt8] = []
			for tag in tags {
				table +=
					Self.ascii(tag.signature)
					+ Self.be32(UInt32(tableEnd + data.count))
					+ Self.be32(UInt32(tag.data.count))
				data += tag.data
			}
			var bytes: [UInt8] = Self.be32(UInt32(tableEnd + data.count))
			bytes += header.dropFirst(4)
			bytes += table
			bytes += data
			return bytes
		}

		mutating func setHeader(_ offset: Int, _ value: some Collection<UInt8>) {
			header.replaceSubrange(offset..<offset + value.count, with: value)
		}

		mutating func setTag(_ signature: String, _ data: [UInt8]) {
			removeTag(signature)
			tags.append((signature, data))
		}

		mutating func removeTag(_ signature: String) {
			tags.removeAll { $0.signature == signature }
		}

		mutating func setTRCs(_ data: [UInt8]) {
			for signature in ["rTRC", "gTRC", "bTRC"] { setTag(signature, data) }
		}

		static func ascii(_ text: String) -> [UInt8] { Array(text.utf8) }

		static func be32(_ value: UInt32) -> [UInt8] {
			[24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
		}

		static func rawFixed(_ values: [Int32]) -> [UInt8] {
			values.flatMap { be32(UInt32(bitPattern: $0)) }
		}

		static func fixed(_ values: [Double]) -> [UInt8] {
			rawFixed(values.map { Int32(($0 * 65536).rounded()) })
		}

		static func rawXYZ(_ x: Int32, _ y: Int32, _ z: Int32) -> [UInt8] {
			ascii("XYZ ") + [0, 0, 0, 0] + rawFixed([x, y, z])
		}

		static func xyz(_ x: Double, _ y: Double, _ z: Double) -> [UInt8] {
			ascii("XYZ ") + [0, 0, 0, 0] + fixed([x, y, z])
		}

		static func rawPara(_ type: UInt8, _ parameters: [Int32]) -> [UInt8] {
			ascii("para") + [0, 0, 0, 0, 0, type, 0, 0] + rawFixed(parameters)
		}

		static func para(_ type: UInt8, _ parameters: [Double]) -> [UInt8] {
			rawPara(type, parameters.map { Int32(($0 * 65536).rounded()) })
		}

		static func sf32(_ values: [Int32]) -> [UInt8] {
			ascii("sf32") + [0, 0, 0, 0] + rawFixed(values)
		}

		static let identityCHAD = sf32([0x1_0000, 0, 0, 0, 0x1_0000, 0, 0, 0, 0x1_0000])
	}

	static func signature(_ text: String) -> UInt32 {
		text.utf8.reduce(0) { $0 << 8 | UInt32($1) }
	}

	static func expectAccepted(
		_ bytes: [UInt8], sourceLocation: SourceLocation = #_sourceLocation
	) {
		#expect(
			(try? ICCProfile(validating: bytes))?.bytes == bytes,
			sourceLocation: sourceLocation)
	}

	static func expectRejected(
		_ bytes: [UInt8], _ rejection: ICCProfile.Rejection,
		sourceLocation: SourceLocation = #_sourceLocation
	) {
		#expect(throws: rejection, sourceLocation: sourceLocation) {
			try ICCProfile(validating: bytes)
		}
	}

	/// A builder with an identity 'chad', so its unadapted white point and
	/// primaries are exactly its 'wtpt' and colorant chromaticities.
	static func identityAdapted() -> Builder {
		var profile = Builder()
		profile.setTag("chad", Builder.identityCHAD)
		expectAccepted(profile.bytes)
		return profile
	}

	@Test("the committed Display P3 profile is admitted")
	func displayP3Accepted() throws {
		let embedded = try #require(
			try JPEGParser.parse(JPEGParserTests.fixture("display_p3_profile"))
				.iccProfile)
		Self.expectAccepted(embedded)
		Self.expectAccepted(Builder().bytes)
	}

	@Test("'para' TRC types 0 through 4 are admitted")
	func paraTypesZeroThroughFourAccepted() {
		let curves: [(UInt8, [Double])] = [
			(0, [2.2]), (1, [2.2, 1, 0]), (2, [2.2, 1, 0, 0]),
			(3, [2.4, 0.9479, 0.0521, 0.0774, 0.0405]),
			(4, [2.4, 0.9479, 0.0521, 0.0774, 0.0405, 0, 0]),
		]
		for (type, parameters) in curves {
			var profile = Builder()
			profile.setTRCs(Builder.para(type, parameters))
			Self.expectAccepted(profile.bytes)
		}
	}

	@Test("'para' type 5 is rejected as an unsupported parametric type")
	func paraTypeFiveRejected() {
		var profile = Builder()
		profile.setTag("gTRC", Builder.para(5, [2.4, 1, 0, 0, 0, 0, 0]))
		Self.expectRejected(profile.bytes, .unsupportedParametricType)
	}

	@Test("a 'para' tag shorter than its type's parameters is rejected")
	func truncatedParaRejected() {
		var profile = Builder()
		profile.setTag("rTRC", Builder.para(3, [2.4, 0.9479, 0.0521, 0.0774]))
		Self.expectRejected(profile.bytes, .truncatedParametricCurve)
	}

	@Test("a 'para' type 1 or 2 with zero slope is rejected")
	func paraZeroSlopeRejected() {
		for curve in [Builder.para(1, [2.2, 0, 0]), Builder.para(2, [2.2, 0, 0, 0])] {
			var profile = Builder()
			profile.setTag("bTRC", curve)
			Self.expectRejected(profile.bytes, .invalidParametricCurve)
		}
	}

	@Test("a 'para' function skcms does not call sRGB-ish is rejected")
	func nonSRGBishParaRejected() {
		let curves = [
			Builder.para(0, [-2.2]),
			Builder.para(3, [2.4, -1, 0, 0, 0]),
			Builder.para(3, [2.4, 1, 0, -1, 0]),
			Builder.para(3, [2.4, 1, 1, 0, -0.5]),
			Builder.para(3, [2.4, 1, -0.5, 1, 0.25]),
		]
		for curve in curves {
			var profile = Builder()
			profile.setTag("rTRC", curve)
			Self.expectRejected(profile.bytes, .invalidParametricCurve)
		}
	}

	@Test("a sampled 'curv' TRC is rejected as an unsupported curve type")
	func sampledCurveRejected() {
		var profile = Builder()
		profile.setTag(
			"gTRC", Builder.ascii("curv") + [0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0xFF, 0xFF])
		Self.expectRejected(profile.bytes, .unsupportedCurveType)
	}

	@Test("a version 2 profile is rejected")
	func version2Rejected() {
		var profile = Builder()
		profile.setHeader(8, [2, 0x10, 0, 0])
		Self.expectRejected(profile.bytes, .unsupportedVersion)
	}

	@Test("a device class other than 'mntr' is rejected")
	func nonDisplayClassRejected() {
		var profile = Builder()
		profile.setHeader(12, Builder.ascii("scnr"))
		Self.expectRejected(profile.bytes, .unsupportedDeviceClass)
	}

	@Test("a gray data colour space is rejected")
	func grayColorSpaceRejected() {
		var profile = Builder()
		profile.setHeader(16, Builder.ascii("GRAY"))
		Self.expectRejected(profile.bytes, .unsupportedColorSpace)
	}

	@Test("a Lab connection space is rejected")
	func labPCSRejected() {
		var profile = Builder()
		profile.setHeader(20, Builder.ascii("Lab "))
		Self.expectRejected(profile.bytes, .unsupportedConnectionSpace)
	}

	@Test("an illuminant more than 0.01 from D50 is rejected")
	func nonD50IlluminantRejected() {
		for (offset, value) in [(68, 0.9505), (72, 1.02), (76, 0.84)] {
			var profile = Builder()
			profile.setHeader(offset, Builder.fixed([value]))
			Self.expectRejected(profile.bytes, .nonD50Illuminant)
		}
	}

	@Test("a missing r/g/bXYZ colorant is rejected naming the tag")
	func missingColorantRejected() {
		var profile = Builder()
		profile.removeTag("gXYZ")
		Self.expectRejected(profile.bytes, .missingTag(signature: Self.signature("gXYZ")))
	}

	@Test("a colorant that is not an 'XYZ ' of at least 20 bytes is rejected")
	func malformedColorantRejected() {
		let colorant = Builder.rawXYZ(0x83DF, 0x3DBF, -0x45)
		let malformed = [
			Array(colorant.prefix(16)),
			Builder.ascii("sf32") + colorant.dropFirst(4),
		]
		for data in malformed {
			var profile = Builder()
			profile.setTag("rXYZ", data)
			Self.expectRejected(
				profile.bytes, .malformedTag(signature: Self.signature("rXYZ")))
		}
	}

	@Test("a missing r/g/bTRC is rejected naming the tag")
	func missingTRCRejected() {
		var profile = Builder()
		profile.removeTag("bTRC")
		Self.expectRejected(profile.bytes, .missingTag(signature: Self.signature("bTRC")))
	}

	@Test("a missing 'wtpt' tag is rejected")
	func missingWhitePointRejected() {
		var profile = Builder()
		profile.removeTag("wtpt")
		Self.expectRejected(profile.bytes, .missingTag(signature: Self.signature("wtpt")))
	}

	@Test("a non-'sf32' or short 'chad' is treated as absent")
	func malformedChadTreatedAsAbsent() {
		let singular = Builder.sf32(Array(repeating: 0, count: 9))
		var profile = Builder()
		profile.setTag("chad", singular)
		Self.expectRejected(profile.bytes, .singularAdaptationMatrix)
		for malformed in [
			Builder.ascii("XYZ ") + singular.dropFirst(4), Array(singular.prefix(40)),
		] {
			profile.setTag("chad", malformed)
			Self.expectAccepted(profile.bytes)
		}
	}

	@Test("a non-invertible 'chad' matrix is rejected")
	func singularChadRejected() {
		var profile = Builder()
		profile.setTag(
			"chad", Builder.sf32([0x1_0000, 0, 0, 0x1_0000, 0, 0, 0, 0, 0x1_0000]))
		Self.expectRejected(profile.bytes, .singularAdaptationMatrix)
	}

	@Test("a white point with zero x or y is rejected")
	func degenerateWhitePointRejected() {
		for white in [Builder.xyz(0, 1, 0.8249), Builder.xyz(0.9642, 0, 0.8249)] {
			var profile = Self.identityAdapted()
			profile.setTag("wtpt", white)
			Self.expectRejected(profile.bytes, .degenerateWhitePoint)
		}
	}

	@Test("a primary with zero x or y is rejected")
	func degeneratePrimariesRejected() {
		for colorant in [Builder.xyz(0, 0.5, 0.1), Builder.xyz(0.5, 0, 0.1)] {
			var profile = Self.identityAdapted()
			profile.setTag("gXYZ", colorant)
			Self.expectRejected(profile.bytes, .degeneratePrimaries)
		}
	}

	@Test("TRCs that are 0 at 1 give NaN primaries and are rejected")
	func zeroTRCAtOnePrimariesRejected() {
		var profile = Builder()
		profile.setTRCs(Builder.para(3, [1, 1, 0, 0, 1.5]))
		Self.expectRejected(profile.bytes, .degeneratePrimaries)
	}

	@Test("a white point outside libjxl's custom xy range is rejected")
	func outOfRangeWhitePointRejected() {
		// x = 2.5 and x = 4.5 both exceed the 21-bit range; 4.5 also fails the
		// rough limit of 4.
		for white in [Builder.xyz(5, 1, -4), Builder.xyz(9, 1, -8)] {
			var profile = Self.identityAdapted()
			profile.setTag("wtpt", white)
			Self.expectRejected(profile.bytes, .degenerateWhitePoint)
		}
	}

	@Test("an A2B0, A2B1, B2A0 or B2A1 tag is rejected")
	func lutProfileRejected() {
		for signature in ["A2B0", "A2B1", "B2A0", "B2A1"] {
			var profile = Builder()
			profile.setTag(
				signature, Builder.ascii("mAB ") + [UInt8](repeating: 0, count: 28))
			Self.expectRejected(profile.bytes, .lutTagPresent)
		}
	}

	@Test("A2B2 and B2A2 tags, which skcms never reads, are admitted")
	func unreadLUTTagsAccepted() {
		for signature in ["A2B2", "B2A2"] {
			var profile = Builder()
			profile.setTag(
				signature, Builder.ascii("mAB ") + [UInt8](repeating: 0, count: 28))
			Self.expectAccepted(profile.bytes)
		}
	}

	@Test("a repeated signature resolves to its first tag-table entry")
	func duplicateTagFirstEntryWins() {
		let curve = Builder.ascii("curv") + [0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0xFF, 0xFF]
		var profile = Builder()
		profile.tags.append(("rTRC", curve))
		Self.expectAccepted(profile.bytes)
		profile.tags.insert(("rTRC", curve), at: 0)
		Self.expectRejected(profile.bytes, .unsupportedCurveType)
	}

	@Test("each primary includes the other channels' TRC at 0")
	func trcAtZeroContributesToPrimaries() {
		var profile = Self.identityAdapted()
		profile.setTag("rXYZ", Builder.xyz(0, 0.5, 0.1))
		Self.expectRejected(profile.bytes, .degeneratePrimaries)
		profile.setTRCs(Builder.para(4, [1, 1, 0, 0, 2, 0, 0.5]))
		Self.expectAccepted(profile.bytes)
	}

	@Test("without 'chad', primaries are adapted by Bradford from the white point")
	func bradfordAdaptsPrimariesWithoutChad() {
		var profile = Self.identityAdapted()
		profile.setTag("wtpt", Builder.xyz(0.9642, 1, -0.025))
		Self.expectAccepted(profile.bytes)
		profile.removeTag("chad")
		Self.expectRejected(profile.bytes, .degeneratePrimaries)
	}

	@Test("a cicp tag is rejected")
	func cicpTagRejected() {
		var profile = Builder()
		profile.setTag("cicp", Builder.ascii("cicp") + [0, 0, 0, 0, 1, 13, 0, 1])
		Self.expectRejected(profile.bytes, .cicpTagPresent)
	}

	@Test("big-endian intents 0 through 3 are admitted")
	func bigEndianIntentsAccepted() {
		for intent: UInt8 in 0...3 {
			var profile = Builder()
			profile.setHeader(64, [0, 0, 0, intent])
			Self.expectAccepted(profile.bytes)
		}
	}

	@Test("an intent valid only when read little-endian is rejected")
	func byteReversedIntentRejected() {
		var profile = Builder()
		profile.setHeader(64, [1, 0, 0, 0])
		Self.expectRejected(profile.bytes, .unsupportedRenderingIntent)
	}

	@Test("a big-endian intent of 4 is rejected")
	func intentFourRejected() {
		var profile = Builder()
		profile.setHeader(64, [0, 0, 0, 4])
		Self.expectRejected(profile.bytes, .unsupportedRenderingIntent)
	}

	@Test("a tag running past the profile end is rejected")
	func tagOutOfBoundsRejected() {
		var bytes = Builder().bytes
		let lastSize = 132 + 12 * 7 + 8
		bytes[lastSize + 3] += 1
		Self.expectRejected(bytes, .invalidTagExtent)
		Self.expectRejected(bytes + [0, 0, 0, 0], .invalidTagExtent)
	}

	@Test("a tag smaller than 4 bytes is rejected")
	func tagSmallerThanFourBytesRejected() {
		var bytes = Builder().bytes
		bytes.replaceSubrange(132 + 8..<132 + 12, with: [0, 0, 0, 3])
		Self.expectRejected(bytes, .invalidTagExtent)
	}

	@Test("a profile shorter than its 132-byte header and tag count is rejected")
	func truncatedHeaderRejected() {
		Self.expectRejected(Array(Builder().bytes.prefix(131)), .truncatedHeader)
	}

	@Test("a declared size beyond the byte count is rejected")
	func declaredSizeBeyondDataRejected() {
		Self.expectRejected(Array(Builder().bytes.dropLast()), .invalidDeclaredSize)
	}

	@Test("a tag table larger than the declared size is rejected despite trailing bytes")
	func tagCountBeyondDeclaredSizeRejected() {
		var bytes = Builder().bytes + [UInt8](repeating: 0, count: 1024)
		bytes.replaceSubrange(128..<132, with: Builder.be32(40))
		Self.expectRejected(bytes, .invalidDeclaredSize)
	}

	@Test("bytes after the declared size are accepted")
	func trailingBytesAccepted() {
		Self.expectAccepted(Builder().bytes + [0, 0, 0, 0])
	}

	@Test("a profile without the 'acsp' signature is rejected")
	func missingAcspSignatureRejected() {
		var profile = Builder()
		profile.setHeader(36, Builder.ascii("ascp"))
		Self.expectRejected(profile.bytes, .badSignature)
	}
}
