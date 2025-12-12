// swift-tools-version:5.5.0
import PackageDescription
let package = Package(
	name: "CCZUNISwiftBridge",
	platforms: [
		.macOS(.v10_15),
		.iOS(.v13),
		.watchOS(.v6),
		.tvOS(.v13)
	],
	products: [
		.library(
			name: "CCZUNISwiftBridge",
			targets: ["CCZUNISwiftBridge"]),
	],
	dependencies: [],
	targets: [
		.binaryTarget(
			name: "RustXcframework",
			path: "RustXcframework.xcframework"
		),
		.target(
			name: "CCZUNISwiftBridge",
			dependencies: ["RustXcframework"],
			resources: [
				.process("calendar.json")
			]
		)
	]
)
	