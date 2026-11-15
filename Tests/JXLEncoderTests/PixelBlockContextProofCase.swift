@testable import JXLEncoder

/// The bounded upstream category lookups consumed by PX-01's token-context test.
struct PixelBlockContextProofCase: Sendable {
	enum Decision: String, Sendable {
		case categoryLookup = "PX-01"
	}

	let fixture: String
	let category: String
	let decision: Decision

	var reference: String {
		"Tests/JXLEncoderTests/Fixtures/semantic/\(fixture).sem#\(category)"
	}

	static let categoryLookup = Self(
		fixture: "e4_pixel_block_model_ties", category: "consumer_categories",
		decision: .categoryLookup)

	static func proves(_ reference: String, decision: String) -> Bool {
		Self.categoryLookup.reference == reference
			&& Self.categoryLookup.decision.rawValue == decision
	}
}
