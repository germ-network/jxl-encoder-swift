//
//  LZ77.swift
//  JXLEncoder
//
//  Backward references over a token stream, ported from libjxl enc_lz77.cc
//  (`ApplyLZ77` and its RLE, greedy hash-chain and optimal-parse variants).
//  A length token carries `minSymbol` + the hybrid-uint length symbol; the
//  distance that follows goes in an extra context after the stream's own.
//

enum LZ77 {
	/// `HistogramParams::LZ77Method` (enc_ans_params.h), less `kNone`, which no
	/// caller of the histogram builder selects.
	enum Method: Equatable, Sendable {
		/// Repeat-previous runs only (`ApplyLZ77_RLE`).
		case rle
		/// Greedy hash-chain matching (`ApplyLZ77_LZ77`).
		case lz77
		/// Cost-driven parse seeded by the greedy result (`ApplyLZ77_Optimal`).
		case optimal
	}

	/// libjxl never changes `LZ77Params::min_length` from its default
	/// (dec_ans.cc:313-314).
	static let minLength: UInt32 = 3

	/// The length symbols' uint configuration, written with log alpha 8
	/// (enc_ans.cc:1107-1113).
	static let lengthConfiguration = HybridUintConfiguration(
		splitExponent: 0, msbInToken: 0, lsbInToken: 0)

	/// The serialized `LZ77Params` of an enabled stream (dec_ans.cc:304-315)
	/// plus the distance context, which libjxl keeps unserialized.
	struct Parameters: Equatable, Sendable {
		/// 224, or 512 under forced prefix codes (enc_ans.cc:1090).
		let minSymbol: UInt32
		/// The stream's context count: distances follow every original context.
		let distanceContext: Int
	}

	/// A token after LZ77: a literal, a length, or the distance after a length.
	struct EncodedToken: Equatable, Sendable {
		let token: Token
		let isLength: Bool
	}

	struct Result {
		/// Nil when LZ77 did not pay for itself.
		let parameters: Parameters?
		/// Literals only, in input order, when `parameters` is nil.
		let tokens: [EncodedToken]
	}

	/// Replaces repeats with length/distance pairs by `parameters.lz77Method`.
	/// RLE and greedy keep the result only when it saves more than 0.2 bits
	/// per token plus 16 (enc_lz77.cc:165, :540); the optimal parse runs only
	/// when the greedy pass met that bar (enc_lz77.cc:550-553). Either way a
	/// decoder expanding the result recovers `tokens`. Ports `ApplyLZ77`
	/// (enc_lz77.cc:684-697).
	static func apply(
		_ tokens: [Token], contextCount: Int, parameters: HistogramParameters
	) -> Result {
		precondition(
			contextCount > 0 && tokens.allSatisfy { Int($0.context) < contextCount })
		let lz77 = Parameters(
			minSymbol: parameters.lz77MinSymbol, distanceContext: contextCount)
		let literals = tokens.map { EncodedToken(token: $0, isLength: false) }
		let costs = SymbolCosts(
			literals, contextCount: contextCount, lz77: lz77,
			forcesPrefixCodes: parameters.forcesPrefixCodes)
		let transformed: [EncodedToken]? =
			switch parameters.lz77Method {
			case .rle: rle(tokens, lz77: lz77, costs: costs)
			case .lz77: greedy(tokens, lz77: lz77, costs: costs)
			case .optimal:
				greedy(tokens, lz77: lz77, costs: costs).map {
					optimal(
						tokens, lz77: lz77,
						costs: SymbolCosts(
							$0, contextCount: contextCount + 1,
							lz77: lz77,
							forcesPrefixCodes: parameters
								.forcesPrefixCodes))
				}
			}
		guard let transformed else {
			return Result(parameters: nil, tokens: literals)
		}
		return Result(parameters: lz77, tokens: transformed)
	}

	private static func savesEnough(_ bitDecrease: Float, tokenCount: Int) -> Bool {
		Double(bitDecrease) > Double(tokenCount) * 0.2 + 16
	}

	private static let literalConfiguration = HybridUintConfiguration(
		splitExponent: 4, msbInToken: 2, lsbInToken: 0)

	/// `SymbolCostEstimator` (enc_lz77.cc:28-95).
	private struct SymbolCosts {
		let lz77: Parameters
		/// One row per context, each as wide as the widest context's
		/// histogram; like the source, a symbol past its own row's histogram
		/// reads 0 and one past the row width reads the next row.
		let rowWidth: Int
		let bits: [Float]
		/// `AddSymbolCost`: the greedy parse's penalty per context.
		let addSymbolCosts: [Float]

		init(
			_ tokens: [EncodedToken], contextCount: Int, lz77: Parameters,
			forcesPrefixCodes: Bool
		) {
			var counts = [[UInt32]](repeating: [], count: contextCount)
			for encoded in tokens {
				let symbol = Int(
					encoded.isLength
						? lengthConfiguration.encode(encoded.token.value)
							.symbol
							+ lz77.minSymbol
						: literalConfiguration.encode(encoded.token.value)
							.symbol)
				let context = Int(encoded.token.context)
				if counts[context].count <= symbol {
					counts[context] += [UInt32](
						repeating: 0,
						count: (symbol + 8) / 8 * 8 - counts[context].count)
				}
				counts[context][symbol] += 1
			}
			let rowWidth = counts.map(\.count).max() ?? 0
			var bits = [Float](repeating: 0, count: contextCount * rowWidth)
			var addSymbolCosts: [Float] = []
			for (context, row) in counts.enumerated() {
				let total = row.reduce(0) { $0 + Int($1) }
				let inverseTotal = 1 / (Float(total) + 1e-8)
				var totalCost: Float = 0
				for (symbol, count) in row.enumerated() {
					var cost: Float = 0
					if count != 0 && Int(count) != total {
						cost = -FastMath.log2(Float(count) * inverseTotal)
						if forcesPrefixCodes { cost.round(.up) }
					} else if count == 0 {
						cost = Float(ANSConstants.logTabSize)
					}
					bits[context * rowWidth + symbol] = cost
					totalCost += cost * Float(count)
				}
				addSymbolCosts.append(max(0, 6 - totalCost * inverseTotal))
			}
			self.lz77 = lz77
			self.rowWidth = rowWidth
			self.bits = bits
			self.addSymbolCosts = addSymbolCosts
		}

		func bits(_ context: UInt32, _ symbol: UInt32) -> Float {
			bits[Int(context) * rowWidth + Int(symbol)]
		}

		func lengthCost(_ context: UInt32, _ length: Int) -> Float {
			let encoded = lengthConfiguration.encode(UInt32(length))
			return Float(encoded.bitCount)
				+ bits(context, encoded.symbol + lz77.minSymbol)
		}

		func distanceCost(_ distanceSymbol: Int) -> Float {
			let encoded = literalConfiguration.encode(UInt32(distanceSymbol))
			return Float(encoded.bitCount)
				+ bits(UInt32(lz77.distanceContext), encoded.symbol)
		}

		/// `sym_cost`: element i is the cost of the first i tokens as literals.
		func cumulativeLiteralCosts(_ tokens: [Token]) -> [Float] {
			var cumulative = [Float](repeating: 0, count: tokens.count + 1)
			for (index, token) in tokens.enumerated() {
				let encoded = literalConfiguration.encode(token.value)
				cumulative[index + 1] =
					bits(token.context, encoded.symbol)
					+ Float(encoded.bitCount)
					+ cumulative[index]
			}
			return cumulative
		}
	}

	private static func length(_ context: UInt32, _ length: Int) -> EncodedToken {
		EncodedToken(
			token: Token(context: context, value: UInt32(length) - minLength),
			isLength: true)
	}

	private static func distance(_ lz77: Parameters, _ distanceSymbol: Int)
		-> EncodedToken
	{
		EncodedToken(
			token: Token(
				context: UInt32(lz77.distanceContext), value: UInt32(distanceSymbol)
			),
			isLength: false)
	}

	/// `ApplyLZ77_RLE` (enc_lz77.cc:97-169) without image-width distances.
	private static func rle(_ tokens: [Token], lz77: Parameters, costs: SymbolCosts)
		-> [EncodedToken]?
	{
		let cumulative = costs.cumulativeLiteralCosts(tokens)
		var transformed: [EncodedToken] = []
		transformed.reserveCapacity(tokens.count)
		var bitDecrease: Float = 0
		var index = 0
		while index < tokens.count {
			var copyCount = 0
			if index > 0 {
				while index + copyCount < tokens.count,
					tokens[index + copyCount].value == tokens[index - 1].value
				{
					copyCount += 1
				}
			}
			let cost = cumulative[index + copyCount] - cumulative[index]
			let length = copyCount - Int(minLength)
			let lengthCost =
				copyCount >= Int(minLength)
				? Float(ceilLog2Nonzero(length + 1) + 1) : 0
			if copyCount < Int(minLength) || cost <= lengthCost {
				let end = index + max(copyCount, 1)
				transformed += tokens[index..<end].map {
					EncodedToken(token: $0, isLength: false)
				}
				index = end
				continue
			}
			transformed.append(Self.length(tokens[index].context, copyCount))
			transformed.append(distance(lz77, 0))
			bitDecrease += cost - lengthCost
			index += copyCount
		}
		return savesEnough(bitDecrease, tokenCount: tokens.count) ? transformed : nil
	}

	/// `ApplyLZ77_LZ77` (enc_lz77.cc:439-544) without image-width distances:
	/// greedy matching with one step of lazy lookahead, priced by the static
	/// length and distance tables.
	private static func greedy(_ tokens: [Token], lz77: Parameters, costs: SymbolCosts)
		-> [EncodedToken]?
	{
		let cumulative = costs.cumulativeLiteralCosts(tokens)
		var chain = HashChain(tokens.map(\.value))
		var transformed: [EncodedToken] = []
		transformed.reserveCapacity(tokens.count)
		var bitDecrease: Float = 0
		var alreadyUpdated = false
		var index = 0
		while index < tokens.count {
			defer { index += 1 }
			transformed.append(EncodedToken(token: tokens[index], isLength: false))
			if !alreadyUpdated { chain.update(index) }
			alreadyUpdated = false
			var match = chain.findMatch(index)
			guard match.length >= Int(minLength) else { continue }
			if match.length < 256 && index + 1 < tokens.count {
				chain.update(index + 1)
				alreadyUpdated = true
				let next = chain.findMatch(index + 1)
				if next.length > match.length {
					index += 1
					alreadyUpdated = false
					match = next
					transformed.append(
						EncodedToken(token: tokens[index], isLength: false))
				}
			}
			let cost = cumulative[index + match.length] - cumulative[index]
			let context = transformed[transformed.count - 1].token.context
			let lz77Cost =
				staticLengthCost(match.length - Int(minLength))
				+ staticDistanceCost(match.distanceSymbol)
				+ costs.addSymbolCosts[Int(context)]
			if lz77Cost <= cost {
				transformed[transformed.count - 1] = length(context, match.length)
				transformed.append(distance(lz77, match.distanceSymbol))
				bitDecrease += cost - lz77Cost
			} else {
				transformed += tokens[(index + 1)..<(index + match.length)].map {
					EncodedToken(token: $0, isLength: false)
				}
			}
			for position in (index + (alreadyUpdated ? 2 : 1))..<(index + match.length)
			{
				chain.update(position)
			}
			alreadyUpdated = false
			index += match.length - 1
		}
		return savesEnough(bitDecrease, tokenCount: tokens.count) ? transformed : nil
	}

	/// `ApplyLZ77_Optimal`'s shortest path (enc_lz77.cc:546-680) without
	/// image-width distances, priced by `costs` estimated from the greedy
	/// result. It keeps its result whatever the saving.
	private static func optimal(_ tokens: [Token], lz77: Parameters, costs: SymbolCosts)
		-> [EncodedToken]
	{
		struct Step {
			var length = 0
			/// Zero for a literal, else the distance symbol plus one.
			var distanceSymbol = 0
			var context: UInt32 = 0
			var cost = Float.greatestFiniteMagnitude
		}
		let cumulative = costs.cumulativeLiteralCosts(tokens)
		var chain = HashChain(tokens.map(\.value))
		let minLength = Int(minLength)
		var steps = [Step](repeating: Step(), count: tokens.count + 1)
		steps[0].cost = 0
		var runLength = 0
		var skipped = 0
		var distanceSymbols: [Int] = []
		for index in tokens.indices {
			chain.update(index)
			let context = tokens[index].context
			let literalCost =
				steps[index].cost + cumulative[index + 1] - cumulative[index]
			if steps[index + 1].cost > literalCost {
				steps[index + 1] = Step(
					length: 1, distanceSymbol: 0, context: context,
					cost: literalCost)
			}
			if skipped > 0 {
				skipped -= 1
				continue
			}
			distanceSymbols.removeAll(keepingCapacity: true)
			chain.findMatches(index) { length, distanceSymbol in
				if distanceSymbols.count <= length {
					distanceSymbols += repeatElement(
						distanceSymbol,
						count: length + 1 - distanceSymbols.count)
				}
				distanceSymbols[length] = min(
					distanceSymbols[length], distanceSymbol)
			}
			guard distanceSymbols.count > minLength else { continue }
			var best = distanceSymbols[distanceSymbols.count - 1]
			for length in (minLength..<distanceSymbols.count).reversed() {
				best = min(best, distanceSymbols[length])
				distanceSymbols[length] = best
			}
			for length in minLength..<distanceSymbols.count {
				let cost =
					steps[index].cost
					+ (costs.lengthCost(context, length - minLength)
						+ costs.distanceCost(distanceSymbols[length]))
				if steps[index + length].cost > cost {
					steps[index + length] = Step(
						length: length,
						distanceSymbol: distanceSymbols[length] + 1,
						context: context, cost: cost)
				}
			}
			// Inside a run, only the first and last 8 positions look for matches.
			runLength =
				distanceSymbols[distanceSymbols.count - 1] == 0 ? runLength + 1 : 0
			if runLength >= 8 && distanceSymbols.count > 9 {
				skipped = distanceSymbols.count - 10
				runLength = 0
			}
		}
		var transformed: [EncodedToken] = []
		var position = tokens.count
		while position > 0 {
			let step = steps[position]
			if step.distanceSymbol != 0 {
				transformed.append(distance(lz77, step.distanceSymbol - 1))
				transformed.append(length(step.context, step.length))
			} else {
				transformed.append(
					EncodedToken(token: tokens[position - 1], isLength: false))
			}
			position -= step.length
		}
		return transformed.reversed()
	}

	/// The greedy parse's static `LenCost` (enc_lz77.cc:364-378).
	private static func staticLengthCost(_ length: Int) -> Float {
		let encoded = HybridUintConfiguration(
			splitExponent: 1, msbInToken: 0, lsbInToken: 0
		)
		.encode(UInt32(length))
		return lengthCostTable[min(Int(encoded.symbol), lengthCostTable.count - 1)]
			+ Float(encoded.bitCount)
	}

	/// The greedy parse's static `DistCost` (enc_lz77.cc:382-437).
	private static func staticDistanceCost(_ distanceSymbol: Int) -> Float {
		let encoded = HybridUintConfiguration(
			splitExponent: 7, msbInToken: 0, lsbInToken: 0
		)
		.encode(UInt32(distanceSymbol))
		return distanceCostTable[min(Int(encoded.symbol), distanceCostTable.count - 1)]
			+ Float(encoded.bitCount)
	}

	// Rounded to Float from Double, as the source's constexpr float tables are.
	private static let lengthCostTable =
		([
			2.797667318563126, 3.213177690381199, 2.5706009246743737, 2.408392498667534,
			2.829649191872326, 3.3923087753324577, 4.029267451554331, 4.415576699706408,
			4.509357574741465, 9.21481543803004, 10.020590190114898, 11.858671627804766,
			12.45853300490526, 11.713105831990857, 12.561996324849314,
			13.775477692278367, 13.174027068768641,
		] as [Double]).map(Float.init)

	private static let distanceCostTable =
		([
			6.368282626312716, 5.680793277090298, 8.347404197105247, 7.641619201599141,
			6.914328374119438, 7.959808291537444, 8.70023120759855, 8.71378518934703,
			9.379132523982769, 9.110472749092708, 9.159029569270908, 9.430936766731973,
			7.278284055315169, 7.8278514904267755, 10.026641158289236,
			9.976049229827066, 9.64351607048908, 9.563403863480442, 10.171474111762747,
			10.45950155077234, 9.994813912104219, 10.322524683741156, 8.465808729388186,
			8.756254166066853, 10.160930174662234, 10.247329273413435,
			10.04090403724809, 10.129398517544082, 9.342311691539546, 9.07608009102374,
			10.104799540677513, 10.378079384990906, 10.165828974075072,
			10.337595322341553, 7.940557464567944, 10.575665823319431,
			11.023344321751955, 10.736144698831827, 11.118277044595054,
			7.468468230648442, 10.738305230932939, 10.906980780216568,
			10.163468216353817, 10.17805759656433, 11.167283670483565,
			11.147050200274544, 10.517921919244333, 10.651764778156886,
			10.17074446448919, 11.217636876224745, 11.261630721139484,
			11.403140815247259, 10.892472096873417, 11.1859607804481, 8.017346947551262,
			7.895143720278828, 11.036577113822025, 11.170562110315794,
			10.326988722591086, 10.40872184751056, 11.213498225466386,
			11.30580635516863, 10.672272515665442, 10.768069466228063,
			11.145257364153565, 11.64668307145549, 10.593156194627339,
			11.207499484844943, 10.767517766396908, 10.826629811407042,
			10.737764794499988, 10.6200448518045, 10.191315385198092, 8.468384171390085,
			11.731295299170432, 11.824619886654398, 10.41518844301179,
			10.16310536548649, 10.539423685097576, 10.495136599328031,
			10.469112847728267, 11.72057686174922, 10.910326337834674,
			11.378921834673758, 11.847759036098536, 11.92071647623854,
			10.810628276345282, 11.008601085273893, 11.910326337834674,
			11.949212023423133, 11.298614839104337, 11.611603659010392,
			10.472930394619985, 11.835564720850282, 11.523267392285337,
			12.01055816679611, 8.413029688994023, 11.895784139536406,
			11.984679534970505, 11.220654278717394, 11.716311684833672,
			10.61036646226114, 10.89849965960364, 10.203762898863669,
			10.997560826267238, 11.484217379438984, 11.792836176993665,
			12.24310468755171, 11.464858097919262, 12.212747017409377,
			11.425595666074955, 11.572048533398757, 12.742093965163013,
			11.381874288645637, 12.191870445817015, 11.683156920035426,
			11.152442115262197, 11.90303691580457, 11.653292787169159,
			11.938615382266098, 16.970641701570223, 16.853602280380002,
			17.26240782594733, 16.644655390108507, 17.14310889757499,
			16.910935455445955, 17.505678976959697, 17.213498225466388,
			2.4162310293553024, 3.494587244462329, 3.5258600986408344,
			3.4959806589517095, 3.098390886949687, 3.343454654302911, 3.588847442290287,
			4.14614790111827, 5.152948641990529, 7.433696808092598, 9.716311684833672,
		] as [Double]).map(Float.init)
}

/// `HashChain` (enc_lz77.cc:172-362) without special distances, so a match at
/// distance d reports distance symbol d - 1.
private struct HashChain {
	let data: [UInt32]
	/// The next power of two at or above the input size, at most 2^20.
	let windowSize: Int
	var head = [Int](repeating: -1, count: 32_768)
	var chain: [Int]
	var hashes: [Int]
	var zeroHead: [Int]
	var zeroChain: [Int]
	var zeros: [Int]
	var zeroCount = 0

	init(_ data: [UInt32]) {
		self.data = data
		var windowSize = 1
		while windowSize < data.count && windowSize < 1 << 20 { windowSize <<= 1 }
		self.windowSize = windowSize
		chain = Array(0..<windowSize)
		hashes = [Int](repeating: -1, count: windowSize)
		zeroHead = [Int](repeating: -1, count: windowSize + 1)
		zeroChain = Array(0..<windowSize)
		zeros = [Int](repeating: 0, count: windowSize)
	}

	func hash(_ position: Int) -> Int {
		guard position + 2 < data.count else { return 0 }
		return Int(
			(data[position] ^ (data[position + 1] &<< 5) ^ (data[position + 2] &<< 10))
				& 32_767)
	}

	func countZeros(_ position: Int, previous: Int) -> Int {
		let end = min(position + windowSize, data.count)
		if previous > 0 {
			return previous >= windowSize - 1 && data[end - 1] == 0
				&& end == position + windowSize ? previous : previous - 1
		}
		var count = 0
		while position + count < end && data[position + count] == 0 { count += 1 }
		return count
	}

	mutating func update(_ position: Int) {
		let hash = hash(position)
		let windowPosition = position & (windowSize - 1)
		hashes[windowPosition] = hash
		if head[hash] != -1 { chain[windowPosition] = head[hash] }
		head[hash] = windowPosition
		if position > 0 && data[position] != data[position - 1] { zeroCount = 0 }
		zeroCount = countZeros(position, previous: zeroCount)
		zeros[windowPosition] = zeroCount
		if zeroHead[zeroCount] != -1 { zeroChain[windowPosition] = zeroHead[zeroCount] }
		zeroHead[zeroCount] = windowPosition
	}

	/// Reports each candidate of at least `LZ77.minLength` that is no more than
	/// two shorter than the longest so far, nearest first.
	func findMatches(_ position: Int, _ found: (_ length: Int, _ distanceSymbol: Int) -> Void) {
		let windowPosition = position & (windowSize - 1)
		let hash = hash(position)
		var candidate = chain[windowPosition]
		var previousDistance = 0
		var chainLength = 0
		var bestLength = 0
		while true {
			let distance =
				candidate <= windowPosition
				? windowPosition - candidate
				: windowPosition - candidate + windowSize
			if distance < previousDistance { break }
			previousDistance = distance
			var length = 0
			if distance > 0 {
				var i = position
				if zeroCount > 3 {
					i += min(
						min(zeroCount - 1, zeros[candidate]),
						data.count - i - 1)
				}
				while i < data.count && data[i] == data[i - distance] { i += 1 }
				length = i - position
				if length >= Int(LZ77.minLength) && length + 2 >= bestLength {
					found(length, distance - 1)
					bestLength = max(bestLength, length)
				}
			}
			chainLength += 1
			if chainLength >= 256 { break }
			if zeroCount >= 3 && length > zeroCount {
				if candidate == zeroChain[candidate] { break }
				candidate = zeroChain[candidate]
				if zeros[candidate] != zeroCount { break }
			} else {
				if candidate == chain[candidate] { break }
				candidate = chain[candidate]
				if hashes[candidate] != hash { break }
			}
		}
	}

	/// The longest match, the smallest distance symbol among equals; length 1
	/// when there is none.
	func findMatch(_ position: Int) -> (length: Int, distanceSymbol: Int) {
		var best = (length: 1, distanceSymbol: 0)
		findMatches(position) { length, distanceSymbol in
			if length > best.length
				|| (length == best.length && best.distanceSymbol > distanceSymbol)
			{
				best = (length, distanceSymbol)
			}
		}
		return best
	}
}
