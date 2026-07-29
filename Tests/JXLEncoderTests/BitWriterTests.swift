import Testing

@testable import JXLEncoder

@Suite("BitWriter")
struct BitWriterTests {
	@Test("writes least-significant-bit first within a byte")
	func lsbFirst() {
		var w = BitWriter()
		w.write(1, 1)
		w.write(1, 0)
		w.write(1, 1)
		w.zeroPadToByte()
		#expect(w.take() == [0b0000_0101])
	}

	@Test("spans byte boundaries in increasing address order")
	func acrossBytes() {
		var w = BitWriter()
		w.write(4, 0xF)
		w.write(8, 0xAB)
		w.zeroPadToByte()
		#expect(w.take() == [0xBF, 0x0A])
	}

	@Test("writes a full 56-bit word")
	func maxWidth() {
		var w = BitWriter()
		w.write(56, 0x00FF_EEDD_CCBB_AA)
		#expect(w.bitsWritten == 56)
		#expect(w.take() == [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00])
	}

	@Test("zeroPadToByte is a no-op when already aligned")
	func padAligned() {
		var w = BitWriter()
		w.write(8, 0x42)
		w.zeroPadToByte()
		#expect(w.bitsWritten == 8)
		#expect(w.take() == [0x42])
	}

	@Test("append concatenates at bit granularity")
	func appendBits() {
		var a = BitWriter()
		a.write(3, 0b101)
		var b = BitWriter()
		b.write(5, 0b11010)
		a.append(b)
		#expect(a.bitsWritten == 8)
		#expect(a.take() == [0b1101_0101])
	}

	@Test("appendByteAligned pads each section to a byte boundary")
	func appendAligned() {
		var a = BitWriter()
		a.write(8, 0x11)
		var b = BitWriter()
		b.write(4, 0x2)
		var c = BitWriter()
		c.write(8, 0x33)
		a.appendByteAligned([b, c])
		#expect(a.take() == [0x11, 0x02, 0x33])
	}
}
