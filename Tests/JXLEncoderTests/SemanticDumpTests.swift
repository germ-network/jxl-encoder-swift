import Foundation
import Testing

/// The semantic dump is the contract between the reference harness and these
/// tests: integers compare exactly, floats within a documented per-field
/// tolerance, and any added, missing or reshaped field is a difference.
@Suite("Semantic dump format")
struct SemanticDumpTests {
	@Test("serializing then parsing gives an equal dump, independent of record order")
	func roundTrips() throws {
		var dump = SemanticDump()
		dump.record("z.empty", .integers([]))
		dump.record(
			"a.float",
			.floats([
				0, -0.0, 1.2345678, Float.leastNonzeroMagnitude,
				Float.greatestFiniteMagnitude,
			]))
		dump.record("a.int", .integers([Int64.min, 0, Int64.max]))
		#expect(try SemanticDump(parsing: dump.serialized) == dump)
		let parsed = try SemanticDump(parsing: dump.serialized)
		if case .floats(let values) = parsed.fields["a.float"] {
			#expect(values[0].bitPattern == Float(0).bitPattern)
			#expect(values[1].bitPattern == Float(-0.0).bitPattern)
		} else {
			Issue.record("missing float field")
		}
		#expect(
			try SemanticDump(parsing: "jxl-semantic-dump 1\nz.b i 0\na.b i 1 2").fields
				== ["z.b": .integers([]), "a.b": .integers([2])])
		#expect(dump.serialized.hasPrefix("jxl-semantic-dump 1\na.float "))
	}

	@Test(
		"the harness writer's golden output parses to the expected dump",
		.enabled(if: PackageCheckout.isAvailable))
	func parsesHarnessGolden() throws {
		let text = try PackageCheckout.read("Reference/harness/golden.sem")
		let dump = try SemanticDump(parsing: text)
		#expect(
			dump.fields == [
				"coeff_order.test": .integers([0, 1, 3, 2]),
				"frame.size": .integers([3, 2]),
				"quant_field.test": .floats([-0.0, 1.2345678, -2, 0]),
			])
		if case .floats(let values) = dump.fields["quant_field.test"] {
			#expect(values[0].bitPattern == Float(-0.0).bitPattern)
			#expect(values[1].bitPattern == Float(1.2345678).bitPattern)
		} else {
			Issue.record("missing float field")
		}
	}

	@Test("a bad header, malformed line, duplicate field or unparsable value throws")
	func rejectsMalformedText() throws {
		let invalid = [
			"", "jxl-semantic-dump 2\n", "jxl-semantic-dump 1\r\n",
			"jxl-semantic-dump 1\nx i 0\n", "jxl-semantic-dump 1\na..b i 0\n",
			"jxl-semantic-dump 1\na.b x 0\n", "jxl-semantic-dump 1\na.b i -1\n",
			"jxl-semantic-dump 1\na.b i 2 1\n", "jxl-semantic-dump 1\na.b i 1 x\n",
			"jxl-semantic-dump 1\na.b i 1 9223372036854775808\n",
			"jxl-semantic-dump 1\na.b f 1 0x1p0\n",
			"jxl-semantic-dump 1\na.b f 1 nan\n", "jxl-semantic-dump 1\na.b f 1 inf\n",
			"jxl-semantic-dump 1\na.b  i 0\n",
			"jxl-semantic-dump 1\na.b i 0\na.b i 0\n",
		]
		for text in invalid {
			#expect(throws: (any Error).self) { try SemanticDump(parsing: text) }
		}
	}

	@Test("integer fields compare exactly")
	func integersExact() throws {
		let reference = try SemanticDump(
			parsing: "jxl-semantic-dump 1\na.b i 3 -1 0 9223372036854775807\n")
		#expect(reference.differences(from: reference).isEmpty)
		let actual = try SemanticDump(
			parsing: "jxl-semantic-dump 1\na.b i 3 -1 1 9223372036854775806\n")
		#expect(
			actual.differences(from: reference) == [
				SemanticDifference(
					field: "a.b",
					kind: .valueMismatch(index: 1, expected: "0", actual: "1"))
			])
	}

	@Test("float fields compare within their tolerance, and fail just outside it")
	func floatsWithinTolerance() throws {
		func differences(_ actual: Float, _ expected: Float, _ tolerance: FloatTolerance)
			-> [SemanticDifference]
		{
			var a = SemanticDump()
			var b = SemanticDump()
			a.record("a.f", .floats([actual]))
			b.record("a.f", .floats([expected]))
			return a.differences(from: b, tolerances: ["a.f": tolerance])
		}
		#expect(differences(Float(1).nextUp, 1, .ulps(1)).isEmpty)
		#expect(!differences(Float(1).nextUp.nextUp, 1, .ulps(1)).isEmpty)
		#expect(differences(Float(-1).nextDown, -1, .ulps(1)).isEmpty)
		#expect(!differences(Float(-1).nextDown.nextDown, -1, .ulps(1)).isEmpty)
		#expect(!differences(-0.0, 0, .ulps(0)).isEmpty)
		#expect(differences(-0.0, 0, .ulps(1)).isEmpty)
		#expect(differences(1.25, 1, .absolute(0.25)).isEmpty)
		#expect(!differences(Float(1.25).nextUp, 1, .absolute(0.25)).isEmpty)
		#expect(!differences(.infinity, .infinity, .ulps(0)).isEmpty)
		#expect(!differences(.nan, 0, .absolute(1)).isEmpty)
	}

	@Test("a float field without a documented tolerance is reported, not compared")
	func floatWithoutToleranceReported() throws {
		var dump = SemanticDump()
		dump.record("a.f", .floats([1]))
		#expect(
			dump.differences(from: dump) == [
				SemanticDifference(field: "a.f", kind: .noTolerance)
			])
	}

	@Test("missing, unexpected, kind and count differences are each reported")
	func structuralDifferences() throws {
		var a = SemanticDump()
		var b = SemanticDump()
		a.record("a.extra", .integers([]))
		b.record("a.missing", .integers([]))
		a.record("a.kind", .floats([]))
		b.record("a.kind", .integers([]))
		a.record("a.floatcount", .floats([1]))
		b.record("a.floatcount", .floats([]))
		a.record("a.count", .integers([1]))
		b.record("a.count", .integers([]))
		#expect(
			a.differences(from: b) == [
				SemanticDifference(
					field: "a.count",
					kind: .countMismatch(expected: 0, actual: 1)),
				SemanticDifference(field: "a.extra", kind: .unexpected),
				SemanticDifference(
					field: "a.floatcount",
					kind: .countMismatch(expected: 0, actual: 1)),
				SemanticDifference(field: "a.kind", kind: .kindMismatch),
				SemanticDifference(field: "a.missing", kind: .missing),
			])
	}

	@Test("one flipped entry in a long integer field is caught")
	func singleFlipCaught() throws {
		var reference = SemanticDump()
		var actual = SemanticDump()
		let values = Array(repeating: Int64(7), count: 4096)
		var changed = values
		changed[2049] = 8
		reference.record("context_map.ac", .integers(values))
		actual.record("context_map.ac", .integers(changed))
		#expect(
			actual.differences(from: reference) == [
				SemanticDifference(
					field: "context_map.ac",
					kind: .valueMismatch(
						index: 2049, expected: "7", actual: "8"))
			])
	}

	@Test("restricting to categories keeps exactly those fields")
	func restrictsByCategory() throws {
		var dump = SemanticDump()
		dump.record("frame.size", .integers([32, 32]))
		dump.record("frame_extra.size", .integers([1]))
		dump.record("coeff_order.dct8.c1", .integers([0, 1]))
		#expect(
			dump.restricted(to: ["frame"]).fields == [
				"frame.size": .integers([32, 32])
			])
		#expect(dump.restricted(to: []).fields.isEmpty)
		#expect(dump.restricted(to: ["frame", "frame_extra", "coeff_order"]) == dump)
	}

	@Test("every documented tolerance names a float field some committed fixture carries")
	func documentedTolerancesAreUsed() throws {
		var fixtureNames = SemanticCorpusEntry.all.map(\.name)
		fixtureNames.append("distance_params")
		var dumps: [SemanticDump] = []
		for fixtureName in fixtureNames {
			dumps.append(try SemanticDump(fixture: fixtureName))
		}
		for name in FloatTolerance.documented.keys {
			#expect(
				dumps.contains {
					if case .floats? = $0.fields[name] { return true }
					return false
				})
		}
	}
}
