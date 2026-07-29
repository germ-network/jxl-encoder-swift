//
//  EntropyCode.swift
//  JXLEncoder
//
//  Port of libjxl-tiny's encoder/entropy_code.h and the token writer from
//  encoder/enc_entropy_code.h.
//
//  JPEG XL permits either ANS or prefix codes; libjxl-tiny uses prefix
//  (Huffman) codes exclusively, so no ANS coder appears in this port.
//

/// A context map plus the prefix codes it selects between.
public struct EntropyCode: Sendable {
	public let contextMap: [UInt8]
	public let prefixCodes: [PrefixCode]

	public init(contextMap: [UInt8], prefixCodes: [PrefixCode]) {
		self.contextMap = contextMap
		self.prefixCodes = prefixCodes
	}

	public var contextCount: Int { contextMap.count }
	public var prefixCodeCount: Int { prefixCodes.count }

	public static let staticDC = EntropyCode(
		contextMap: StaticEntropyCodes.dcContextMap,
		prefixCodes: StaticEntropyCodes.dcPrefixCodes)

	public static let staticAC = EntropyCode(
		contextMap: StaticEntropyCodes.acContextMap,
		prefixCodes: StaticEntropyCodes.acPrefixCodes)
}

extension BitWriter {
	/// Writes one token: the prefix code for its symbol, followed by the
	/// hybrid-uint extra bits packed above it in the same word.
	public mutating func write(token: Token, code: EntropyCode) {
		let (symbol, bitCount, bits) = UintCoder.encode(token.value)
		let prefix = code.prefixCodes[Int(code.contextMap[Int(token.context)])]
		let depth = prefix.depths[Int(symbol)]
		var data = UInt64(prefix.bits[Int(symbol)])
		data |= UInt64(bits) << UInt64(depth)
		write(Int(depth) + Int(bitCount), data)
	}
}
