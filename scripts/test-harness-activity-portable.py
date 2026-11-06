#!/usr/bin/env python3
"""Run actual hook policy sources/tests on Linux without the macOS app graph.

Only platform imports and path hashing are adapted. The SHA stub preserves unique
fixture names; this lane does not qualify CryptoKit, Keychain or Darwin behavior.
"""
import argparse
import contextlib
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ("HarnessHookState.swift", "HarnessHookDispatcher.swift", "HarnessActivityReporter.swift")
TESTS = ("HarnessHookStateTests.swift", "HarnessActivityRenewalTests.swift", "HarnessActivitySequenceTests.swift", "HarnessHookDispatcherTests.swift")


def portable(source):
    return source.replace("import Darwin", "import Glibc\nimport FoundationNetworking").replace("import CryptoKit\n", "").replace("Darwin.write", "Glibc.write")


parser = argparse.ArgumentParser()
parser.add_argument("--package-directory")
parser.add_argument("--prepare-only", action="store_true")
args = parser.parse_args()
if args.prepare_only and not args.package_directory:
    parser.error("--prepare-only requires --package-directory")
workspace = contextlib.nullcontext(args.package_directory) if args.package_directory else tempfile.TemporaryDirectory(prefix="harness-activity-portable-")
with workspace as temp:
    package = pathlib.Path(temp)
    source = package / "Sources/PersonaStackCore"
    tests = package / "Tests/PersonaStackTests"
    executable = package / "Sources/PersonaStackHarnessHook"
    source.mkdir(parents=True, exist_ok=True)
    tests.mkdir(parents=True, exist_ok=True)
    executable.mkdir(parents=True, exist_ok=True)
    (executable / "main.swift").write_text(portable((ROOT / "Sources/PersonaStackHarnessHook/main.swift").read_text()))
    (package / "Package.swift").write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "HarnessActivityPortable", targets: [
    .target(name: "PersonaStackCore"),
    .testTarget(name: "PersonaStackTests", dependencies: ["PersonaStackCore"]),
    .executableTarget(name: "PersonaStackHarnessHook", dependencies: ["PersonaStackCore"])
])
''')
    for name in SOURCES:
        (source / name).write_text(portable((ROOT / "Sources/PersonaStackCore" / name).read_text()))
    for name in TESTS:
        contents = portable((ROOT / "Tests/PersonaStackTests" / name).read_text()).replace("import Foundation\n", "import Foundation\nimport FoundationNetworking\n")
        if name == "HarnessHookDispatcherTests.swift":
            # Native bundle/Keychain decoding is separately owned. Supply only
            # equivalent isolated credentials to this actual dispatcher corpus.
            start = contents.index("    private func credential(")
            end = contents.index("    private func read(", start)
            contents = contents[:start] + '''    private func credential(_ harness: LocalSessionHarness) throws -> HarnessActivityCredential {
        .init(connectionID: UUID().uuidString.lowercased(), activityToken: UUID().uuidString, appURL: URL(string: "https://my.personastack.ai")!, harness: harness, routingEnabled: true)
    }
''' + contents[end:]
        (tests / name).write_text(contents)
    (source / "PlatformFixtures.swift").write_text('''import Foundation
public enum LocalSessionError: Error { case invalidRequest, unsafeFiles, mcpUnavailable }
public enum LocalSessionHarness: String, Codable, Sendable { case codex, claudeCode }
public struct HarnessActivityCredential: Codable, Sendable {
    public let connectionID: String
    public let activityToken: String
    public let appURL: URL
    public let harness: LocalSessionHarness
    public let routingEnabled: Bool
}
public struct HarnessActivityKeychain {
    public init() {}
    public func read(_ connection: String) throws -> HarnessActivityCredential { throw LocalSessionError.invalidRequest }
}
// Hash cryptography is outside this portable policy lane.
enum SHA256 { static func hash(data: Data) -> [UInt8] { Array(data) } }
''')
    if not args.prepare_only:
        subprocess.run(["swift", "test", "--package-path", str(package), "--parallel"], check=True)
