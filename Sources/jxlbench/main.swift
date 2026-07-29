import Foundation
import JXLEncoder

func makeImage(_ w: Int, _ h: Int) -> ImageBuffer {
	var s = [UInt8](repeating: 0, count: w * h * 3)
	for y in 0..<h {
		for x in 0..<w {
			let i = (y * w + x) * 3
			s[i] = UInt8((x * 7 + y * 3) % 256)
			s[i + 1] = UInt8((x * 3 + y * 11) % 256)
			s[i + 2] = UInt8((x &* y) % 256)
		}
	}
	return try! ImageBuffer(width: w, height: h, samples: s)
}

let w = Int(CommandLine.arguments[1])!
let h = Int(CommandLine.arguments[2])!
FileHandle.standardError.write("encoding \(w)x\(h)...\n".data(using: .utf8)!)
let image = makeImage(w, h)
let start = Date()
let bytes = try! JXLEncoder.Encoder.encode(image, distance: 1.0)
let elapsed = Date().timeIntervalSince(start)
let mp = Double(w * h) / 1_000_000
print(String(format: "%5.2f MP  %7.3f s  %6.2f MP/s  %8d bytes", mp, elapsed, mp / elapsed, bytes.count))
FileHandle.standardError.write("done\n".data(using: .utf8)!)
