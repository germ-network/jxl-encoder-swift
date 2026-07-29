//
//  Token.swift
//  JXLEncoder
//
//  Port of libjxl-tiny's encoder/token.h and the signed packing from
//  encoder/common.h.
//

/// One integer to be entropy coded, tagged with the context that selects its
/// prefix code.
public struct Token: Equatable, Sendable {
	public let context: UInt32
	public let value: UInt32

	public init(context: UInt32, value: UInt32) {
		self.context = context
		self.value = value
	}
}

/// Splits a value into a small token plus raw extra bits.
///
/// Values below 16 are their own token with no extra bits. Above that, the
/// token encodes the magnitude and the top two mantissa bits, and the remainder
/// is written raw:
///
///     16 (10000) -> token 16, 2 extra bits '00'
///     17 (10001) -> token 16, 2 extra bits '01'
///     32 (100000) -> token 20, 3 extra bits '000'
///     65535 -> token 63, 13 extra bits
public enum UintCoder {
	public static func encode(_ value: UInt32) -> (
		token: UInt32, bitCount: UInt32, bits: UInt32
	) {
		if value < 16 {
			return (value, 0, 0)
		}
		let n = UInt32(31 - value.leadingZeroBitCount)
		let m = value - (1 << n)
		let token = (n << 2) + (m >> (n - 2))
		let bitCount = n - 2
		let bits = value & ((1 << bitCount) - 1)
		return (token, bitCount, bits)
	}
}

/// Zig-zag: non-negative X becomes 2X, negative -X becomes 2X - 1, so small
/// magnitudes of either sign stay small.
public func packSigned(_ value: Int32) -> UInt32 {
	(UInt32(bitPattern: value) << 1) ^ ((UInt32(bitPattern: ~value) >> 31) &- 1)
}
