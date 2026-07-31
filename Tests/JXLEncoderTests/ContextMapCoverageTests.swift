import Testing

@testable import JXLEncoder

/// The decoder's `VerifyContextMap` requires every prefix code to be *reachable*:
/// each index in `0 ..< numHistograms` has to appear at least once in the
/// transmitted map, or it rejects the stream as "Incomplete context map."
///
/// Counting codes is not enough — an earlier check compared the map's maximum
/// against the code count and passed, because the failure is about coverage
/// rather than range.
///
/// This bites the re-clustered codes specifically. `SectionOptimizer` clusters
/// over the *mapped* context space, so what the decoder sees is the composition
/// of two maps, and a cluster reachable in the inner map can be unreachable
/// through the pair.
@Suite("Context map coverage")
struct ContextMapCoverageTests {
	/// The decoder's check, as written.
	static func verify(_ map: [UInt8], histograms: Int) -> Bool {
		var seen = Set<Int>()
		for entry in map {
			guard Int(entry) < histograms else { return false }
			seen.insert(Int(entry))
		}
		return seen.count == histograms
	}

	/// What `EntropyCodeWriter.writeContextMap` transmits.
	static func transmitted(_ code: EntropyCode) -> [UInt8] {
		if let original = code.originalContextMap {
			return original.map { code.contextMap[Int($0)] }
		}
		return code.contextMap
	}

	@Test("the decoder's rule rejects an unreachable histogram")
	func ruleItself() {
		#expect(Self.verify([0, 1, 2], histograms: 3))
		#expect(!Self.verify([0, 0, 2], histograms: 3), "index 1 never appears")
		#expect(!Self.verify([0, 1], histograms: 3))
	}

	/// Re-clustering a code whose buckets are only partly used. Buckets with no
	/// tokens are what a subsampled image produces: the chroma planes are a
	/// quarter the size, so whole swathes of the context space go untouched.
	@Test(
		"a re-clustered code stays reachable when buckets go unused",
		arguments: [1, 2, 3, 5, 8], [EntropyCode.staticDC, EntropyCode.staticAC])
	func reclusteredCoverage(usedBuckets: Int, base: EntropyCode) {
		let bucketCount = base.prefixCodeCount

		// Only the first `usedBuckets` buckets see any tokens.
		var histograms = [Histogram](repeating: Histogram(), count: bucketCount)
		for bucket in 0..<min(usedBuckets, bucketCount) {
			for symbol in 0..<(bucket + 2) {
				for _ in 0..<(10 * (bucket + 1)) {
					histograms[bucket].add(UInt32(symbol))
				}
			}
		}

		let (clusters, contextMap) = HistogramCluster.cluster(histograms)
		let code = EntropyCode(
			contextMap: contextMap,
			prefixCodes: HistogramCluster.buildPrefixCodes(clusters),
			originalContextMap: base.contextMap)

		let map = Self.transmitted(code)
		#expect(map.count == base.contextMap.count)
		let detail =
			"\(code.prefixCodeCount) codes but the transmitted map "
			+ "reaches \(Set(map).count): every code must be referenced"
		#expect(Self.verify(map, histograms: code.prefixCodeCount), "\(detail)")
	}
}
