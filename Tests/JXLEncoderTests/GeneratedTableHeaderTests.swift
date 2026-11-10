import Foundation
import Testing

/// A generated table compiled into the encoder carries its own provenance, so a
/// reader of the source sees the generator, upstream and configuration without
/// going to the manifest — and the two can't disagree.
@Suite("Generated table headers")
struct GeneratedTableHeaderTests {
	@Test("every table row's source file header cites its generator, upstream and config")
	func headersCiteManifestRow() throws {
		let manifest = try ProvenanceManifest(
			contentsOf: RepositoryLayout.provenanceManifest)
		let tableRows = manifest.rows.filter { $0.kind == .table }
		#expect(!tableRows.isEmpty, "manifest must carry at least one table row")

		let tablePaths = tableRows.map(\.path)
		#expect(
			Set(tablePaths).count == tablePaths.count,
			"Table rows must have unique paths")

		let expectedTables = [
			"Sources/JXLEncoder/StaticEntropyCodes.swift",
			"Sources/JXLEncoder/ContextTree.swift",
			"Sources/JXLEncoder/QuantMatrices.swift",
			"Sources/JXLEncoder/SRGBTransfer.swift",
		]
		for expected in expectedTables {
			#expect(
				tablePaths.contains(expected),
				"Missing expected table row for \(expected)")
		}

		let root = RepositoryLayout.root
		for row in tableRows {
			let fileURL = root.appendingPathComponent(row.path)
			let exists = FileManager.default.fileExists(atPath: fileURL.path)
			#expect(exists, "Table source file does not exist: \(row.path)")
			guard exists else { continue }

			let content = try String(contentsOf: fileURL, encoding: .utf8)
			let lines = content.components(separatedBy: "\n")

			// Extract leading comment block
			var headerLines: [String] = []
			for line in lines {
				let trimmed = line.trimmingCharacters(
					in: .whitespacesAndNewlines)
				if trimmed.hasPrefix("//") {
					let afterSlash = trimmed.dropFirst(2).trimmingCharacters(
						in: .whitespacesAndNewlines)
					headerLines.append(afterSlash)
				} else if trimmed.isEmpty && headerLines.isEmpty {
					continue
				} else {
					break
				}
			}

			var generator: String?
			var upstream: String?
			var config: String?

			for h in headerLines {
				if h.hasPrefix("Generator:") {
					generator = h.dropFirst("Generator:".count)
						.trimmingCharacters(
							in: .whitespacesAndNewlines)
				} else if h.hasPrefix("Upstream:") {
					upstream = h.dropFirst("Upstream:".count)
						.trimmingCharacters(
							in: .whitespacesAndNewlines)
				} else if h.hasPrefix("Config:") {
					config = h.dropFirst("Config:".count).trimmingCharacters(
						in: .whitespacesAndNewlines)
				}
			}

			#expect(
				generator == row.generator,
				"Header Generator mismatch in \(row.path): got \(generator ?? "nil"), expected \(row.generator)"
			)
			#expect(
				upstream == row.upstream,
				"Header Upstream mismatch in \(row.path): got \(upstream ?? "nil"), expected \(row.upstream)"
			)
			#expect(
				config == row.config,
				"Header Config mismatch in \(row.path): got \(config ?? "nil"), expected \(row.config)"
			)
		}
	}
}
