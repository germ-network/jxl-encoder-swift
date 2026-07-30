import Foundation

/// Reads the dumps written by `Reference/tools/dump_jpeg_coefficients.c`:
/// libjpeg's own quantized coefficients and quantization tables for a fixture,
/// in the layout `JPEGParser` produces — blocks in raster order over the
/// MCU-padded grid, natural order within a block.
struct JPEGCoefficientDump {
	struct Component {
		let identifier: UInt8
		let horizontalSampling: Int
		let verticalSampling: Int
		let quantTableIndex: Int
		let blocksPerLine: Int
		let blocksPerColumn: Int
		let coefficients: [Int32]
	}

	enum DumpError: Error {
		case fixtureNotFound(String)
		case badMagic
		case truncated
	}

	let width: Int
	let height: Int
	let components: [Component]
	/// Sparse: only the table ids the file defines.
	let quantTables: [Int: [UInt16]]

	init(fixture name: String) throws {
		guard
			let url = Bundle.module.url(
				forResource: name, withExtension: "coef", subdirectory: "Fixtures")
		else {
			throw DumpError.fixtureNotFound(name)
		}
		let bytes = [UInt8](try Data(contentsOf: url))
		var cursor = 0

		func uint32() throws -> Int {
			guard cursor + 4 <= bytes.count else { throw DumpError.truncated }
			defer { cursor += 4 }
			return Int(bytes[cursor]) | Int(bytes[cursor + 1]) << 8
				| Int(bytes[cursor + 2]) << 16 | Int(bytes[cursor + 3]) << 24
		}
		func int16() throws -> Int32 {
			guard cursor + 2 <= bytes.count else { throw DumpError.truncated }
			defer { cursor += 2 }
			return Int32(
				Int16(
					bitPattern: UInt16(bytes[cursor]) | UInt16(
						bytes[cursor + 1]) << 8))
		}

		guard try uint32() == 0x3046_434A else { throw DumpError.badMagic }
		width = try uint32()
		height = try uint32()
		let count = try uint32()

		var headers: [(UInt8, Int, Int, Int, Int, Int)] = []
		for _ in 0..<count {
			headers.append(
				(
					UInt8(try uint32()), try uint32(), try uint32(),
					try uint32(),
					try uint32(), try uint32()
				))
		}

		components = try headers.map { header in
			let (identifier, horizontal, vertical, quantIndex, blocksX, blocksY) =
				header
			var coefficients = [Int32](repeating: 0, count: blocksX * blocksY * 64)
			for i in 0..<coefficients.count { coefficients[i] = try int16() }
			return Component(
				identifier: identifier, horizontalSampling: horizontal,
				verticalSampling: vertical, quantTableIndex: quantIndex,
				blocksPerLine: blocksX, blocksPerColumn: blocksY,
				coefficients: coefficients)
		}

		var tables: [Int: [UInt16]] = [:]
		for index in 0..<4 {
			guard try uint32() == 1 else { continue }
			var table = [UInt16](repeating: 0, count: 64)
			for k in 0..<64 { table[k] = UInt16(try uint32()) }
			tables[index] = table
		}
		quantTables = tables
	}
}
