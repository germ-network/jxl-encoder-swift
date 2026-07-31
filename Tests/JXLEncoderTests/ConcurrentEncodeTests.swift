import Testing

@testable import JXLEncoder

/// Running the AC groups concurrently must not change what comes out.
///
/// Groups read only the shared linear image and their own geometry, and the
/// assembly step keys off each group's coordinates rather than the order
/// results arrive in — so the output is byte-identical, and that is the whole
/// contract. Anything less would mean the groups were not as independent as the
/// format says.
@Suite("Concurrent encoding")
struct ConcurrentEncodeTests {
	static func image(width: Int, height: Int) throws -> ImageBuffer {
		var samples = [UInt8](repeating: 0, count: width * height * 3)
		for y in 0..<height {
			for x in 0..<width {
				let i = (y * width + x) * 3
				samples[i] = UInt8((x * 7 + y * 3) % 256)
				samples[i + 1] = UInt8((x * 3 + y * 11) % 256)
				samples[i + 2] = UInt8((x &* y) % 256)
			}
		}
		return try ImageBuffer(width: width, height: height, samples: samples)
	}

	/// Sizes chosen around the group boundary: one group, several, and a size
	/// whose last group is partial in both directions.
	@Test(
		"concurrent output is byte-identical",
		arguments: [(64, 64), (256, 256), (301, 301), (600, 400), (513, 257)])
	func identical(width: Int, height: Int) async throws {
		let image = try Self.image(width: width, height: height)
		let sequential = try Encoder.encode(image, distance: 1.0)
		let concurrent = try await Encoder.encodeConcurrently(image, distance: 1.0)
		#expect(sequential == concurrent)
	}

	/// The staged entropy path collects tokens from every group before building
	/// a code, so it is the one most exposed to results arriving out of order.
	@Test("both entropy paths agree", arguments: [true, false])
	func entropyPaths(optimize: Bool) async throws {
		let image = try Self.image(width: 301, height: 301)
		let sequential = try Encoder.encode(
			image, distance: 1.0, optimizeCodes: optimize)
		let concurrent = try await Encoder.encodeConcurrently(
			image, distance: 1.0, optimizeCodes: optimize)
		#expect(sequential == concurrent)
	}

	@Test(
		"distance and transfer function carry through",
		arguments: [0.5, 1.0, 3.0] as [Float])
	func parametersCarry(distance: Float) async throws {
		let image = try Self.image(width: 300, height: 200)
		let sequential = try Encoder.encode(
			image, distance: distance, transferFunction: .linear)
		let concurrent = try await Encoder.encodeConcurrently(
			image, distance: distance, transferFunction: .linear)
		#expect(sequential == concurrent)
	}
}
