import Foundation
import JXLEncoder
import JXLEncoderApple

guard CommandLine.arguments.count >= 4,
	let distance = Float(CommandLine.arguments[3])
else {
	FileHandle.standardError.write(
		Data(
			"usage: jxlencode <input-image> <output.jxl> <distance> [--entropy-report]\n"
				.utf8))
	exit(1)
}

if CommandLine.arguments.contains("--entropy-report") {
	EntropyDiagnostics.sink = { report in
		let coderLoss =
			Double(report.prefixSymbolBits) / report.entropyBoundBits - 1
		let modelLoss =
			report.entropyBoundBits / report.fullContextBoundBits - 1
		print(
			String(
				format: "entropy: base=%d clusters=%d tokens=%d prefix=%d "
					+ "bound=%.0f coder-loss=%.1f%% "
					+ "full-ctx: clusters=%d bound=%.0f model-loss=%.1f%%",
				report.baseContexts, report.clusters, report.tokenCount,
				report.prefixSymbolBits, report.entropyBoundBits,
				coderLoss * 100, report.fullContextClusters,
				report.fullContextBoundBits, modelLoss * 100))
	}
}

let input = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let encoded = try JXLEncoderApple.encode(data: input, distance: distance)
try encoded.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
print(encoded.count)
