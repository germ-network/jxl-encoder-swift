import Foundation

/// The encoder decisions a JPEG XL codestream carries, as named integer and
/// float fields. `Reference/semantic-dump.md` is the format and the comparison
/// rules this type implements.
///
/// The reference harness writes one by decoding any codestream (cjxl's or this
/// package's); the tests write one from the Swift encoder's own decisions. Two
/// dumps agree when every integer field is equal and every float field is
/// within its documented tolerance, so a changed decision is caught even when
/// the file still decodes and its size is unchanged.
struct SemanticDump: Equatable {
	enum Values: Equatable {
		case integers([Int64])
		case floats([Float])
	}

	/// Field name to values, e.g. `coeff_order.dct8.c1`. Names are
	/// `<category>.<field>[.<qualifier>…]`; the category is the harness
	/// dumper that owns the field.
	private(set) var fields: [String: Values] = [:]

	init() {}

	/// Parses the text form. Throws on a bad header, a malformed line, a
	/// duplicate field, or a value that doesn't parse as its declared kind.
	init(parsing text: String) throws {
		throw SemanticDumpError.unimplemented
	}

	init(fixture name: String) throws {
		guard
			let url = Bundle.module.url(
				forResource: name, withExtension: "sem",
				subdirectory: "Fixtures/semantic")
		else {
			throw SemanticDumpError.fixtureNotFound(name)
		}
		try self.init(parsing: String(contentsOf: url, encoding: .utf8))
	}

	/// Adds a field; a name already present is a programming error.
	mutating func record(_ name: String, _ values: Values) {
		precondition(fields[name] == nil, "field \(name) recorded twice")
		fields[name] = values
	}

	/// The text form, fields sorted by name so equal dumps serialize equally.
	var serialized: String {
		""
	}

	/// Every way `self` departs from `reference` under `tolerances`. Empty means
	/// the two agree. A float field without a tolerance entry is reported
	/// rather than compared, so every float comparison is a documented one.
	func differences(
		from reference: SemanticDump,
		tolerances: [String: FloatTolerance] = FloatTolerance.documented
	) -> [SemanticDifference] {
		[]
	}

	/// Only the fields whose category is in `categories`, so a test can compare
	/// the categories the Swift side emits against a full reference dump.
	func restricted(to categories: Set<String>) -> SemanticDump {
		self
	}
}

/// How far a float field may move before it counts as a changed decision.
enum FloatTolerance: Equatable {
	/// At most this many representable floats apart; 0 is bit-identical.
	case ulps(Int)
	/// At most this far apart in absolute value.
	case absolute(Float)

	/// The per-field table `Reference/semantic-dump.md` documents. Keys are
	/// full field names.
	static let documented: [String: FloatTolerance] = [:]
}

struct SemanticDifference: Equatable, CustomStringConvertible {
	enum Kind: Equatable {
		/// In the reference, not in the compared dump.
		case missing
		/// In the compared dump, not in the reference.
		case unexpected
		/// Integer in one, float in the other.
		case kindMismatch
		case countMismatch(expected: Int, actual: Int)
		/// First differing element only; `expected`/`actual` as written in the
		/// text form.
		case valueMismatch(index: Int, expected: String, actual: String)
		/// A float field with no `FloatTolerance` entry.
		case noTolerance
	}

	let field: String
	let kind: Kind

	var description: String { "\(field): \(kind)" }
}

enum SemanticDumpError: Error, Equatable {
	case fixtureNotFound(String)
	case badHeader(String)
	case malformedLine(line: Int, reason: String)
	case duplicateField(String)
	case unimplemented
}
