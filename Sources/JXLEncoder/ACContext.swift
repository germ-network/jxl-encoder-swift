//
//  ACContext.swift
//  JXLEncoder
//
//  Port of libjxl-tiny's encoder/ac_context.h: the context model that selects
//  which prefix code encodes each AC coefficient.
//
//  Contexts are derived from how many non-zero coefficients remain and where in
//  scan order the coefficient sits, clustered so the model stays small enough
//  to be worth signalling.
//

public enum ACContext {
	/// Predicted non-zero counts run 0...1008 and are bucketed by
	/// ceil(log2(predicted + 1)).
	public static let nonZeroBuckets = 37
	/// Supremum of `zeroDensityContext` + 1 given the encoder's invariant that
	/// non-zeros remaining plus scan position stays under 64.
	public static let zeroDensityCount = 458
	/// Supremum with no such constraint. Larger than the count above, so the
	/// invariant is what keeps the context map correctly sized.
	public static let zeroDensityLimit = 474
	public static let numBlockCategories = 4
	public static let numAcStrategyCodes = 27

	public static let totalCount =
		numBlockCategories * (nonZeroBuckets + zeroDensityCount)

	/// 0xBAD marks the DC slot, which never reaches this table.
	static let coeffFreqIndex: [UInt16] = [
		0xBAD, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
		15, 15, 16, 16, 17, 17, 18, 18, 19, 19, 20, 20, 21, 21, 22, 22,
		23, 23, 23, 23, 24, 24, 24, 24, 25, 25, 25, 25, 26, 26, 26, 26,
		27, 27, 27, 27, 28, 28, 28, 28, 29, 29, 29, 29, 30, 30, 30, 30,
	]

	static let coeffNumNonzeroIndex: [UInt16] = [
		0xBAD, 0, 31, 62, 62, 93, 93, 93, 93, 123, 123, 123, 123,
		152, 152, 152, 152, 152, 152, 152, 152, 180, 180, 180, 180, 180,
		180, 180, 180, 180, 180, 180, 180, 206, 206, 206, 206, 206, 206,
		206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206,
		206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206,
	]

	static let compactBlockIndexMap: [UInt8] = [
		0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1,
		2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3, 3, 3,
		2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3, 3, 3,
	]

	static let blockIndexMap: [UInt8] = [
		2, 0, 0, 0, 0, 0, 3, 3, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0,
		0, 0, 0, 0, 3, 3, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	]

	public static func blockContext(channel: Int, acStrategyCode: Int) -> Int {
		Int(blockIndexMap[channel * numAcStrategyCodes + acStrategyCode])
	}

	/// Clusters (nonzerosLeft, k) into a manageable number of buckets; keeping
	/// every combination would need 2016 of them before block context is even
	/// considered.
	public static func zeroDensityContext(
		nonzerosLeft: Int, k: Int, coveredBlocks: Int, log2CoveredBlocks: Int, previous: Int
	) -> Int {
		let nonzeros = (nonzerosLeft + coveredBlocks - 1) >> log2CoveredBlocks
		let index = k >> log2CoveredBlocks
		return (Int(coeffNumNonzeroIndex[nonzeros]) + Int(coeffFreqIndex[index])) * 2
			+ previous
	}

	/// `numCategories` defaults to the pixel path's fixed category count; the
	/// JPEG-transcode adaptive block-context-map path passes its own
	/// per-image category count instead of duplicating this formula.
	public static func zeroDensityContextsOffset(
		blockContext: Int, numCategories: Int = numBlockCategories
	) -> Int {
		numCategories * nonZeroBuckets + zeroDensityCount * blockContext
	}

	/// Groups contexts with the same non-zero count together, which clusters
	/// better than interleaving them with block context.
	public static func nonZeroContext(
		nonZeros: Int, blockContext: Int, numCategories: Int = numBlockCategories
	) -> Int {
		let bucket = nonZeros < 8 ? nonZeros : (nonZeros >= 64 ? 36 : 4 + nonZeros / 2)
		return bucket * numCategories + blockContext
	}
}
