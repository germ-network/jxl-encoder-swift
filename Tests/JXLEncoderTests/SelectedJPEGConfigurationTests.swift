import Foundation
import Testing

@Suite("Selected JPEG configuration")
struct SelectedJPEGConfigurationTests {
	static let pin = "a7a9c787341cf703dede03c2009fa460cae5e5df"
	static let evidencePath = "Reference/jpeg-container-configuration.md"

	static func inventory() throws -> DecisionInventory {
		DecisionInventory(
			inventoryTSV: try PackageCheckout.read("Reference/decision-inventory.tsv"),
			exemptTSV: try PackageCheckout.read(
				"Reference/decision-inventory-exempt.tsv"))
	}

	@Test(
		"selected JPEG reconstruction and box obligations remain inventoried",
		.enabled(if: PackageCheckout.isAvailable))
	func selectedJPEGObligationsRemainInventoried() throws {
		let inventory = try Self.inventory()
		let ih = try #require(inventory.rows.first { $0.id == "IH-04" })
		#expect(ih.swiftSymbol == "ImageHeader.write")
		#expect(ih.path == "both")
		#expect(ih.classification == "original")
		#expect(ih.verification == "diffed")
		#expect(ih.replacement == "GER-3388,GER-3389")
		#expect(ih.fixture == "-")
		#expect(ih.config.contains("-e 4 -j 1 --container=0"))
		#expect(ih.notes.contains("Pixel"))
		#expect(ih.evidence.contains("tools/cjxl_main.cc:1131"))
		#expect(ih.evidence.contains("Sources/JXLEncoder/ImageHeader.swift:"))

		let jbrd = try #require(inventory.rows.first { $0.id == "JR-03" })
		#expect(jbrd.swiftSymbol == "(absent)")
		#expect(jbrd.decision.contains("reconstruction"))
		#expect(jbrd.path == "jpeg" && jbrd.classification == "original")
		#expect(jbrd.replacement == "GER-3389,GER-3388")
		#expect(jbrd.config.contains("--container=0"))
		#expect(jbrd.config.contains("default reconstruction=1"))
		#expect(jbrd.evidence.contains("tools/cjxl_main.cc:517"))
		#expect(jbrd.evidence.contains("tools/cjxl_main.cc:1148-1156"))
		#expect(jbrd.evidence.contains("lib/extras/enc/jxl.cc:187-204"))
		#expect(jbrd.evidence.contains("lib/jxl/encode.cc:2278-2293"))

		let metadata = try #require(inventory.rows.first { $0.id == "JR-04" })
		#expect(metadata.swiftSymbol == "(absent)")
		#expect(metadata.path == "jpeg" && metadata.classification == "original")
		#expect(metadata.replacement == "GER-3389,GER-3388")
		#expect(metadata.config.contains("-e 4 -j 1 --container=0"))
		#expect(metadata.config.contains("default reconstruction=1"))
		#expect(metadata.evidence.contains("tools/cjxl_main.cc:517"))
		#expect(metadata.config.contains("default JPEG metadata storage"))
		#expect(metadata.evidence.contains("lib/jxl/encode.cc:2251-2276"))
		#expect(metadata.evidence.contains("lib/jxl/encode.cc:2182-2206"))
		#expect(metadata.evidence.contains("2244-2293"))
		#expect(PackageCheckout.fileExists(Self.evidencePath))

		let scope = try PackageCheckout.read("docs/gap-closure-plan.md")
		#expect(scope.contains("JR-03/04 therefore remain programme work"))
		#expect(scope.contains("reconstruction-enabled reference"))
		#expect(scope.contains("ICC and orientation decoded meaning"))
	}

	@Test(
		"selected JPEG source proof has pinned consumed provenance",
		.enabled(if: PackageCheckout.isAvailable))
	func selectedJPEGProofHasPinnedProvenance() throws {
		let proof = try PackageCheckout.read(Self.evidencePath)
		let copy = try #require(proof.range(of: "into `params.jpeg_store_metadata`"))
		let reset = try #require(
			proof.range(of: "sets `args.allow_jpeg_reconstruction = JXL_FALSE`"))
		let encode = try #require(proof.range(of: "reach `EncodeImageJXL`"))
		#expect(copy.lowerBound < reset.lowerBound)
		#expect(reset.lowerBound < encode.lowerBound)
		for required in [
			"libjxl v0.12.0", Self.pin,
			"cjxl_main.cc:232-236,517",
			"cjxl_main.cc:1085,1110,1131", "cjxl_main.cc:922-923",
			"cjxl_main.cc:1148-1156", "cjxl_main.cc:1190",
			"extras/enc/jxl.cc:187-204,206-233", "encode.cc:2182-2206",
			"2244-2293", "allow_jpeg_reconstruction=0",
			"strip=exif", "strip=xmp", "strip=jumbf", "cmd_encode_jpeg.cc:29-30",
		] {
			#expect(proof.contains(required), "proof lacks \(required)")
		}

		let manifest = try ProvenanceManifest(
			contentsOf: RepositoryLayout.provenanceManifest)
		let row = try #require(
			manifest.rows.first {
				$0.path
					== "Tests/JXLEncoderTests/SelectedJPEGConfigurationTests.swift"
			})
		#expect(row.kind == .inline)
		#expect(row.sha256 == nil)
		#expect(row.origin == .fullLibjxl)
		#expect(row.path == "Tests/JXLEncoderTests/SelectedJPEGConfigurationTests.swift")
		#expect(row.generator.contains(Self.evidencePath))
		#expect(row.generator.contains("cjxl_main.cc"))
		#expect(row.generator.contains("lib/jxl/encode.cc"))
		#expect(row.invocation == "manual pinned-source dataflow review")
		#expect(row.input == "-e 4 -j 1 --container=0")
		#expect(row.upstream == "libjxl \(Self.pin)")
		#expect(row.config.contains("default reconstruction=1"))
		#expect(
			row.consumers.contains(
				"SelectedJPEGConfigurationTests.swift#selectedJPEGProofHasPinnedProvenance"
			))
	}

	@Test(
		"JPEG source proof distinguishes pixel stripping and decoded meaning",
		.enabled(if: PackageCheckout.isAvailable))
	func selectedJPEGProofDistinguishesPixelPath() throws {
		let proof = try PackageCheckout.read(Self.evidencePath)
		#expect(proof.contains("args.allow_jpeg_reconstruction = JXL_FALSE"))
		#expect(proof.contains("params.jpeg_store_metadata` remains true"))
		#expect(proof.contains("jpeg_bytes"))
		#expect(proof.contains("pixel path has no original JPEG bytes"))
		#expect(proof.contains("ICC and orientation decoded meaning remain required"))
		#expect(proof.contains("no blanket metadata waiver"))
		#expect(proof.contains("No source/spec conflict was identified"))
		#expect(!proof.contains("full standard conformance"))
	}
}
