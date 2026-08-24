// Normalizes measurement-corpus images to deterministic sRGB PNGs.
//
// Every corpus image passes through the same CGContext redraw so that what the
// encoders consume is byte-stable across regenerations — decoded JPEG fixtures
// and testdata PNGs alike. `gradient` generates the synthetic smooth-content
// case in-process so the corpus carries no asset for it.
//
// Usage:
//   swift make_corpus.swift normalize <input-image> <out-dir> <name>
//   swift make_corpus.swift gradient <out-dir>

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func writePNG(_ image: CGImage, to path: String) {
	let dest = CGImageDestinationCreateWithURL(
		URL(fileURLWithPath: path) as CFURL,
		UTType.png.identifier as CFString, 1, nil)!
	CGImageDestinationAddImage(dest, image, nil)
	CGImageDestinationFinalize(dest)
}

switch CommandLine.arguments[1] {
case "normalize":
	let inPath = CommandLine.arguments[2]
	let outDir = CommandLine.arguments[3]
	let name = CommandLine.arguments[4]
	let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: inPath) as CFURL, nil)!
	let image = CGImageSourceCreateImageAtIndex(src, 0, nil)!
	let w = image.width
	let h = image.height
	var rgba = [UInt8](repeating: 0, count: w * h * 4)
	let rebuilt = rgba.withUnsafeMutableBytes { buffer -> CGImage in
		let ctx = CGContext(
			data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
			bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
			bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
		ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
		return ctx.makeImage()!
	}
	writePNG(rebuilt, to: "\(outDir)/\(name).png")
	print("\(name): \(w)x\(h)")

case "gradient":
	let outDir = CommandLine.arguments[2]
	let size = 1024
	let colorSpace = CGColorSpaceCreateDeviceRGB()
	let context = CGContext(
		data: nil, width: size, height: size, bitsPerComponent: 8,
		bytesPerRow: 0, space: colorSpace,
		bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
	let gradient = CGGradient(
		colorsSpace: colorSpace,
		colors: [
			CGColor(red: 1, green: 0.2, blue: 0.1, alpha: 1),
			CGColor(red: 0.1, green: 0.3, blue: 1, alpha: 1),
		] as CFArray,
		locations: [0, 1])!
	context.drawLinearGradient(
		gradient, start: .zero, end: CGPoint(x: size, y: size), options: [])
	writePNG(context.makeImage()!, to: "\(outDir)/gradient.png")
	print("gradient: \(size)x\(size)")

default:
	FileHandle.standardError.write(Data("unknown mode\n".utf8))
	exit(1)
}
