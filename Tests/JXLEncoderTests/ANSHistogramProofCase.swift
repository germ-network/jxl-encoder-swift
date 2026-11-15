import Foundation

@testable import JXLEncoder

/// Typed bounds for the public libjxl ANS witnesses cited by the inventory.
struct ANSHistogramProofCase: Sendable {
	struct InlineRLE: Sendable {
		let name: String
		let counts: [UInt32]
		let normalized: [Int]
		let sourceDerivedOmitPosition: Int
		let headerBits: Int
		let bytes: [Int]
		let decisions: Set<Decision>
	}

	enum Decision: String, CaseIterable, Sendable {
		case selection = "AH-01"
		case omission = "AH-02"
		case rebalancing = "AH-03"
		case generalSerialization = "AH-04"
		case smallTreeSerialization = "AH-05"
		case contextMapSelection = "EW-08"
	}

	enum Observation: Sendable {
		case selectedCandidate(strategy: ANSHistogramStrategy, shift: Int?)
		case semanticHistogram(strategy: ANSHistogramStrategy)
		case preciseContextMap(shift: Int)
	}

	let fixture: String
	let decisions: Set<Decision>
	let observation: Observation

	var reference: String {
		let category: String
		switch observation {
		case .semanticHistogram: category = "histogram"
		case .selectedCandidate, .preciseContextMap: category = "ans_cost"
		}
		return "Tests/JXLEncoderTests/Fixtures/entropy/\(fixture).expected.sem#\(category)"
	}

	var strategy: ANSHistogramStrategy {
		switch observation {
		case .selectedCandidate(let strategy, _): strategy
		case .semanticHistogram(let strategy): strategy
		case .preciseContextMap: .precise
		}
	}

	var selectedShift: Int? {
		switch observation {
		case .selectedCandidate(_, let shift): shift
		case .preciseContextMap(let shift): shift
		case .semanticHistogram: nil
		}
	}

	static let selectedCandidates: [Self] = [
		.init(
			fixture: "ans_cost_sparse_precise",
			decisions: [.selection, .omission, .rebalancing, .generalSerialization],
			observation: .selectedCandidate(strategy: .precise, shift: 0)),
		.init(
			fixture: "ans_cost_flat_alphabet47",
			decisions: [.selection],
			observation: .selectedCandidate(strategy: .fast, shift: nil)),
		.init(
			fixture: "ans_cost_skewed_approximate",
			decisions: [.selection, .omission, .rebalancing, .generalSerialization],
			observation: .selectedCandidate(strategy: .approximate, shift: 4)),
		.init(
			fixture: "ans_cost_approx_step2_witness",
			decisions: [.selection, .rebalancing, .generalSerialization],
			observation: .selectedCandidate(strategy: .approximate, shift: 6)),
		.init(
			fixture: "ans_cost_precise_map_witness",
			decisions: [.selection, .rebalancing, .generalSerialization],
			observation: .selectedCandidate(strategy: .precise, shift: 7)),
		.init(
			fixture: "ans_cost_scaled_fast",
			decisions: [.selection, .rebalancing, .generalSerialization],
			observation: .selectedCandidate(strategy: .fast, shift: 6)),
		.init(
			fixture: "ans_cost_shift_2",
			decisions: [.selection, .omission, .rebalancing, .generalSerialization],
			observation: .selectedCandidate(strategy: .precise, shift: 2)),
		.init(
			fixture: "ans_cost_shift_3",
			decisions: [.selection, .omission, .rebalancing, .generalSerialization],
			observation: .selectedCandidate(strategy: .precise, shift: 3)),
		.init(
			fixture: "ans_cost_shift_5",
			decisions: [.selection, .omission, .rebalancing, .generalSerialization],
			observation: .selectedCandidate(strategy: .precise, shift: 5)),
		.init(
			fixture: "ans_cost_shift_7",
			decisions: [.selection, .omission, .rebalancing, .generalSerialization],
			observation: .selectedCandidate(strategy: .precise, shift: 7)),
		.init(
			fixture: "ans_cost_shift_8",
			decisions: [.selection, .omission, .rebalancing, .generalSerialization],
			observation: .selectedCandidate(strategy: .precise, shift: 8)),
		.init(
			fixture: "ans_cost_shift_9",
			decisions: [.selection, .omission, .rebalancing, .generalSerialization],
			observation: .selectedCandidate(strategy: .precise, shift: 9)),
		.init(
			fixture: "ans_cost_shift_10",
			decisions: [.selection, .omission, .rebalancing, .generalSerialization],
			observation: .selectedCandidate(strategy: .precise, shift: 10)),
		.init(
			fixture: "ans_cost_shift_11",
			decisions: [.selection, .omission, .rebalancing, .generalSerialization],
			observation: .selectedCandidate(strategy: .precise, shift: 11)),
	]

	static let smallTrees: [Self] = [
		.init(
			fixture: "ans_empty", decisions: [.smallTreeSerialization],
			observation: .semanticHistogram(strategy: .fast)),
		.init(
			fixture: "ans_all_zero", decisions: [.smallTreeSerialization],
			observation: .semanticHistogram(strategy: .fast)),
		.init(
			fixture: "ans_singleton_precise", decisions: [.smallTreeSerialization],
			observation: .semanticHistogram(strategy: .precise)),
		.init(
			fixture: "ans_two_symbol_approximate", decisions: [.smallTreeSerialization],
			observation: .semanticHistogram(strategy: .approximate)),
	]

	static let contextMap = Self(
		fixture: "ans_cost_precise_map_witness", decisions: [.contextMapSelection],
		observation: .preciseContextMap(shift: 7))

	static let all = selectedCandidates + smallTrees + [contextMap]

	static let inlineRLE: [InlineRLE] = [
		.init(
			name: "public-rle4", counts: [100, 1, 1, 1, 1],
			normalized: [3968, 32, 32, 32, 32], sourceDerivedOmitPosition: 0,
			headerBits: 23,
			bytes: [24, 32, 73], decisions: [.omission, .generalSerialization]),
		.init(
			name: "public-rle5", counts: [100, 1, 1, 1, 1, 1],
			normalized: [3936, 32, 32, 32, 32, 32], sourceDerivedOmitPosition: 0,
			headerBits: 22,
			bytes: [152, 96, 16], decisions: [.omission, .generalSerialization]),
		.init(
			name: "public-omit-splits-run", counts: [1, 1, 100, 1, 1, 1, 1, 1],
			normalized: [32, 32, 3872, 32, 32, 32, 32, 32],
			sourceDerivedOmitPosition: 2,
			headerBits: 29, bytes: [168, 72, 48, 8],
			decisions: [.omission, .generalSerialization]),
	]

	static func proves(_ reference: DecisionInventory.FixtureReference, decision: String)
		-> Bool
	{
		all.contains {
			$0.reference == "\(reference.path)#\(reference.category ?? "")"
				&& $0.decisions.contains { $0.rawValue == decision }
		}
	}
}
