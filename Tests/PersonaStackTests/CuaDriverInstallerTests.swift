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
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS", isDirectory: true), withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.trycua.driver"], format: .xml, options: 0
        )
        try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let executable = app.appendingPathComponent("Contents/MacOS/cua-driver")
        try Data("fake executable".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let runner = FixedCuaProcessRunner()
        let installer = CuaDriverInstaller(supportDirectory: root, processRunner: runner, externalApplicationURLs: [])

        let installed = try await installer.validateOrInstall()

        #expect(installed.version == CuaDriverCompatibility.version)
        #expect(installed.applicationURL == app)
        #expect(installed.toolNames.isSuperset(of: CuaDriverCompatibility.requiredTools))
        #expect(runner.invocations == [
            ["--verify", "--deep", "--strict", app.path],
            ["-dv", "--verbose=4", app.path],
            ["-a", "256", executable.path],
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
        let installer = CuaDriverInstaller(supportDirectory: root, processRunner: runner, externalApplicationURLs: [])

        await #expect(throws: CuaDriverInstallError.invalidLayout) {
            try await installer.validateOrInstall(repair: true)
        }

        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "keep")
        #expect(runner.invocations.isEmpty)
    }

    @Test
    func compatibleExternalApplicationIsReusedWithoutManagedInstallOrMutation() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let application = root.appendingPathComponent("Applications/CuaDriver.app", isDirectory: true)
        let executable = try makeFakeApplication(at: application)
        let runner = FixedCuaProcessRunner()
        let installer = CuaDriverInstaller(supportDirectory: root, processRunner: runner, externalApplicationURLs: [application])

        let installed = try await installer.validateOrInstall(repair: true)

        #expect(installed.applicationURL == application)
        #expect(installed.executableURL == executable)
        #expect(try String(contentsOf: executable, encoding: .utf8) == "untouched external executable")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("CuaDriver-\(CuaDriverCompatibility.version)").path))
        #expect(runner.invocations == [
            ["--verify", "--deep", "--strict", application.path],
            ["-dv", "--verbose=4", application.path],
            ["-a", "256", executable.path],
            ["manifest", "--pretty"],
            ["list-tools"]
        ])
    }

    @Test
    func incompatibleExternalApplicationIsSkippedForNextCompatibleApplication() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outdated = root.appendingPathComponent("old/CuaDriver.app", isDirectory: true)
        let compatible = root.appendingPathComponent("Applications/CuaDriver.app", isDirectory: true)
        let outdatedExecutable = try makeFakeApplication(at: outdated)
        let compatibleExecutable = try makeFakeApplication(at: compatible)
        let runner = FixedCuaProcessRunner(outdatedExecutablePaths: [outdatedExecutable.path])
        let installer = CuaDriverInstaller(
            supportDirectory: root, processRunner: runner, externalApplicationURLs: [outdated, compatible]
        )

        let installed = try await installer.validateOrInstall()

        #expect(installed.applicationURL == compatible)
        #expect(installed.executableURL == compatibleExecutable)
        #expect(try String(contentsOf: outdatedExecutable, encoding: .utf8) == "untouched external executable")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("CuaDriver-\(CuaDriverCompatibility.version)").path))
    }

    @Test
    func executableChecksumIsCheckedBeforeAnyDriverCommandRuns() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let changed = root.appendingPathComponent("changed/CuaDriver.app", isDirectory: true)
        let reviewed = root.appendingPathComponent("reviewed/CuaDriver.app", isDirectory: true)
        let changedExecutable = try makeFakeApplication(at: changed)
        _ = try makeFakeApplication(at: reviewed)
        let runner = FixedCuaProcessRunner(mismatchedChecksumPaths: [changedExecutable.path])
        let installer = CuaDriverInstaller(supportDirectory: root, processRunner: runner,
                                           externalApplicationURLs: [changed, reviewed])
        let installed = try await installer.validateOrInstall()
        #expect(installed.applicationURL == reviewed)
        #expect(runner.driverInvocationPaths.allSatisfy { $0 != changedExecutable.path })
        #expect(try String(contentsOf: changedExecutable, encoding: .utf8) == "untouched external executable")
    }

    @Test
    func processRunnerDrainsLargeStderrWhileReadingStdout() throws {
        // This owns bounded output and pipe draining. The stalled-command test
        // owns the short timeout contract. Allow parallel CI scheduling here.
        #expect(throws: CuaDriverInstallError.processFailed("Cua validation output exceeded limit")) {
            try SystemCuaProcessRunner(timeout: 10, outputLimit: 256).run(
                URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "head -c 2000000 /dev/zero >&2; printf ready"]
            )
        }
    }

    @Test
    func processRunnerStopsAStalledValidationCommand() throws {
        let start = ProcessInfo.processInfo.systemUptime
        #expect(throws: CuaDriverInstallError.processFailed("Cua validation command timed out")) {
            try SystemCuaProcessRunner(timeout: 0.2).run(
                URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "while :; do :; done"]
            )
        }
        #expect(ProcessInfo.processInfo.systemUptime - start < 2)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cua-installer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeFakeApplication(at application: URL) throws -> URL {
        let executable = application.appendingPathComponent("Contents/MacOS/cua-driver")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": CuaDriverCompatibility.bundleIdentifier], format: .xml, options: 0
        )
        try info.write(to: application.appendingPathComponent("Contents/Info.plist"))
        try Data("untouched external executable".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }
}

private final class FixedCuaProcessRunner: CuaProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let outdatedExecutablePaths: Set<String>
    private let mismatchedChecksumPaths: Set<String>
    private var calls: [[String]] = []
    private var driverPaths: [String] = []

    init(outdatedExecutablePaths: Set<String> = [], mismatchedChecksumPaths: Set<String> = []) {
        self.outdatedExecutablePaths = outdatedExecutablePaths
        self.mismatchedChecksumPaths = mismatchedChecksumPaths
    }

    var invocations: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var driverInvocationPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return driverPaths
    }

    func run(_ executable: URL, arguments: [String]) throws -> CuaProcessResult {
        lock.lock()
        calls.append(arguments)
        if arguments == ["manifest", "--pretty"] || arguments == ["list-tools"] { driverPaths.append(executable.path) }
        lock.unlock()
        if arguments.first == "--verify" { return CuaProcessResult(status: 0, stdout: Data(), stderr: Data()) }
        if arguments.first == "-dv" {
            return CuaProcessResult(
                status: 0,
                stdout: Data(),
                stderr: Data("Identifier=com.trycua.driver\nTeamIdentifier=YCK386LBJ7\n".utf8)
            )
        }
        if arguments.first == "-a" {
            let hash = mismatchedChecksumPaths.contains(arguments.last ?? "") ? "unreviewed" : CuaDriverCompatibility.executableSHA256
            return CuaProcessResult(status: 0, stdout: Data("\(hash)  reviewed-executable".utf8), stderr: Data())
        }
        if arguments == ["manifest", "--pretty"] {
            let version = outdatedExecutablePaths.contains(executable.path) ? "0.28.1" : CuaDriverCompatibility.version
            let json = "{\"binary_version\":\"\(version)\",\"schema_version\":\"1\"}"
            return CuaProcessResult(status: 0, stdout: Data(json.utf8), stderr: Data())
        }
        if arguments == ["list-tools"] {
            let output = CuaDriverCompatibility.requiredTools.sorted().map { "\($0): required" }.joined(separator: "\n")
            return CuaProcessResult(status: 0, stdout: Data(output.utf8), stderr: Data())
        }
        return CuaProcessResult(status: 1, stdout: Data(), stderr: Data())
    }
}
