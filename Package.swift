// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "TimeWeaveCore",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "TimeWeaveCore", targets: ["TimeWeaveCore"])],
    targets: [
        .target(name: "TimeWeaveCore", path: "TimeWeave/Core"),
        .testTarget(name: "TimeWeaveCoreTests", dependencies: ["TimeWeaveCore"])
    ]
)
