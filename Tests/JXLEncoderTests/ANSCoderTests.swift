//
//  ANSCoderTests.swift
//  JXLEncoderTests
//
//  Hand-computed cases for the alias table construction, in isolation,
//  before it is wired into any encoder path — same discipline as
//  JPEGBlockContextMapTests. See docs/gap-closure-plan.md, Phase B.
//

import Testing

@testable import JXLEncoder

@Suite("ANS alias table")
struct ANSCoderTests {
	@Test("a single dominant symbol produces the identity reverse map")
	func singleSymbol() {
		// distribution = [4096], logAlphaSize = 2 (tableSize 4, entrySize 1024).
		let table = ANSAliasTable.build(distribution: [4096], logAlphaSize: 2)
		#expect(table.count == 4)
		for i in 0..<4 {
			#expect(table[i].rightValue == 0)
			#expect(table[i].cutoff == 0)
			#expect(table[i].offsets1 == 1024 * i)
		}

		let info = ANSInfoTable.build(distribution: [4096], alphabetSize: 1, logAlphaSize: 2)
		#expect(info.count == 1)
		#expect(info[0].freq == 4096)
		#expect(info[0].reverseMap == (0..<4096).map { UInt16($0) })
	}

	@Test("an exact even split needs no rebalancing")
	func evenSplitNoRebalance() {
		// distribution = [2048, 2048], logAlphaSize = 1 (tableSize 2, entrySize 2048):
		// both cutoffs already equal entrySize, so neither is over/underfull.
		let table = ANSAliasTable.build(distribution: [2048, 2048], logAlphaSize: 1)
		#expect(table.count == 2)
		#expect(table[0].rightValue == 0 && table[0].cutoff == 0 && table[0].offsets1 == 0)
		#expect(table[1].rightValue == 1 && table[1].cutoff == 0 && table[1].offsets1 == 0)
	}

	@Test("a 75/25 split rebalances by moving exactly the overfull amount")
	func rebalancedSplit() {
		// distribution = [3072, 1024], logAlphaSize = 1 (entrySize 2048).
		// Symbol 0 is overfull by 1024, symbol 1 underfull by 1024 — traced by
		// hand: table[0] = {right:0, cutoff:0, off1:0} (already exactly full),
		// table[1] = {right:0, cutoff:1024, off1:1024} (1024 of symbol 1, then
		// 1024 more of symbol 0 borrowed from its overfull share).
		let table = ANSAliasTable.build(distribution: [3072, 1024], logAlphaSize: 1)
		#expect(table.count == 2)
		#expect(table[0].rightValue == 0 && table[0].cutoff == 0 && table[0].offsets1 == 0)
		#expect(table[1].rightValue == 0 && table[1].cutoff == 1024 && table[1].offsets1 == 1024)

		let info = ANSInfoTable.build(
			distribution: [3072, 1024], alphabetSize: 2, logAlphaSize: 1)
		#expect(info[0].freq == 3072)
		#expect(info[1].freq == 1024)
		// Symbol 0 owns table-index-0's whole entry (global slots 0..2047,
		// local offsets 0..2047) plus table-index-1's "greater" sub-range
		// (global slots 3072..4095, continuing at local offsets 2048..3071).
		#expect(info[0].reverseMap[0] == 0)
		#expect(info[0].reverseMap[2047] == 2047)
		#expect(info[0].reverseMap[2048] == 3072)
		#expect(info[0].reverseMap[3071] == 4095)
		// Symbol 1 owns table-index-1's "not greater" sub-range (global slots
		// 2048..3071, local offsets 0..1023).
		#expect(info[1].reverseMap[0] == 2048)
		#expect(info[1].reverseMap[1023] == 3071)
	}

	@Test("every reverse-map slot is assigned exactly once across all symbols")
	func reverseMapPartitionsCompletely() {
		let distribution = [1500, 900, 800, 500, 396]  // sums to 4096
		let alphabetSize = distribution.count
		let logAlphaSize = 3  // tableSize 8 >= alphabetSize
		let info = ANSInfoTable.build(
			distribution: distribution, alphabetSize: alphabetSize, logAlphaSize: logAlphaSize)
		var seen = [Bool](repeating: false, count: ANSConstants.tabSize)
		for symbolInfo in info {
			#expect(symbolInfo.reverseMap.count == symbolInfo.freq)
			for slot in symbolInfo.reverseMap {
				#expect(!seen[Int(slot)], "slot \(slot) assigned more than once")
				seen[Int(slot)] = true
			}
		}
		#expect(seen.allSatisfy { $0 }, "every table slot must be assigned to some symbol")
	}

}
