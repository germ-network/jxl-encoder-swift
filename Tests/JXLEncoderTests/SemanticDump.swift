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
		let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
		guard lines.first == "jxl-semantic-dump 1" else {
			throw SemanticDumpError.badHeader(String(lines.first ?? ""))
		}
		for (offset, line) in lines.dropFirst().enumerated() {
			if line.isEmpty && offset == lines.count - 2 { continue }
			let parts = line.split(separator: " ", omittingEmptySubsequences: false)
			func malformed(_ reason: String) -> SemanticDumpError {
				.malformedLine(line: offset + 2, reason: reason)
			}
			guard parts.count >= 3, !parts.contains(where: { $0.isEmpty }) else {
				throw malformed("field syntax")
			}
			let name = String(parts[0])
			let components = name.split(
				separator: ".", omittingEmptySubsequences: false)
			guard components.count >= 2, !components.contains(where: { $0.isEmpty }),
				name.utf8.allSatisfy({
					(97...122).contains($0) || (48...57).contains($0)
						|| $0 == 95 || $0 == 46
				})
			else { throw malformed("field name") }
			guard let count = Int(parts[2]), count >= 0, count == parts.count - 3 else {
				throw malformed("count")
			}
			guard fields[name] == nil else {
				throw SemanticDumpError.duplicateField(name)
			}
			let values = parts.dropFirst(3)
			switch parts[1] {
			case "i":
				let parsed = values.compactMap { Int64($0) }
				guard parsed.count == count else { throw malformed("integer") }
				fields[name] = .integers(parsed)
			case "f":
				guard
					values.allSatisfy({
						$0.range(
							of:
								#"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#,
							options: .regularExpression) != nil
					})
				else { throw malformed("decimal float") }
				let parsed = values.compactMap { Float($0) }
				guard parsed.count == count, parsed.allSatisfy({ $0.isFinite })
				else { throw malformed("float") }
				fields[name] = .floats(parsed)
			default: throw malformed("kind")
			}
		}
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
		var lines = ["jxl-semantic-dump 1"]
		for name in fields.keys.sorted() {
			let kind: String
			let values: [String]
			switch fields[name]! {
			case .integers(let items):
				kind = "i"
				values = items.map { String($0) }
			case .floats(let items):
				kind = "f"
				values = items.map { String($0) }
			}
			lines.append(
				([name, kind, String(values.count)] + values).joined(separator: " ")
			)
		}
		return lines.joined(separator: "\n") + "\n"
	}

	/// Every way `self` departs from `reference` under `tolerances`. Empty means
	/// the two agree. A float field without a tolerance entry is reported
	/// rather than compared, so every float comparison is a documented one.
	func differences(
		from reference: SemanticDump,
		tolerances: [String: FloatTolerance] = FloatTolerance.documented
	) -> [SemanticDifference] {
		var result: [SemanticDifference] = []
		for name in Set(fields.keys).union(reference.fields.keys).sorted() {
			func add(_ kind: SemanticDifference.Kind) {
				result.append(SemanticDifference(field: name, kind: kind))
			}
			guard let expected = reference.fields[name] else {
				add(.unexpected)
				continue
			}
			guard let actual = fields[name] else {
				add(.missing)
				continue
			}
			switch (actual, expected) {
			case (.integers(let a), .integers(let b)):
				guard a.count == b.count else {
					add(.countMismatch(expected: b.count, actual: a.count))
					continue
				}
				if let index = a.indices.first(where: { a[$0] != b[$0] }) {
					add(
						.valueMismatch(
							index: index, expected: String(b[index]),
							actual: String(a[index])))
				}
			case (.floats(let a), .floats(let b)):
				guard a.count == b.count else {
					add(.countMismatch(expected: b.count, actual: a.count))
					continue
				}
				guard let tolerance = tolerances[name] else {
					add(.noTolerance)
					continue
				}
				if let index = a.indices.first(where: {
					!tolerance.contains(a[$0], b[$0])
				}) {
					add(
						.valueMismatch(
							index: index, expected: String(b[index]),
							actual: String(a[index])))
				}
			default: add(.kindMismatch)
			}
		}
		return result
	}

	/// Only the fields whose category is in `categories`, so a test can compare
	/// the categories the Swift side emits against a full reference dump.
	func restricted(to categories: Set<String>) -> SemanticDump {
		var result = SemanticDump()
		result.fields = fields.filter {
			categories.contains(String($0.key.split(separator: ".")[0]))
		}
		return result
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

	func contains(_ a: Float, _ b: Float) -> Bool {
		guard a.isFinite, b.isFinite else { return false }
		switch self {
		case .absolute(let limit): return limit >= 0 && abs(a - b) <= limit
		case .ulps(let limit):
			// Monotonic keys preserve signed zero as distinct adjacent values.
			func ordered(_ value: Float) -> Int64 {
				let bits = value.bitPattern
				return Int64(bits & 0x8000_0000 == 0 ? bits | 0x8000_0000 : ~bits)
			}
			return limit >= 0 && abs(ordered(a) - ordered(b)) <= Int64(limit)
		}
	}
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
	case malformedEntropyFixture(name: String, field: String)
	case unsupportedEntropyFixture(String)
	case unimplemented
}
