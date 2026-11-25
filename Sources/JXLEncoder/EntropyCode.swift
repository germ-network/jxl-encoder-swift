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
	var uintConfigurations: [HybridUintConfiguration]? = nil
	var logAlphabetSize: Int = ANSConstants.logAlphaSize

	public let contextMap: [UInt8]
	public let prefixCodes: [PrefixCode]
	/// Set when this code re-clusters an earlier one's buckets. The decoder
	/// needs a map over the original context space, so the two compose when the
	/// context map is written out.
	public let originalContextMap: [UInt8]?
	/// Non-nil selects ANS over prefix coding — real libjxl's per-code
	/// `use_prefix_code` bit. `prefixCodes` still holds a valid, unused
	/// prefix encoding in this case; only `EntropyCodeWriter`/`SectionWriter`
	/// read this field to decide which one actually gets serialized.
	public let ansInfoTables: [[ANSEncSymbolInfo]]?
	private(set) var ansHistograms: [ANSEncodingHistogram]? = nil

	public init(
		contextMap: [UInt8], prefixCodes: [PrefixCode],
		originalContextMap: [UInt8]? = nil,
		ansInfoTables: [[ANSEncSymbolInfo]]? = nil
	) {
		self.init(
			contextMap: contextMap, prefixCodes: prefixCodes,
			originalContextMap: originalContextMap, ansInfoTables: ansInfoTables,
			uintConfigurations: nil, logAlphabetSize: ANSConstants.logAlphaSize)
	}

	init(
		contextMap: [UInt8], prefixCodes: [PrefixCode],
		originalContextMap: [UInt8]? = nil,
		ansInfoTables: [[ANSEncSymbolInfo]]? = nil,
		uintConfigurations: [HybridUintConfiguration]?, logAlphabetSize: Int
	) {
		self.contextMap = contextMap
		self.prefixCodes = prefixCodes
		self.originalContextMap = originalContextMap
		self.ansInfoTables = ansInfoTables
		self.uintConfigurations = uintConfigurations
		self.logAlphabetSize = logAlphabetSize
	}

	init(
		contextMap: [UInt8], prefixCodes: [PrefixCode],
		originalContextMap: [UInt8]? = nil, ansHistograms: [ANSEncodingHistogram],
		uintConfigurations: [HybridUintConfiguration]? = nil,
		logAlphabetSize: Int = ANSConstants.logAlphaSize
	) {
		precondition(!ansHistograms.isEmpty)
		self.contextMap = contextMap
		self.prefixCodes = prefixCodes
		self.originalContextMap = originalContextMap
		self.ansHistograms = ansHistograms
		self.uintConfigurations = uintConfigurations
		self.logAlphabetSize = logAlphabetSize
		self.ansInfoTables = ansHistograms.map { histogram in
			ANSInfoTable.build(
				distribution: histogram.normalizedCounts,
				alphabetSize: histogram.alphabetSize,
				logAlphaSize: logAlphabetSize)
		}
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

	/// The stream's LZ77 header; nil writes `enabled = 0` (dec_ans.cc:304-315).
	var lz77: LZ77.Parameters? = nil
}

extension BitWriter {
	/// Writes one token: the prefix code for its symbol, followed by the
	/// hybrid-uint extra bits packed above it in the same word.
	public mutating func write(token: Token, code: EntropyCode) {
		precondition(
			code.ansInfoTables == nil,
			"an ANS-carrying code must be written via flushANS, not this prefix path")
		let (symbol, bitCount, bits) = UintCoder.encode(token.value)
		let prefix = code.prefixCodes[Int(code.contextMap[Int(token.context)])]
		let depth = prefix.isDegenerate ? 0 : Int(prefix.depths[Int(symbol)])
		var data = prefix.isDegenerate ? 0 : UInt64(prefix.bits[Int(symbol)])
		data |= UInt64(bits) << UInt64(depth)
		write(depth + Int(bitCount), data)
	}
}
