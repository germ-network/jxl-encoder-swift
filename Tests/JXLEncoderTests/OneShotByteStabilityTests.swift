import Foundation
import Testing

@testable import JXLEncoder

/// Frames libjxl encodes in one shot, and every JPEG transcode, must keep their
/// exact bytes while streaming frames change how they are coded.
@Suite("One-shot byte stability")
struct OneShotByteStabilityTests {
	@Test("frames at or below eight groups keep their bytes")
	func eightGroupFrameBytesAreUnchanged() throws {
		let image = try ConcurrentEncodeTests.image(width: 600, height: 400)
		#expect(ImageDim(width: 600, height: 400).groupCount <= 8)
		let bytes = try Encoder.encode(image, distance: 1.0)
		#expect(Self.sha256Hex(bytes) == Self.eightGroup)
	}

	@Test("a resampled frame coded above eight groups keeps its bytes")
	func resampledFrameAboveEightGroupsBytesAreUnchanged() throws {
		let image = try ConcurrentEncodeTests.image(width: 4608, height: 512)
		let coded = ImageDim(width: 2304, height: 256)
		#expect(coded.groupCount > 8)
		let bytes = try Encoder.encode(image, distance: 10)
		#expect(Self.sha256Hex(bytes) == Self.resampled)
	}

	@Test(
		"colour and grayscale JPEG transcodes keep their bytes",
		arguments: [true, false])
	func jpegTranscodeBytesAreUnchanged(optimizeCodes: Bool) throws {
		var digests: [String] = []
		for name in ["hopper_420_odd", "hopper_gray_odd"] {
			let transcode = try JPEGTranscode(
				JPEGParser.parse(JPEGParserTests.fixture(name)))
			digests.append(
				Self.sha256Hex(
					try Encoder.encodeJPEG(
						transcode, optimizeCodes: optimizeCodes)))
		}
		#expect(digests == Self.jpeg[optimizeCodes ? 0 : 1])
	}

	// Digests recorded at main 3a9f046.
	static let eightGroup =
		"18d74158f2b098a20cc7929551065e9b36a07e5d926a85dc8b8ece69fe349195"
	static let resampled =
		"87b488282ac93bdb5e63688635df2229d94fecfda16bf56a62f7e80d71711090"
	static let jpeg = [
		[
			"1cf68cb275214f9dc083084d6447539878ed89447640a5f1e823bb84301756b2",
			"0cd0a6e9df7d3d5341a8bb312f0c06571109c31582fb2dba69f66e26aa2b4b86",
		],
		[
			"421a2bbb4dee4b560cfa2804938a42be1d4a181779dbf6f63f6fa22c97191620",
			"3791b329dbab2d992db522e15333783682b429a546833455d0c6c2fdf6328848",
		],
	]

	static func sha256Hex(_ bytes: [UInt8]) -> String {
		SHA256Digest.hash(bytes).map { String(format: "%02x", $0) }.joined()
	}
}

/// Self-contained SHA-256, so the digests check on every platform the package
/// builds for.
enum SHA256Digest {
	private static let k: [UInt32] = [
		0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b,
		0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5, 0xd807_aa98, 0x1283_5b01,
		0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7,
		0xc19b_f174, 0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc,
		0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da, 0x983e_5152,
		0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147,
		0x06ca_6351, 0x1429_2967, 0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc,
		0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
		0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3, 0xd192_e819,
		0xd699_0624, 0xf40e_3585, 0x106a_a070, 0x19a4_c116, 0x1e37_6c08,
		0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f,
		0x682e_6ff3, 0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208,
		0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
	]

	static func hash(_ message: [UInt8]) -> [UInt8] {
		var h: [UInt32] = [
			0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
			0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
		]
		var data = message
		data.append(0x80)
		while data.count % 64 != 56 { data.append(0) }
		let bitLength = UInt64(message.count) * 8
		for shift in stride(from: 56, through: 0, by: -8) {
			data.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
		}
		func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
		var w = [UInt32](repeating: 0, count: 64)
		for chunk in stride(from: 0, to: data.count, by: 64) {
			for i in 0..<16 {
				let j = chunk + i * 4
				w[i] =
					UInt32(data[j]) << 24 | UInt32(data[j + 1]) << 16
					| UInt32(data[j + 2]) << 8 | UInt32(data[j + 3])
			}
			for i in 16..<64 {
				let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
				let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
				w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
			}
			var v = h
			for i in 0..<64 {
				let s1 = rotr(v[4], 6) ^ rotr(v[4], 11) ^ rotr(v[4], 25)
				let ch = (v[4] & v[5]) ^ (~v[4] & v[6])
				let t1 = v[7] &+ s1 &+ ch &+ k[i] &+ w[i]
				let s0 = rotr(v[0], 2) ^ rotr(v[0], 13) ^ rotr(v[0], 22)
				let maj = (v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2])
				let t2 = s0 &+ maj
				v = [t1 &+ t2, v[0], v[1], v[2], v[3] &+ t1, v[4], v[5], v[6]]
			}
			for i in 0..<8 { h[i] = h[i] &+ v[i] }
		}
		return h.flatMap { word in
			[24, 16, 8, 0].map { UInt8(truncatingIfNeeded: word >> UInt32($0)) }
		}
	}
}
