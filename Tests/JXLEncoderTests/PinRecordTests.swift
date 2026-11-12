import Foundation
import Testing

/// The reference build is only reproducible if it names one libjxl. Moving the
/// pin is a deliberate act: it has to change this test too.
@Suite("libjxl pin record")
struct PinRecordTests {
	@Test("pins full libjxl v0.12.0 at a7a9c787", .enabled(if: PackageCheckout.isAvailable))
	func pinsV0_12_0() throws {
		let pin = try PinRecord(contentsOf: RepositoryLayout.pinRecord)
		#expect(pin["LIBJXL_TAG"] == "v0.12.0")
		#expect(pin["LIBJXL_COMMIT"] == "a7a9c787341cf703dede03c2009fa460cae5e5df")
		#expect(pin["LIBJXL_URL"] != nil)
	}

	@Test(
		"records a full commit for libjxl and every submodule the build fetches",
		.enabled(if: PackageCheckout.isAvailable))
	func recordsSubmoduleCommits() throws {
		let pin = try PinRecord(contentsOf: RepositoryLayout.pinRecord)
		let keys = [
			"LIBJXL_COMMIT",
			"HIGHWAY_COMMIT",
			"BROTLI_COMMIT",
			"SKCMS_COMMIT",
			"TESTDATA_COMMIT",
		]
		for key in keys {
			let commit = try #require(pin[key])
			#expect(
				commit.count == 40
					&& commit.allSatisfy { $0.isHexDigit && !$0.isUppercase },
				"\(key) commit must be 40 lowercase hex characters: \(commit)"
			)
		}
	}

	@Test("sha256Hex matches the FIPS 180-2 test vectors")
	func digestKnownAnswers() throws {
		#expect(
			sha256Hex([])
				== "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
		)
		#expect(
			sha256Hex(Array("abc".utf8))
				== "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
		)
		#expect(
			sha256Hex(
				Array(
					"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
						.utf8)
			) == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
		)
	}
}
