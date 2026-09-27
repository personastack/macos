// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PersonaStackDesktop",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PersonaStack", targets: ["PersonaStack"]),
        .executable(name: "PersonaStackPolicyCheck", targets: ["PersonaStackPolicyCheck"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
    ],
    targets: [
        .target(name: "PersonaStackCore", dependencies: ["Yams"]),
        .executableTarget(name: "PersonaStack", dependencies: ["PersonaStackCore"]),
        .executableTarget(name: "PersonaStackPolicyCheck", dependencies: ["PersonaStackCore"]),
        .testTarget(name: "PersonaStackTests", dependencies: ["PersonaStackCore", "PersonaStack"], resources: [.copy("Fixtures/local-session.json"), .copy("Fixtures/desktop-parity.json")]),
    ]
)
