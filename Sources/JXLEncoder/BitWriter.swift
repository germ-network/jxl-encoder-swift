//
//  BitWriter.swift
//  JXLEncoder
//
//  Port of libjxl-tiny's encoder/enc_bit_writer.{h,cc}. The reference uses an
//  Allotment type to pre-size storage for unaligned 64-bit stores; a growable
//  Swift array makes that unnecessary, so only the bit-order semantics carry
//  over.
//

/// Writes bits into bytes in increasing address order, least-significant-bit
/// first within each byte, per the JPEG XL codestream convention.
public struct BitWriter: Sendable {
	/// Shifting a 64-bit word left by up to 7 already-valid bits must not
	/// overflow, so a single call tops out at 56 bits.
	public static let maxBitsPerCall = 56

	public private(set) var bytes: [UInt8] = []
	public private(set) var bitsWritten: Int = 0

	public init() {}

	public var isByteAligned: Bool { bitsWritten % 8 == 0 }

	public mutating func write(_ nBits: Int, _ bits: UInt64) {
		precondition(
			nBits >= 0 && nBits <= Self.maxBitsPerCall,
			"nBits \(nBits) out of range 0...\(Self.maxBitsPerCall)")
		precondition(
			nBits == 0 || bits >> UInt64(nBits) == 0,
			"value \(bits) does not fit in \(nBits) bits")
		guard nBits > 0 else { return }

		var value = bits << UInt64(bitsWritten % 8)
		var index = bitsWritten / 8
		var bitsLeft = nBits + bitsWritten % 8

		while bitsLeft > 0 {
			if index == bytes.count { bytes.append(0) }
			bytes[index] |= UInt8(truncatingIfNeeded: value)
			value >>= 8
			bitsLeft -= 8
			index += 1
		}
		bitsWritten += nBits
	}

	public mutating func zeroPadToByte() {
		let remainder = (8 - bitsWritten % 8) % 8
		guard remainder > 0 else { return }
		write(remainder, 0)
	}

	public mutating func append(_ other: BitWriter) {
		let fullBytes = other.bitsWritten / 8
		for i in 0..<fullBytes {
			write(8, UInt64(other.bytes[i]))
		}
		let trailingBits = other.bitsWritten % 8
		if trailingBits > 0 {
			let mask = (UInt64(1) << UInt64(trailingBits)) - 1
			write(trailingBits, UInt64(other.bytes[fullBytes]) & mask)
		}
	}

	/// Byte-aligned concatenation, used where later sections are referenced by
	/// byte offset (the TOC points at groups this way).
	public mutating func appendByteAligned(_ others: [BitWriter]) {
		precondition(isByteAligned, "appendByteAligned requires byte alignment")
		for other in others {
			var padded = other
			padded.zeroPadToByte()
			bytes.append(contentsOf: padded.bytes.prefix(padded.bitsWritten / 8))
			bitsWritten += padded.bitsWritten
		}
	}

	/// Finished bytes. Requires byte alignment so no uninitialized bits escape.
	public func take() -> [UInt8] {
		precondition(isByteAligned, "take() requires byte alignment")
		return Array(bytes.prefix(bitsWritten / 8))
	}
}
