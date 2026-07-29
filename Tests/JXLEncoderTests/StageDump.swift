import Foundation

/// Reads the planar float32 dumps written by `Reference/tools/dump_stages.cc`,
/// which capture libjxl-tiny's intermediate stages for differential testing.
struct StageDump {
	let width: Int
	let height: Int
	let planes: [[Float]]

	var pixelCount: Int { width * height }

	/// Channel-major planar layout flattened to the interleaved form the
	/// encoder core takes as input.
	var interleaved: [Float] {
		var out = [Float](repeating: 0, count: pixelCount * planes.count)
		for (c, plane) in planes.enumerated() {
			for i in 0..<pixelCount {
				out[i * planes.count + c] = plane[i]
			}
		}
		return out
	}

	init(fixture name: String) throws {
		guard
			let url = Bundle.module.url(
				forResource: name, withExtension: "dump", subdirectory: "Fixtures")
		else {
			throw DumpError.fixtureNotFound(name)
		}
		try self.init(contentsOf: url)
	}

	init(contentsOf url: URL) throws {
		let data = try Data(contentsOf: url)
		guard data.count >= 16 else { throw DumpError.truncated }

		func u32(_ offset: Int) -> UInt32 {
			data.withUnsafeBytes {
				$0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
			}
		}
		guard u32(0) == 0x304D_5544 else { throw DumpError.badMagic }

		width = Int(u32(4))
		height = Int(u32(8))
		let channels = Int(u32(12))

		let count = width * height
		guard data.count == 16 + count * channels * 4 else { throw DumpError.truncated }

		var planes: [[Float]] = []
		var offset = 16
		for _ in 0..<channels {
			var plane = [Float](repeating: 0, count: count)
			for i in 0..<count {
				plane[i] = data.withUnsafeBytes {
					$0.loadUnaligned(
						fromByteOffset: offset + i * 4, as: Float.self)
				}
			}
			planes.append(plane)
			offset += count * 4
		}
		self.planes = planes
	}

	enum DumpError: Error {
		case fixtureNotFound(String)
		case badMagic
		case truncated
	}
}

/// Distance in representable floats. Zero means bit-identical.
func ulpDistance(_ a: Float, _ b: Float) -> Int {
	if a == b { return 0 }
	return abs(Int(Int32(bitPattern: a.bitPattern)) - Int(Int32(bitPattern: b.bitPattern)))
}
