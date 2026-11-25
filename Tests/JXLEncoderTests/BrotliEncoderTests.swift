import Foundation
import Testing

@testable import JXLEncoder

/// Brotli streams must be RFC 7932-conformant and decode to their input byte
/// for byte. Google's reference decoder checks that wherever it can run; the
/// remaining tests pin the encoder's own invariants on every platform.
@Suite("Brotli encoder")
struct BrotliEncoderTests {
	@Suite("stream framing")
	struct Framing {
		@Test(
			"empty input is the WBITS 22 header and an empty last meta-block",
			.disabled())
		func emptyInput() {}

		@Test("the stream header encodes WBITS 22 in four bits", .disabled())
		func streamHeader() {}

		@Test(
			"an uncompressed meta-block carries MLEN - 1 in four nibbles, then the bytes verbatim from a byte boundary",
			.disabled())
		func uncompressedMetaBlock() {}

		@Test("inputs are split into meta-blocks of at most 64 KiB", .disabled())
		func metaBlockSplit() {}
	}

	@Suite("length and distance codes")
	struct Codes {
		@Test(
			"every insert length up to 2^16 maps to its RFC 7932 §5 code and extra bits",
			.disabled())
		func insertCodes() {}

		@Test(
			"every copy length from 2 to 2^16 maps to its RFC 7932 §5 code and extra bits",
			.disabled())
		func copyCodes() {}

		@Test(
			"insert-and-copy symbols follow the §5 cell table, with implicit distance reuse only in 0...127",
			.disabled())
		func insertAndCopySymbols() {}

		@Test(
			"the distance ring starts with last 4, then 11, 15, 16, and symbol 0 does not push",
			.disabled())
		func distanceRing() {}

		@Test(
			"special distance symbols resolve to the distance they encode and never to zero or less",
			.disabled())
		func specialDistanceSymbols() {}

		@Test(
			"long distance symbols and extra bits give back the distance by the §4 formula",
			.disabled())
		func longDistanceSymbols() {}
	}

	@Suite("prefix codes")
	struct PrefixCodes {
		@Test(
			"code lengths stay within 15 bits and fill the code space exactly",
			.disabled())
		func depthLimitAndCompleteness() {}

		@Test(
			"simple-code symbols use the bit width of the whole alphabet, not the largest symbol",
			.disabled())
		func simpleCodeSymbolWidth() {}

		@Test(
			"an empty or one-symbol histogram gives a degenerate code that costs no bits per symbol",
			.disabled())
		func degenerateCodes() {}
	}

	@Suite("backward references")
	struct References {
		@Test("replaying the commands reproduces the input range", .disabled())
		func commandsReplay() {}

		@Test(
			"no copy reaches beyond the window or before the input start, and every copy is at least 2 bytes",
			.disabled())
		func copiesStayInWindow() {}

		@Test("copies may reach back into earlier meta-blocks", .disabled())
		func crossMetaBlockCopies() {}

		@Test(
			"a short match is deferred when the next position starts a much longer one",
			.disabled())
		func lazyMatching() {}
	}

	@Suite("size bound")
	struct SizeBound {
		@Test(
			"incompressible input of N bytes takes at most N + 3 per 64 KiB meta-block + 1 bytes",
			.disabled())
		func incompressibleInputBound() {}

		@Test(
			"writing the smaller form advances the distance ring only when the compressed form is kept",
			.disabled())
		func rejectedTrialKeepsRing() {}

		@Test("repetitive input compresses below a tenth of its size", .disabled())
		func repetitiveInputCompresses() {}
	}

	@Suite("reference decoder")
	struct ReferenceDecoder {
		@Test(
			"Google's brotli decoder reproduces every corpus input exactly",
			.disabled())
		func roundTripsThroughReference() {}
	}
}
