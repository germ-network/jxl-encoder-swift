//
//  ANSTokenWriter.swift
//  JXLEncoder
//
//  Port of `WriteTokens`' ANS branch (enc_ans.cc). Unlike the prefix path,
//  which writes tokens one at a time as they're staged, ANS requires the
//  whole section's token list up front: it encodes in reverse order, since
//  rANS's state recursion only runs backwards relative to how a decoder
//  reads it forward. No tiny counterpart.
//

enum ANSTokenWriter {
	/// `infoTables[context]` must hold the built info table for the
	/// histogram `contextMap[context]` selects — i.e. already composed the
	/// same way `EntropyCode.contextMap` composes for the prefix path.
	static func write(
		tokens: [Token], contextMap: [UInt8], infoTables: [[ANSEncSymbolInfo]],
		writer: inout BitWriter
	) {
		write(
			contextMapTokens: tokens.map {
				ContextMapEntropy.EncodedToken(token: $0, isLength: false)
			}, contextMap: contextMap, infoTables: infoTables,
			uintConfigurations: [HybridUintConfiguration](
				repeating: HybridUintConfiguration(
					splitExponent: 4, msbInToken: 2, lsbInToken: 0),
				count: infoTables.count),
			lengthConfiguration: HybridUintConfiguration(
				splitExponent: 0, msbInToken: 0, lsbInToken: 0),
			lengthSymbolOffset: 0, writer: &writer)
	}

	static func write(
		contextMapTokens tokens: [ContextMapEntropy.EncodedToken],
		contextMap: [UInt8], infoTables: [[ANSEncSymbolInfo]],
		uintConfigurations: [HybridUintConfiguration],
		lengthConfiguration: HybridUintConfiguration, lengthSymbolOffset: UInt32,
		writer: inout BitWriter
	) {
		var out: [(bits: UInt64, nbits: Int)] = []
		var allBits: UInt64 = 0
		var numAllBits = 0
		func addBits(_ bits: UInt64, _ nbits: Int) {
			guard nbits > 0 else { return }
			if numAllBits + nbits > BitWriter.maxBitsPerCall {
				out.append((allBits, numAllBits))
				allBits = 0
				numAllBits = 0
			}
			allBits = (allBits << UInt64(nbits)) | bits
			numAllBits += nbits
		}

		var coder = ANSState()
		for encoded in tokens.reversed() {
			let token = encoded.token
			let histo = Int(contextMap[Int(token.context)])
			let configuration =
				encoded.isLength
				? lengthConfiguration : uintConfigurations[histo]
			let (baseSymbol, extraBitCount, extraBits) = configuration.encode(
				token.value)
			let symbol = baseSymbol + (encoded.isLength ? lengthSymbolOffset : 0)
			let info = infoTables[histo][Int(symbol)]
			// Extra bits before the ANS bits, since this is all reversed —
			// once played back forward they land after their symbol's bits.
			addBits(UInt64(extraBits), Int(extraBitCount))
			let (ansBits, ansNBits) = coder.putSymbol(info)
			addBits(UInt64(ansBits), ansNBits)
		}

		writer.write(32, UInt64(coder.currentState))
		writer.write(numAllBits, allBits)
		for chunk in out.reversed() {
			writer.write(chunk.nbits, chunk.bits)
		}
	}
}
