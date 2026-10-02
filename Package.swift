// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PersonaStackDesktop",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PersonaStack", targets: ["PersonaStack"]),
        .executable(name: "PersonaStackPolicyCheck", targets: ["PersonaStackPolicyCheck"]),
        .executable(name: "PersonaStackLockedControlInstaller", targets: ["PersonaStackLockedControlInstaller"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "LockedControlAudit", publicHeadersPath: "include", linkerSettings: [.linkedFramework("Security"), .linkedFramework("SystemConfiguration"), .linkedLibrary("bsm")]),
        .target(name: "PersonaStackCore", dependencies: ["Yams", "LockedControlAudit"]),
        .executableTarget(name: "PersonaStack", dependencies: ["PersonaStackCore", .product(name: "Sparkle", package: "Sparkle")]),
        .executableTarget(name: "PersonaStackPolicyCheck", dependencies: ["PersonaStackCore"]),
        .executableTarget(name: "PersonaStackLockedControlInstaller", dependencies: ["PersonaStackCore"]),
        .testTarget(name: "PersonaStackTests", dependencies: ["PersonaStackCore", "PersonaStack"], resources: [.copy("Fixtures/local-session.json"), .copy("Fixtures/desktop-parity.json")]),
    ]
)
