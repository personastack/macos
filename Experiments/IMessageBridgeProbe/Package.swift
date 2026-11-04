// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IMessageBridgeProbe",
    platforms: [.macOS(.v14)],
    products: [.library(name: "IMessageBridgeProbe", targets: ["IMessageBridgeProbe"])],
    targets: [
        .target(name: "IMessageBridgeProbe"),
        .testTarget(name: "IMessageBridgeProbeTests", dependencies: ["IMessageBridgeProbe"]),
    ]
)
