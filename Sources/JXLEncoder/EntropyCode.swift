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
	/// Set when this code re-clusters an earlier one's buckets. The decoder
	/// needs a map over the original context space, so the two compose when the
	/// context map is written out.
	public let originalContextMap: [UInt8]?

	public init(
		contextMap: [UInt8], prefixCodes: [PrefixCode],
		originalContextMap: [UInt8]? = nil
	) {
		self.contextMap = contextMap
		self.prefixCodes = prefixCodes
		self.originalContextMap = originalContextMap
	}

	public var contextCount: Int { contextMap.count }
	public var prefixCodeCount: Int { prefixCodes.count }
	/// Contexts the decoder sees, which is the original space when this code
	/// was built by re-clustering.
	public var transmittedContextCount: Int {
		originalContextMap?.count ?? contextMap.count
	}

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
