// swift-tools-version: 6.1

import PackageDescription

let package = Package(
	name: "jxl-encoder-swift",
	platforms: [.iOS(.v17), .macOS(.v15)],
	products: [
		.library(name: "JXLEncoder", targets: ["JXLEncoder"]),
		.library(name: "JXLEncoderApple", targets: ["JXLEncoderApple"]),
	],
	targets: [
		//Portable core: Swift stdlib only. No Foundation, no platform frameworks —
		//Linux CI enforces this so an Android shim can consume it unchanged.
		.target(name: "JXLEncoder"),
		.target(
			name: "JXLEncoderApple",
			dependencies: ["JXLEncoder"]
		),
		.testTarget(
			name: "JXLEncoderTests",
			dependencies: ["JXLEncoder"],
			resources: [.copy("Fixtures")]
		),
		.testTarget(name: "JXLEncoderAppleTests", dependencies: ["JXLEncoderApple"]),
	]
)
