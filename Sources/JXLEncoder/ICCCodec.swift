//
//  ICCCodec.swift
//  JXLEncoder
//
//  The codestream's compressed ICC profile: libjxl's predictive transform
//  (enc_icc_codec.cc `PredictICC`), its byte contexts (icc_codec_common.cc
//  `ICCANSContext`) and the header field that carries both
//  (enc_icc_codec.cc `WriteICC`). A decoder inverts it to the exact source
//  bytes.
//

enum ICCCodec {
	/// `kNumICCContexts` (icc_codec_common.h).
	static let contextCount = 41

	/// The transformed stream a decoder's `UnpredictICC` maps back to `icc`
	/// byte for byte: varint size, varint command count, commands, then data.
	/// Ports `PredictICC` (enc_icc_codec.cc).
	static func predict(_ icc: [UInt8]) -> [UInt8] {
		fatalError("unimplemented")
	}

	/// The context of transformed byte `index` given the two bytes before it:
	/// 0 for `index <= 128` (the first 129 bytes), otherwise a byte-kind pair
	/// in 1..<41. Ports `ICCANSContext` (icc_codec_common.cc:171-174).
	static func context(index: Int, previous: UInt8, previousPrevious: UInt8) -> Int {
		fatalError("unimplemented")
	}

	/// Optimal LZ77 below 16,384 transformed bytes and greedy LZ77 from there
	/// (enc_icc_codec.cc:472-473).
	static func lz77Method(transformedSize: Int) -> LZ77.Method {
		fatalError("unimplemented")
	}

	/// Writes U64(transformed length) then the transformed bytes as
	/// forced-prefix tokens over `contextCount` contexts, with LZ77 chosen by
	/// `lz77Method(transformedSize:)`. Ports `WriteICC` (enc_icc_codec.cc).
	static func write(_ profile: ICCProfile, to writer: inout BitWriter) {
		fatalError("unimplemented")
	}
}
