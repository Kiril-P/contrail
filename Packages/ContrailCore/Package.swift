// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ContrailCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ContrailCore", targets: ["ContrailCore"]),
    ],
    targets: [
        .target(name: "ContrailCore"),
        .testTarget(name: "ContrailCoreTests", dependencies: ["ContrailCore"]),
    ],
    swiftLanguageModes: [.v6]
)
