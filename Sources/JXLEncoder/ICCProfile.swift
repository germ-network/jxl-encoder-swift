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
	/// to its first tag-table entry (skcms.cc:1339-1352). The intent rule is stricter than jxl_cms.cc:1007-1032, which also
	/// tolerates little-endian; the family restriction declines v2, non-'mntr',
	/// Lab-PCS, LUT and cicp profiles that libjxl accepts.
	init(validating bytes: [UInt8]) throws(Rejection) {
		fatalError("unimplemented")
	}
}
