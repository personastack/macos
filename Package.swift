// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PersonaStackDesktop",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PersonaStack", targets: ["PersonaStack"]),
        .executable(name: "PersonaStackPolicyCheck", targets: ["PersonaStackPolicyCheck"]),
    ],
    targets: [
        .target(name: "PersonaStackCore"),
        .executableTarget(name: "PersonaStack", dependencies: ["PersonaStackCore"]),
        .executableTarget(name: "PersonaStackPolicyCheck", dependencies: ["PersonaStackCore"]),
    ]
)
