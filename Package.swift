// swift-tools-version: 6.1

import PackageDescription

let package = Package(
	name: "jxl-encoder-swift",
	platforms: [.iOS(.v17), .macOS(.v15)],
	products: [
		.library(name: "JXLEncoder", targets: ["JXLEncoder"]),
		.library(name: "JXLEncoderApple", targets: ["JXLEncoderApple"]),
	],
	dependencies: [
		//RealModule only, for pow(). Pure Swift over the platform libm, so it
		//stays portable to Linux and Android.
		.package(url: "https://github.com/apple/swift-numerics", from: "1.1.1")
	],
	targets: [
		//Portable core: no Foundation, no platform frameworks — Linux CI enforces
		//this so an Android shim can consume it unchanged.
		.target(
			name: "JXLEncoder",
			dependencies: [.product(name: "RealModule", package: "swift-numerics")]
		),
		.target(
			name: "JXLEncoderApple",
			dependencies: ["JXLEncoder"]
		),
		.testTarget(
			name: "JXLEncoderTests",
			dependencies: ["JXLEncoder"],
			resources: [.copy("Fixtures")]
		),
		.executableTarget(name: "jxlbench", dependencies: ["JXLEncoder"]),
		//Measurement harness for docs/gap-closure-plan.md — encodes a file at a
		//given distance so corpus sweeps can compare against the reference.
		.executableTarget(name: "jxlencode", dependencies: ["JXLEncoderApple"]),
		.testTarget(
			name: "JXLEncoderAppleTests",
			dependencies: ["JXLEncoder", "JXLEncoderApple"],
			resources: [.copy("Fixtures")]
		),
	]
)
