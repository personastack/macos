import Foundation
import Testing
@testable import PersonaStackCore

@Suite
struct CuaDriverInstallerTests {
    @Test
    func installerPreservesThePinnedDriversLicenseBesideTheManagedPayload() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try CuaDriverInstaller.installLicenseNotice(into: root)

        let notice = root.appendingPathComponent("LICENSE-CuaDriver-MIT.txt")
        #expect(try String(contentsOf: notice, encoding: .utf8) == CuaDriverCompatibility.licenseNotice)
    }

    @Test
    func healthyPinnedInstallIsReusedWithoutNetworkOrReplacement() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let installationRoot = root.appendingPathComponent("CuaDriver-\(CuaDriverCompatibility.version)", isDirectory: true)
        let app = installationRoot.appendingPathComponent("CuaDriver.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents", isDirectory: true), withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.trycua.driver"], format: .xml, options: 0
        )
        try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let executable = installationRoot.appendingPathComponent("cua-driver")
        try Data("fake executable".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let runner = FixedCuaProcessRunner()
        let installer = CuaDriverInstaller(supportDirectory: root, processRunner: runner)

        let installed = try await installer.validateOrInstall()

        #expect(installed.version == CuaDriverCompatibility.version)
        #expect(installed.applicationURL == app)
        #expect(installed.toolNames.isSuperset(of: CuaDriverCompatibility.requiredTools))
        #expect(runner.invocations == [
            ["--verify", "--deep", "--strict", app.path],
            ["-dv", "--verbose=4", app.path],
            ["manifest", "--pretty"],
            ["list-tools"]
        ])
    }

    @Test
    func repairRefusesToReplaceUnmanagedPath() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let install = root.appendingPathComponent("CuaDriver-\(CuaDriverCompatibility.version)", isDirectory: true)
        try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
        let sentinel = install.appendingPathComponent("user-file")
        try Data("keep".utf8).write(to: sentinel)
        let runner = FixedCuaProcessRunner()
        let installer = CuaDriverInstaller(supportDirectory: root, processRunner: runner)

        await #expect(throws: CuaDriverInstallError.invalidLayout) {
            try await installer.validateOrInstall(repair: true)
        }

        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "keep")
        #expect(runner.invocations.isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cua-installer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private final class FixedCuaProcessRunner: CuaProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []

    var invocations: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func run(_ executable: URL, arguments: [String]) throws -> CuaProcessResult {
        lock.lock()
        calls.append(arguments)
        lock.unlock()
        if arguments.first == "--verify" { return CuaProcessResult(status: 0, stdout: Data(), stderr: Data()) }
        if arguments.first == "-dv" {
            return CuaProcessResult(
                status: 0,
                stdout: Data(),
                stderr: Data("Identifier=com.trycua.driver\nTeamIdentifier=YCK386LBJ7\n".utf8)
            )
        }
        if arguments == ["manifest", "--pretty"] {
            let json = #"{"binary_version":"0.28.2","schema_version":"1"}"#
            return CuaProcessResult(status: 0, stdout: Data(json.utf8), stderr: Data())
        }
        if arguments == ["list-tools"] {
            let output = CuaDriverCompatibility.requiredTools.sorted().map { "\($0): required" }.joined(separator: "\n")
            return CuaProcessResult(status: 0, stdout: Data(output.utf8), stderr: Data())
        }
        return CuaProcessResult(status: 1, stdout: Data(), stderr: Data())
    }
}
