import Foundation

// This tool is Apple-only: it exists to drive `JXLEncoderApple`, which is
// itself guarded by the same condition. Without this guard, `swift test` on
// Linux builds this target against an empty `JXLEncoderApple` module and
// fails with "has no member named 'encode'".
#if canImport(ImageIO)

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
			print(
				String(
					format:
						"entropy: rawContexts=%d clusters=%d tokens=%d prefix=%d bits bound=%.0f bits coder-loss=%.1f%%",
					report.baseContexts, report.clusters, report.tokenCount,
					report.prefixSymbolBits, report.entropyBoundBits,
					coderLoss * 100))
		}
	}

	let input = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
	let encoded = try JXLEncoderApple.encode(data: input, distance: distance)
	try encoded.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
	print(encoded.count)

#else

	FileHandle.standardError.write(
		Data("jxlencode requires ImageIO (Apple platforms only)\n".utf8))
	exit(1)

#endif
