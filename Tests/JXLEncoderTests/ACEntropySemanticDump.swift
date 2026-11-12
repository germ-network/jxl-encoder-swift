@testable import JXLEncoder

enum ACEntropyCaptureError: Error, Equatable {
	case invalidTableCount
	case invalidContextMap
	case invalidANSTable(Int)
	case invalidPrefixTable(Int)
	case duplicateField(String)
}

extension SemanticDump {
	mutating func recordACEntropyCode(_ code: EntropyCode) throws {
		let tableCount: Int
		if let ansTables = code.ansInfoTables {
			tableCount = ansTables.count
		} else {
			tableCount = code.prefixCodes.count
		}
		guard tableCount > 0 else { throw ACEntropyCaptureError.invalidTableCount }

		guard code.contextMap.allSatisfy({ Int($0) < tableCount }),
			(code.originalContextMap ?? []).allSatisfy({
				Int($0) < code.contextMap.count
			})
		else { throw ACEntropyCaptureError.invalidContextMap }

		var fields: [String: SemanticDump.Values] = [
			"ac_entropy.kind": .integers([code.ansInfoTables == nil ? 0 : 1]),
			"ac_entropy.table_count": .integers([Int64(tableCount)]),
			"ac_entropy.uint_config": .integers(
				Array(repeating: [4, 2, 0].map(Int64.init), count: tableCount)
					.flatMap { $0 }),
			"ac_entropy.lz77_enabled": .integers([0]),
			"ac_entropy_alphabet.ans_log_alpha_size": .integers(
				code.ansInfoTables == nil ? [] : [6]),
		]

		if let ansTables = code.ansInfoTables {
			var lengths: [Int64] = []
			var frequencies: [Int64] = []
			for (index, table) in ansTables.enumerated() {
				let freq = table.map(\.freq)
				guard freq.allSatisfy({ (0...4096).contains($0) }),
					freq.reduce(0, +) == 4096,
					table.allSatisfy({ $0.reverseMap.count == $0.freq })
				else { throw ACEntropyCaptureError.invalidANSTable(index) }
				let length = freq.lastIndex(where: { $0 != 0 }).map { $0 + 1 } ?? 0
				lengths.append(Int64(length))
				frequencies.append(contentsOf: freq.prefix(length).map(Int64.init))
			}
			fields["ac_entropy.ans.alphabet_lengths"] = .integers(lengths)
			fields["ac_entropy.ans.frequencies"] = .integers(frequencies)
		} else {
			var lengths: [Int64] = []
			var singletons: [Int64] = []
			var depths: [Int64] = []
			for (index, table) in code.prefixCodes.enumerated() {
				guard table.depths.count == 64, table.bits.count == 64,
					table.depths.allSatisfy({ $0 <= 15 })
				else { throw ACEntropyCaptureError.invalidPrefixTable(index) }
				let nonzero = table.depths.indices.filter { table.depths[$0] != 0 }
				let singleton = nonzero.count <= 1
				let symbol = nonzero.first ?? 0
				let length =
					singleton
					? symbol + 1
					: (table.depths.lastIndex(where: { $0 != 0 })! + 1)
				lengths.append(Int64(length))
				singletons.append(singleton ? Int64(symbol) : -1)
				if singleton {
					depths.append(contentsOf: repeatElement(0, count: length))
				} else {
					depths.append(
						contentsOf: table.depths.prefix(length).map(
							Int64.init))
				}
			}
			fields["ac_entropy.prefix.alphabet_lengths"] = .integers(lengths)
			fields["ac_entropy.prefix.singleton_symbols"] = .integers(singletons)
			fields["ac_entropy.prefix.depths"] = .integers(depths)
		}

		for name in fields.keys.sorted() where self.fields[name] != nil {
			throw ACEntropyCaptureError.duplicateField(name)
		}
		for (name, value) in fields { record(name, value) }
	}
}
