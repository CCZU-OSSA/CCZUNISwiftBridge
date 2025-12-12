// swift-tools-version:5.5.0
import PackageDescription
let package = Package(
	name: "CCZUNISwiftBridge",
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
			dependencies: ["RustXcframework"])
	]
)
	