//
//  ICCProfile.swift
//  JXLEncoder
//
//  Admission of an embedded ICC profile into the coded-ICC header path. Ports
//  the checks of skcms `skcms_ParseWithA2BPriority` and `read_curve_para`
//  (third_party/skcms/skcms.cc) and of libjxl `JxlCmsSetFieldsFromICC`
//  (lib/jxl/cms/jxl_cms.cc) that a matrix/TRC profile can fail, restricted to
//  the display matrix/TRC family a coefficient transcode can carry without
//  inferring anything from it.
//

/// An embedded ICC profile that libjxl's encoder would accept and that lies in
/// the admitted display matrix/TRC family. Its bytes are nonempty and are
/// carried verbatim into the codestream.
public struct ICCProfile: Equatable, Sendable {
	/// The profile exactly as embedded in the source.
	public let bytes: [UInt8]

	/// Why a profile falls outside the admitted family. Every case declines
	/// coefficient recompression, so the caller decodes pixels instead.
	enum Rejection: Error, Equatable, Sendable {
		/// Shorter than the 132 bytes of header and tag count (skcms.cc:1362,
		/// 1369).
		case truncatedHeader
		/// The header's size field exceeds the byte count or cannot hold the
		/// header and tag table (skcms.cc:1388-1392). Trailing bytes beyond the
		/// declared size are accepted, as upstream does.
		case invalidDeclaredSize
		/// No 'acsp' file signature at byte 36.
		case badSignature
		/// Major version other than 4.
		case unsupportedVersion
		/// Device class other than 'mntr'.
		case unsupportedDeviceClass
		/// Data colour space other than 'RGB '.
		case unsupportedColorSpace
		/// Profile connection space other than 'XYZ '.
		case unsupportedConnectionSpace
		/// Header illuminant more than 0.01 from D50 in any component.
		case nonD50Illuminant
		/// Rendering intent outside 0...3 when read big-endian.
		case unsupportedRenderingIntent
		/// A tag smaller than 4 bytes or running past the profile
		/// (skcms.cc:1405-1412).
		case invalidTagExtent
		/// A required colorant, TRC or 'wtpt' tag is absent.
		case missingTag(signature: UInt32)
		/// A colorant or 'wtpt' tag that is not an 'XYZ ' of at least 20 bytes.
		/// A malformed 'chad' is not this case: like `skcms_GetCHAD`
		/// (skcms.cc:451-459) it counts as absent.
		case malformedTag(signature: UInt32)
		/// An A2B0, A2B1, B2A0 or B2A1 lookup table, which skcms would prefer
		/// over the matrix (skcms_public.h:278-285).
		case lutTagPresent
		/// A 'cicp' tag, which names an encoding this path does not signal.
		case cicpTagPresent
		/// A TRC that is not a 'para' curve.
		case unsupportedCurveType
		/// A 'para' function type above 4.
		case unsupportedParametricType
		/// A 'para' tag too short for its function type (skcms.cc:592-595).
		case truncatedParametricCurve
		/// A 'para' type 1 or 2 with zero slope, or a function skcms's
		/// `skcms_TransferFunction_isSRGBish` rejects: non-finite, negative
		/// a, c, d or g, or a·d + b < 0 (skcms.cc:135-190, 647).
		case invalidParametricCurve
		/// A well-formed 'chad' that `skcms_Matrix3x3_invert` rejects: zero
		/// determinant or a non-finite float reciprocal (skcms.cc:1930-1941,
		/// jxl_cms.cc:463-466).
		case singularAdaptationMatrix
		/// An unadapted white-point xy that `SetWhitePoint` rejects: zero,
		/// NaN, or outside `Customxy`'s range (|v| ≥ 4 or roundf(v·1e6) outside
		/// [-0x200000, 0x1FFFFF]) (color_encoding_cms.h:128-136, 466-470,
		/// 484); or, with no 'chad', |y| < 1e-12, which `CIEXYZFromWhiteCIExy`
		/// rejects (jxl_cms_internal.h:235-243).
		case degenerateWhitePoint
		/// A primary's unadapted xy that `SetPrimaries` rejects: zero, NaN (as
		/// from an all-zero XYZ, jxl_cms.cc:334-340) or outside `Customxy`'s
		/// range (color_encoding_cms.h:128-136, 399-406, 429-431).
		case degeneratePrimaries
	}

	/// Admits exactly ICC v4 'mntr' RGB profiles with an XYZ connection space,
	/// 'XYZ ' r/g/bXYZ and 'wtpt' tags, 'para' r/g/bTRC of types 0–4 that
	/// skcms accepts, an invertible 'chad' when a well-formed one is present,
	/// a D50 illuminant, a big-endian intent 0–3, in-bounds tags of at least 4
	/// bytes, white-point and primary chromaticities libjxl can store, and no
	/// A2B0/A2B1/B2A0/B2A1/cicp tag. A signature that appears twice resolves
	/// to its first tag-table entry (skcms.cc:1339-1352). The intent rule is
	/// stricter than jxl_cms.cc:1007-1032, which also tolerates little-endian;
	/// the family restriction declines v2, non-'mntr', Lab-PCS, LUT and cicp
	/// profiles that libjxl accepts.
	init(validating bytes: [UInt8]) throws(Rejection) {
		let profile = bytes[...]
		guard bytes.count >= 132 else { throw .truncatedHeader }
		guard Self.be32(profile, 36) == Self.signature("acsp") else { throw .badSignature }
		let size = UInt64(Self.be32(profile, 0))
		let tagCount = UInt64(Self.be32(profile, 128))
		guard size <= bytes.count, size >= 132 + 12 * tagCount else {
			throw .invalidDeclaredSize
		}
		guard bytes[8] == 4 else { throw .unsupportedVersion }
		guard Self.be32(profile, 12) == Self.signature("mntr") else {
			throw .unsupportedDeviceClass
		}
		guard Self.be32(profile, 16) == Self.signature("RGB ") else {
			throw .unsupportedColorSpace
		}
		guard Self.be32(profile, 20) == Self.signature("XYZ ") else {
			throw .unsupportedConnectionSpace
		}
		let d50: [Float] = [0.9642, 1, 0.8249]
		for i in 0..<3 where abs(Self.fixed(profile, 68 + 4 * i) - d50[i]) > 0.01 {
			throw .nonD50Illuminant
		}
		guard Self.be32(profile, 64) <= 3 else { throw .unsupportedRenderingIntent }

		var tags: [UInt32: ArraySlice<UInt8>] = [:]
		for entry in stride(from: 132, to: 132 + 12 * Int(tagCount), by: 12) {
			let offset = UInt64(Self.be32(profile, entry + 4))
			let length = UInt64(Self.be32(profile, entry + 8))
			guard length >= 4, offset + length <= size else { throw .invalidTagExtent }
			let signature = Self.be32(profile, entry)
			if tags[signature] == nil {
				tags[signature] = bytes[Int(offset)..<Int(offset + length)]
			}
		}
		func tag(_ name: String) throws(Rejection) -> ArraySlice<UInt8> {
			guard let tag = tags[Self.signature(name)] else {
				throw .missingTag(signature: Self.signature(name))
			}
			return tag
		}
		func xyz(_ name: String) throws(Rejection) -> [Float] {
			let tag = try tag(name)
			guard tag.count >= 20, Self.be32(tag, 0) == Self.signature("XYZ ") else {
				throw .malformedTag(signature: Self.signature(name))
			}
			return (0..<3).map { Self.fixed(tag, 8 + 4 * $0) }
		}

		var colorants: [[Float]] = []
		var curves: [TransferFunction] = []
		for channel in ["r", "g", "b"] {
			colorants.append(try xyz(channel + "XYZ"))
			curves.append(try TransferFunction(try tag(channel + "TRC")))
		}
		for name in ["A2B0", "A2B1", "B2A0", "B2A1"] where tags[Self.signature(name)] != nil
		{
			throw .lutTagPresent
		}
		guard tags[Self.signature("cicp")] == nil else { throw .cicpTagPresent }

		let white = try xyz("wtpt")
		var inverseCHAD: [[Float]]?
		if let chad = tags[Self.signature("chad")], chad.count >= 44,
			Self.be32(chad, 0) == Self.signature("sf32")
		{
			let rows = (0..<3).map { r in
				(0..<3).map { Self.fixed(chad, 8 + 12 * r + 4 * $0) }
			}
			guard let inverse = Self.invert(rows) else {
				throw .singularAdaptationMatrix
			}
			inverseCHAD = inverse
		}
		let whitePoint = Self.chromaticity(
			inverseCHAD.map { Self.product($0, white) } ?? white)
		guard Self.isStorable(whitePoint) else { throw .degenerateWhitePoint }

		guard let toUnadapted = inverseCHAD ?? Self.bradford(toWhite: whitePoint) else {
			throw .degenerateWhitePoint
		}
		let toXYZ = (0..<3).map { r in colorants.map { $0[r] } }
		for primary in 0..<3 {
			let rgb = (0..<3).map { curves[$0]($0 == primary ? 1 : 0) }
			let xyz = Self.product(toUnadapted, Self.product(toXYZ, rgb))
			guard Self.isStorable(Self.chromaticity(xyz)) else {
				throw .degeneratePrimaries
			}
		}
		self.bytes = bytes
	}

	/// skcms_TransferFunction as `read_curve_para` fills it (skcms.cc:577-650).
	private struct TransferFunction {
		var g: Float, a: Float = 1, b: Float = 0, c: Float = 0, d: Float = 0, e: Float = 0,
			f: Float = 0

		init(_ tag: ArraySlice<UInt8>) throws(Rejection) {
			guard ICCProfile.be32(tag, 0) == ICCProfile.signature("para") else {
				throw .unsupportedCurveType
			}
			guard tag.count >= 12 else { throw .truncatedParametricCurve }
			let type = Int(tag[tag.startIndex + 8]) << 8 | Int(tag[tag.startIndex + 9])
			guard type <= 4 else { throw .unsupportedParametricType }
			let count = [1, 3, 4, 5, 7][type]
			guard tag.count >= 12 + 4 * count else { throw .truncatedParametricCurve }
			let p = (0..<count).map { ICCProfile.fixed(tag, 12 + 4 * $0) }
			g = p[0]
			if type == 1 || type == 2 {
				guard p[1] != 0 else { throw .invalidParametricCurve }
				(a, b, d) = (p[1], p[2], -p[2] / p[1])
				if type == 2 { (e, f) = (p[3], p[3]) }
			} else if type >= 3 {
				(a, b, c, d) = (p[1], p[2], p[3], p[4])
				if type == 4 { (e, f) = (p[5], p[6]) }
			}
			// skcms also requires a finite sum of the parameters, which s15.16
			// inputs always give (skcms.cc:179).
			guard a >= 0, c >= 0, d >= 0, g >= 0, a * d + b >= 0 else {
				throw .invalidParametricCurve
			}
		}

		/// `apply_tf` (skcms Transform_inl.h:301-312) for x >= 0.
		func callAsFunction(_ x: Float) -> Float {
			x < d ? c * x + f : Self.approximatePower(a * x + b, g) + e
		}

		/// skcms's `approx_pow` (Transform_inl.h:250-283), which skcms_Transform
		/// evaluates the curve with.
		private static func approximatePower(_ x: Float, _ y: Float) -> Float {
			guard x != 0, x != 1 else { return x }
			let bits = Int32(bitPattern: x.bitPattern)
			let m = Float(
				bitPattern: UInt32(bitPattern: bits) & 0x007F_FFFF | 0x3F00_0000)
			let log2 =
				Float(bits) * (1 / Float(1 << 23)) - 124.225514990 - 1.498030302 * m
				- 1.725879990 / (0.3520887068 + m)
			let p = log2 * y
			let fraction = p - p.rounded(.down)
			let exponentBits =
				Float(1 << 23)
				* (p + 121.274057500 - 1.490129070 * fraction + 27.728023300
					/ (4.84252568 - fraction))
			let clamped = min(max(exponentBits, 0), Float(0x7F80_0000))
			return Float(bitPattern: UInt32(bitPattern: Int32(clamped)))
		}
	}

	/// `skcms_Matrix3x3_invert` (skcms.cc:1912-1967), including its rejection
	/// of a zero determinant or a non-float reciprocal.
	private static func invert(_ m: [[Float]]) -> [[Float]]? {
		let (a00, a01, a02) = (Double(m[0][0]), Double(m[1][0]), Double(m[2][0]))
		let (a10, a11, a12) = (Double(m[0][1]), Double(m[1][1]), Double(m[2][1]))
		let (a20, a21, a22) = (Double(m[0][2]), Double(m[1][2]), Double(m[2][2]))
		let determinant =
			(a00 * a11 - a01 * a10) * a22 - (a00 * a12 - a02 * a10) * a21
			+ (a01 * a12 - a02 * a11) * a20
		guard determinant != 0 else { return nil }
		let invdet = 1 / determinant
		guard abs(invdet) <= Double(Float.greatestFiniteMagnitude) else { return nil }
		let b = [
			a00 * a11 - a01 * a10, a00 * a12 - a02 * a10, a01 * a12 - a02 * a11, a20,
			a21, a22,
		].map { $0 * invdet }
		let inverse = [
			[
				a11 * b[5] - a12 * b[4], a12 * b[3] - a10 * b[5],
				a10 * b[4] - a11 * b[3],
			],
			[
				a02 * b[4] - a01 * b[5], a00 * b[5] - a02 * b[3],
				a01 * b[3] - a00 * b[4],
			],
			[b[2], -b[1], b[0]],
		].map { $0.map(Float.init) }
		return inverse.joined().allSatisfy(\.isFinite) ? inverse : nil
	}

	/// The Bradford adaptation from D50 back to `white` that jxl_cms.cc:481-502
	/// uses when there is no 'chad', or nil where `CIEXYZFromWhiteCIExy`
	/// fails (jxl_cms_internal.h:235-243).
	private static func bradford(toWhite white: (x: Double, y: Double)) -> [[Float]]? {
		guard abs(white.y) >= 1e-12 else { return nil }
		let factor = Double(Float(1 / white.y))
		let whiteXYZ = [
			Float(white.x * factor), 1, Float((1 - white.x - white.y) * factor),
		]
		let lmsFromXYZ: [[Float]] = [
			[0.8951, 0.2664, -0.1614], [-0.7502, 1.7135, 0.0367],
			[0.0389, -0.0685, 1.0296],
		]
		let xyzFromLMS: [[Float]] = [
			[0.9869929, -0.1470543, 0.1599627], [0.4323053, 0.5183603, 0.0492912],
			[-0.0085287, 0.0400428, 0.9684867],
		]
		let d50 = product(lmsFromXYZ, [0.96420288, 1.0, 0.82490540])
		let whiteLMS = product(lmsFromXYZ, whiteXYZ)
		let scale = (0..<3).map { r in (0..<3).map { r == $0 ? whiteLMS[r] / d50[r] : 0 } }
		return concat(concat(xyzFromLMS, scale), lmsFromXYZ)
	}

	/// `MatrixProduct` (jxl_cms.cc:437-445), in its float arithmetic.
	private static func product(_ m: [[Float]], _ v: [Float]) -> [Float] {
		m.map { row in (0..<3).reduce(Float(0)) { $0 + row[$1] * v[$1] } }
	}

	private static func concat(_ a: [[Float]], _ b: [[Float]]) -> [[Float]] {
		let columns = (0..<3).map { c in b.map { $0[c] } }
		return a.map { row in product(columns, row) }
	}

	/// `CIExyFromXYZ` (jxl_cms.cc:334-340).
	private static func chromaticity(_ xyz: [Float]) -> (x: Double, y: Double) {
		let factor = 1 / Double(xyz[0] + xyz[1] + xyz[2])
		return (Double(xyz[0]) * factor, Double(xyz[1]) * factor)
	}

	/// Whether `SetWhitePoint`/`SetPrimaries` accept the chromaticity: nonzero,
	/// and storable as `Customxy` (color_encoding_cms.h:128-136). The named
	/// shortcuts they take first lie inside that range, so they change nothing.
	private static func isStorable(_ xy: (x: Double, y: Double)) -> Bool {
		let range: ClosedRange<Float> = -0x20_0000...0x1F_FFFF
		return [xy.x, xy.y].allSatisfy { (v: Double) -> Bool in
			guard v != 0, abs(v) < 4 else { return false }
			let scaled = Float(v * 1_000_000).rounded(.toNearestOrAwayFromZero)
			return range.contains(scaled)
		}
	}

	private static func be32(_ bytes: ArraySlice<UInt8>, _ offset: Int) -> UInt32 {
		bytes[bytes.startIndex + offset..<bytes.startIndex + offset + 4].reduce(0) {
			$0 << 8 | UInt32($1)
		}
	}

	private static func fixed(_ bytes: ArraySlice<UInt8>, _ offset: Int) -> Float {
		Float(Int32(bitPattern: be32(bytes, offset))) * (1 / 65536)
	}

	private static func signature(_ name: String) -> UInt32 {
		name.utf8.reduce(0) { $0 << 8 | UInt32($1) }
	}
}
