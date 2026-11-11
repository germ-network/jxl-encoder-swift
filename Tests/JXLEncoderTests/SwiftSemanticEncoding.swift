import Foundation

@testable import JXLEncoder

/// The decisions the optimized pixel path (`Encoder.encodeFrame` with
/// `optimizeCodes: true`) makes for one frame, captured so they can be dumped
/// and, in mutation tests, altered before the frame is written.
struct SwiftFrameDecisions {
	let width: Int
	let height: Int
	let params: DistanceParams
	var coeffOrder: CoeffOrder.Result
	var acCode: EntropyCode
	/// No lane-A category reads it; the entropy categories will.
	var dcCode: EntropyCode
	/// Per AC group, in group raster order: the raw quant field the group
	/// wrote, block-major.
	var quantFields: [[UInt8]]
}

/// Re-runs `Encoder.encodeFrame`'s optimized composition from the same
/// internal steps, so the Swift side can report the decisions it made.
///
/// Must stay byte-identical to `Encoder.encode` / `Encoder.encodeFrame` when
/// nothing is altered; a test pins that, so this copy can't drift from the
/// encoder it describes.
enum SwiftSemanticEncoding {
	struct Result {
		let codestream: [UInt8]
		let decisions: SwiftFrameDecisions
	}

	/// Where a mutation test may alter a decision, after it's computed and
	/// before anything that depends on it is written. Each alteration must leave
	/// a codestream that still decodes.
	struct Alterations: Sendable {
		/// Before AC tokenization, so tokens and the signalled order agree.
		var coeffOrder: @Sendable (inout CoeffOrder.Result) -> Void = { _ in }
		/// After the AC code is optimized, before the AC global section is
		/// written. The AC groups are already written with the unaltered code
		/// by then, so only a context that carries no tokens may be remapped,
		/// and only to a cluster other contexts still use.
		var acCode: @Sendable (inout EntropyCode) -> Void = { _ in }

		static let none = Alterations()
	}

	/// 8-bit sRGB input, the production path (`Encoder.encode`).
	static func encode(
		_ image: ImageBuffer, distance: Float, altering: Alterations = .none
	) throws -> Result {
		throw SemanticDumpError.unimplemented
	}

	/// Pre-linearized float input with a linear transfer function, the path the
	/// stage-dump tests use (`EncoderTests.encodeMatchingReference`, but optimized).
	static func encode(
		linear: StageDump, distance: Float, altering: Alterations = .none
	) throws -> Result {
		throw SemanticDumpError.unimplemented
	}
}

extension SemanticDump {
	/// The harness categories the Swift side emits from its own decisions.
	/// Lanes that add a category add it here alongside its emitter.
	static let swiftEmittedCategories: Set<String> = [
		"frame", "coeff_order", "block_context", "context_map", "quant_field",
	]

	/// The dump of `decisions` in exactly the field names and layout the
	/// harness's decoder-side dumpers write for the same categories.
	init(swiftDecisions decisions: SwiftFrameDecisions) {
		self.init()
	}
}
