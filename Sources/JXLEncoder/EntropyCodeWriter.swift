//
//  EntropyCodeWriter.swift
//  JXLEncoder
//
//  Port of `WriteContextMap` and `WriteEntropyCode` from libjxl-tiny's
//  encoder/enc_entropy_code.cc.
//
//  An entropy code is transmitted as its context map followed by its prefix
//  codes. The context map is itself entropy coded, with a code built from the
//  map's own symbol statistics.
//

enum EntropyCodeWriter {
	/// `allowANS` only ever applies to the context-map sub-encoding this
	/// writes, never to `code`'s own main token stream (`code.ansInfoTables`
	/// decides that independently, below) — see `writeContextMapEntries`.
	static func writeContextMap(
		_ code: EntropyCode, allowANS: Bool = false, writer: inout BitWriter
	) {
		guard code.transmittedContextCount != 0 else { return }

		// A re-clustered code composes with the map it was built from, so the
		// decoder still sees an entry per original context.
		let entries: [UInt8] =
			if let original = code.originalContextMap {
				original.map { code.contextMap[Int($0)] }
			} else {
				code.contextMap
			}
		writeContextMapEntries(entries, allowANS: allowANS, writer: &writer)
	}

	/// Writes an array of small integers as an entropy-coded context map —
	/// shared by an entropy code's own map above and, from
	/// `JPEGBlockContextMap`, the JPEG-transcode AC block-context map,
	/// exactly as full libjxl's `EncodeContextMap` serves both callers. Port
	/// of `EncodeContextMap` (enc_context_map.cc) minus the move-to-front
	/// choice, a pure size optimisation not yet ported.
	///
	/// `allowANS` must stay `false` for any caller whose context map has to
	/// stay byte-exact against libjxl-tiny's own (ANS-less) reference —
	/// `.staticAC`/`.staticDC`'s 1980/45-entry maps route through here too,
	/// and size alone can't tell those apart from a genuinely large, dynamic,
	/// ANS-eligible map (the optimised AC code's context map is the same
	/// 1980-entry raw space, just re-clustered).
	static func writeContextMapEntries(
		_ entries: [UInt8], allowANS: Bool = false, writer: inout BitWriter
	) {
		guard !entries.isEmpty else { return }

		// When every entry is the same the map carries no information. This is
		// the common case for a re-clustered code on a small image, and it
		// collapses the map to three bits.
		if entries.max() == 0 {
			writer.write(3, 1)  // simple code, 0 bits per entry
			return
		}
		writer.write(3, 0)  // no simple code, no move-to-front, no lz77

		let tokens = entries.map { Token(context: 0, value: UInt32($0)) }

		if allowANS && entries.count >= SectionOptimizer.ansMinimumTokens {
			let histogram = HistogramCluster.buildHistograms(
				tokens: tokens, contextMap: [0], contextCount: 1)[0]
			let selected = ANSEncodingHistogram.computeBest(
				counts: histogram.counts, strategy: .precise)
			let infoTable = ANSInfoTable.build(
				distribution: selected.normalizedCounts,
				alphabetSize: selected.alphabetSize,
				logAlphaSize: ANSConstants.logAlphaSize)
			writer.write(1, 0)  // use_prefix_code = false
			writer.write(2, UInt64(ANSConstants.logAlphaSize - 5))
			PrefixCodeWriter.writeUintConfigs(
				count: 1, logAlphaSize: ANSConstants.logAlphaSize, writer: &writer)
			selected.write(to: &writer)
			ANSTokenWriter.write(
				tokens: tokens, contextMap: [0], infoTables: [infoTable],
				writer: &writer)
			return
		}

		let mapCode = HistogramCluster.optimizePrefixCodes(
			tokens: tokens, contextMap: [0], prefixCodeCount: 1)
		writer.write(1, 1)  // use_prefix_code
		PrefixCodeWriter.writePrefixCodes(mapCode.prefixCodes, writer: &writer)
		for token in tokens {
			writer.write(token: token, code: mapCode)
		}
	}

	static func write(
		_ code: EntropyCode, allowContextMapANS: Bool = false, writer: inout BitWriter
	) {
		writeContextMap(code, allowANS: allowContextMapANS, writer: &writer)
		if let histograms = code.ansHistograms {
			writer.write(1, 0)  // use_prefix_code = false
			writer.write(2, UInt64(ANSConstants.logAlphaSize - 5))
			PrefixCodeWriter.writeUintConfigs(
				count: histograms.count, logAlphaSize: ANSConstants.logAlphaSize,
				writer: &writer)
			for histogram in histograms {
				histogram.write(to: &writer)
			}
		} else if let ansInfoTables = code.ansInfoTables {
			writer.write(1, 0)  // use_prefix_code = false
			writer.write(2, UInt64(ANSConstants.logAlphaSize - 5))
			PrefixCodeWriter.writeUintConfigs(
				count: ansInfoTables.count, logAlphaSize: ANSConstants.logAlphaSize,
				writer: &writer)
			for table in ansInfoTables {
				ANSHistogramWriter.write(counts: table.map(\.freq), writer: &writer)
			}
		} else {
			writer.write(1, 1)  // use_prefix_code
			PrefixCodeWriter.writePrefixCodes(code.prefixCodes, writer: &writer)
		}
	}
}

struct HybridUintConfiguration: Equatable, Sendable {
	let splitExponent: Int
	let msbInToken: Int
	let lsbInToken: Int

	func encode(_ value: UInt32) -> (symbol: UInt32, bitCount: UInt32, bits: UInt32) {
		fatalError("Hybrid uint encoding is not implemented")
	}
}

enum ContextMapEntropy {
	struct EncodedToken: Equatable, Sendable {
		let token: Token
		let isLength: Bool
	}

	struct RunLengthResult {
		let enabled: Bool
		let tokens: [EncodedToken]
	}

	struct Prepared {
		let runLength: RunLengthResult
		let contextMap: [UInt8]
		let histograms: [Histogram]
		let uintConfigurations: [HybridUintConfiguration]
		let usesPrefixCode: Bool
		let logAlphabetSize: Int
		let prefixCodes: [PrefixCode]
		let ansHistograms: [ANSEncodingHistogram]
		let estimatedCost: Int
	}

	static func runLengthEncode(_ entries: [UInt8]) -> RunLengthResult {
		fatalError("Context-map run length encoding is not implemented")
	}

	static func cluster(_ histograms: [Histogram]) -> (
		histograms: [Histogram], contextMap: [UInt8]
	) {
		fatalError("Context-map clustering is not implemented")
	}

	static func prepare(_ entries: [UInt8]) -> Prepared {
		fatalError("Context-map entropy preparation is not implemented")
	}

	static func write(_ prepared: Prepared, to writer: inout BitWriter) {
		fatalError("Context-map entropy serialization is not implemented")
	}
}

enum ContextMapEncoding {
	enum Representation: Equatable {
		case simple(entryBits: Int)
		case raw
		case moveToFront
	}

	struct Prepared {
		let entries: [UInt8]
		let numHistograms: Int
		let transformedEntries: [UInt8]
		let raw: ContextMapEntropy.Prepared?
		let moveToFront: ContextMapEntropy.Prepared?
		let representation: Representation
	}

	static func prepare(_ entries: [UInt8], numHistograms: Int) -> Prepared {
		fatalError("Context-map representation selection is not implemented")
	}

	static func write(_ prepared: Prepared, to writer: inout BitWriter) {
		fatalError("Context-map serialization is not implemented")
	}
}
