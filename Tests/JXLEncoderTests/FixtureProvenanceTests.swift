import Foundation
import Testing

/// Every committed reference artifact says where it came from, and its bytes
/// can't change without the manifest changing with it.
@Suite("Fixture provenance")
struct FixtureProvenanceTests {
	@Test("every file in both Fixtures directories has exactly one fixture row")
	func everyFixtureHasOneRow() throws {
		let manifest = try ProvenanceManifest(
			contentsOf: RepositoryLayout.provenanceManifest)
		let root = RepositoryLayout.root
		let fixtureDirs = [
			root.appendingPathComponent("Tests/JXLEncoderTests/Fixtures"),
			root.appendingPathComponent("Tests/JXLEncoderAppleTests/Fixtures"),
		]
		var diskFixtures: [String] = []
		for dir in fixtureDirs {
			let contents = try FileManager.default.contentsOfDirectory(
				at: dir,
				includingPropertiesForKeys: nil,
				options: []
			)
			for fileURL in contents {
				if fileURL.lastPathComponent == ".DS_Store" { continue }
				let rel = fileURL.path.replacingOccurrences(
					of: root.path + "/", with: "")
				diskFixtures.append(rel)
			}
		}

		let fixtureRows = manifest.rows.filter { $0.kind == .fixture }
		let manifestPaths = fixtureRows.map(\.path)

		// Every file on disk must be in manifest exactly once
		for diskFile in diskFixtures {
			let count = manifestPaths.filter { $0 == diskFile }.count
			#expect(
				count == 1,
				"Fixture \(diskFile) has \(count) rows in manifest, expected 1")
		}

		// Every fixture row in manifest must be on disk
		for row in fixtureRows {
			#expect(
				diskFixtures.contains(row.path),
				"Manifest fixture row not on disk: \(row.path)")
		}
	}

	@Test("every fixture row names a file that exists")
	func noOrphanRows() throws {
		let manifest = try ProvenanceManifest(
			contentsOf: RepositoryLayout.provenanceManifest)
		let root = RepositoryLayout.root
		for row in manifest.rows where row.kind == .fixture {
			let fileURL = root.appendingPathComponent(row.path)
			#expect(
				FileManager.default.fileExists(atPath: fileURL.path),
				"Fixture row \(row.path) does not exist on disk")
		}
	}

	@Test("every fixture's bytes match its recorded sha256")
	func bytesMatchRecordedDigest() throws {
		let manifest = try ProvenanceManifest(
			contentsOf: RepositoryLayout.provenanceManifest)
		let root = RepositoryLayout.root
		for row in manifest.rows where row.kind == .fixture {
			let fileURL = root.appendingPathComponent(row.path)
			let data = try Data(contentsOf: fileURL)
			let actualSHA = sha256Hex(Array(data))
			#expect(
				actualSHA == row.sha256,
				"Fixture \(row.path) SHA-256 mismatch: got \(actualSHA) expected \(row.sha256 ?? "nil")"
			)
		}
	}

	@Test("full-libjxl rows cite the pinned commit; inherited-tiny rows say unpinned")
	func upstreamMatchesOrigin() throws {
		let pin = try PinRecord(contentsOf: RepositoryLayout.pinRecord)
		let pinnedCommit = try #require(pin["LIBJXL_COMMIT"])
		let manifest = try ProvenanceManifest(
			contentsOf: RepositoryLayout.provenanceManifest)

		func checkRows(_ rows: [ProvenanceRow]) {
			for row in rows {
				switch row.origin {
				case .fullLibjxl:
					#expect(
						row.upstream.contains(pinnedCommit),
						"full-libjxl row \(row.path) must cite \(pinnedCommit): \(row.upstream)"
					)
				case .inheritedTiny:
					#expect(
						row.upstream.contains("unpinned"),
						"inherited-tiny row \(row.path) must cite 'unpinned': \(row.upstream)"
					)
				default:
					break
				}
			}
		}

		checkRows(manifest.rows)

		// Also check in-memory manifest with a synthetic full-libjxl fixture row
		let syntheticTSV = """
			# test manifest
			Tests/JXLEncoderTests/Fixtures/edge_linear.dump\tfixture\t42ce7bc0d2396787f047327d65e523e49218032b6f0977104af773fe221fc60b\tfull-libjxl\tReference/build/cjxl\tcjxl -d 1.0\tin.ppm\tlibjxl \(pinnedCommit)\tRelease\t-
			"""
		let inMemory = try ProvenanceManifest(text: syntheticTSV)
		checkRows(inMemory.rows)
	}

	@Test("a malformed manifest row is rejected, not skipped")
	func malformedRowThrows() throws {
		// Wrong column count (9 columns)
		let wrongCols =
			"path\tfixture\t\(String(repeating: "a", count: 64))\tinherited-tiny\tgen\tinv\tin\tupstream\tconfig"
		#expect(throws: Error.self) { try ProvenanceManifest(text: wrongCols) }

		// Bad kind
		let badKind = "path\tnotakind\t-\tinherited-tiny\tgen\tinv\tin\tupstream\tconfig\t-"
		#expect(throws: Error.self) { try ProvenanceManifest(text: badKind) }

		// Bad origin
		let badOrigin = "path\tinline\t-\tnotanorigin\tgen\tinv\tin\tupstream\tconfig\t-"
		#expect(throws: Error.self) { try ProvenanceManifest(text: badOrigin) }

		// SHA present on inline row
		let shaOnInline =
			"path\tinline\t\(String(repeating: "a", count: 64))\tinherited-tiny\tgen\tinv\tin\tupstream\tconfig\t-"
		#expect(throws: Error.self) { try ProvenanceManifest(text: shaOnInline) }

		// SHA missing on fixture row
		let shaMissing =
			"path\tfixture\t-\tinherited-tiny\tgen\tinv\tin\tupstream\tconfig\t-"
		#expect(throws: Error.self) { try ProvenanceManifest(text: shaMissing) }

		// Bad SHA format (uppercase)
		let badSha =
			"path\tfixture\t\(String(repeating: "A", count: 64))\tinherited-tiny\tgen\tinv\tin\tupstream\tconfig\t-"
		#expect(throws: Error.self) { try ProvenanceManifest(text: badSha) }

		// Empty required field (e.g. empty generator)
		let emptyGenerator =
			"path\tinline\t-\tinherited-tiny\t\tinv\tin\tupstream\tconfig\t-"
		#expect(throws: Error.self) { try ProvenanceManifest(text: emptyGenerator) }
	}

	@Test("only fixture rows carry a sha256, and every fixture row does")
	func digestPresenceFollowsKind() throws {
		let manifest = try ProvenanceManifest(
			contentsOf: RepositoryLayout.provenanceManifest)
		for row in manifest.rows {
			if row.kind == .fixture {
				let sha = try #require(row.sha256)
				#expect(
					sha.count == 64
						&& sha.allSatisfy {
							$0.isHexDigit && !$0.isUppercase
						})
			} else {
				#expect(row.sha256 == nil)
			}
		}
	}

	@Test("every inline row names a test file that exists")
	func inlineRowsNameExistingTests() throws {
		let manifest = try ProvenanceManifest(
			contentsOf: RepositoryLayout.provenanceManifest)
		let root = RepositoryLayout.root
		let inlineRows = manifest.rows.filter { $0.kind == .inline }
		#expect(!inlineRows.isEmpty, "Manifest must have at least one inline row")

		// Check uniqueness
		let paths = inlineRows.map(\.path)
		#expect(Set(paths).count == paths.count, "Inline rows must have unique paths")

		// Expected inline tests from plan.md
		let expectedInlineTests = [
			"Tests/JXLEncoderTests/EntropyTests.swift",
			"Tests/JXLEncoderTests/ImageHeaderTests.swift",
			"Tests/JXLEncoderTests/DistanceParamsTests.swift",
		]
		for expected in expectedInlineTests {
			#expect(
				paths.contains(expected),
				"Missing expected inline row for \(expected)")
		}

		for row in inlineRows {
			let fileURL = root.appendingPathComponent(row.path)
			#expect(
				FileManager.default.fileExists(atPath: fileURL.path),
				"Inline row test file does not exist: \(row.path)")
		}
	}
}
