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
        let installationRoot = root.appendingPathComponent("Applications", isDirectory: true)
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
        let installer = CuaDriverInstaller(supportDirectory: root, processRunner: runner, externalApplicationURLs: [app])

        let stages = CuaInstallStageRecorder()
        let installed = try await installer.install { await stages.append($0) }

        #expect(await stages.values == [.checking, .installed])
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

    @Test func missingDiscoveryDoesNotInstallOrRunCommands() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = FixedCuaProcessRunner()
        let installer = CuaDriverInstaller(supportDirectory: root, processRunner: runner,
            externalApplicationURLs: [root.appendingPathComponent("missing/CuaDriver.app")])
        #expect(try await installer.discoverExisting() == nil)
        #expect(runner.invocations.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test
    func compatibleExternalApplicationIsReusedWithoutManagedInstallOrMutation() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let application = root.appendingPathComponent("Applications/CuaDriver.app", isDirectory: true)
        let executable = try makeFakeApplication(at: application)
        let runner = FixedCuaProcessRunner()
        let installer = CuaDriverInstaller(supportDirectory: root, processRunner: runner, externalApplicationURLs: [application])

        let installed = try await installer.install()

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

        let installed = try await installer.install()

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
        let installed = try await installer.install()
        #expect(installed.applicationURL == reviewed)
        #expect(runner.driverInvocationPaths.allSatisfy { $0 != changedExecutable.path })
        #expect(try String(contentsOf: changedExecutable, encoding: .utf8) == "untouched external executable")
    }

    @Test
    func processRunnerDrainsLargeStderrWhileReadingStdout() throws {
        // This owns bounded output and pipe draining. The stalled-command test
        // owns the short timeout contract. Allow parallel CI scheduling here.
        #expect(throws: CuaProcessError.outputLimitExceeded) {
            try SystemCuaProcessRunner(timeout: 10, outputLimit: 256).run(
                URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "head -c 2000000 /dev/zero >&2; printf ready"]
            )
        }
    }

    @Test
    func processRunnerStopsAStalledValidationCommand() throws {
        let start = ProcessInfo.processInfo.systemUptime
        #expect(throws: CuaProcessError.timedOut) {
            try SystemCuaProcessRunner(timeout: 0.2).run(
                URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "while :; do :; done"]
            )
        }
        #expect(ProcessInfo.processInfo.systemUptime - start < 2)
    }

    @Test
    func failedDownloadReportsItsStageWithoutClaimingInstallation() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CuaFailedDownloadProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let application = root.appendingPathComponent("Applications/CuaDriver.app")
        let runner = FixedCuaProcessRunner()
        let installer = CuaDriverInstaller(supportDirectory: root, processRunner: runner,
            session: session, externalApplicationURLs: [application])
        let stages = CuaInstallStageRecorder()
        await #expect(throws: CuaDriverInstallError.downloadFailed) {
            try await installer.install { await stages.append($0) }
        }
        #expect(await stages.values == [.checking, .downloading])
        #expect(!FileManager.default.fileExists(atPath: application.path))
        #expect(runner.invocations.isEmpty)
    }

    @Test func installedDestinationIsReadBackBeforeSuccess() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("staging/CuaDriver.app")
        _ = try makeFakeApplication(at: source)
        let destination = root.appendingPathComponent("CuaDriver.app")
        let runner = FixedCuaProcessRunner()
        let installer = CuaDriverInstaller(supportDirectory: root, processRunner: runner, externalApplicationURLs: [destination])
        let installed = try await installer.placeValidatedApplication(source, at: destination)
        #expect(installed.applicationURL == destination)
        #expect(runner.driverInvocationPaths == [installed.executableURL.path, installed.executableURL.path])
        #expect(!FileManager.default.fileExists(atPath: source.path))
        let retry = try await installer.install()
        #expect(retry == installed)
    }

    @Test func concurrentCompatibleDestinationIsReusedWithoutOverwrite() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("staging/CuaDriver.app")
        _ = try makeFakeApplication(at: source)
        let destination = root.appendingPathComponent("CuaDriver.app")
        let executable = try makeFakeApplication(at: destination)
        let installer = CuaDriverInstaller(supportDirectory: root, processRunner: FixedCuaProcessRunner(), externalApplicationURLs: [destination])
        let installed = try await installer.placeValidatedApplication(source, at: destination)
        #expect(installed.applicationURL == destination)
        #expect(try String(contentsOf: executable, encoding: .utf8) == "untouched external executable")
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func conflictingDestinationSurvivesFailedReadback() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("staging/CuaDriver.app")
        _ = try makeFakeApplication(at: source)
        let destination = root.appendingPathComponent("CuaDriver.app")
        let executable = try makeFakeApplication(at: destination)
        let runner = FixedCuaProcessRunner(mismatchedChecksumPaths: [executable.path])
        let installer = CuaDriverInstaller(supportDirectory: root, processRunner: runner, externalApplicationURLs: [destination])
        await #expect(throws: CuaDriverInstallError.checksumMismatch) {
            try await installer.placeValidatedApplication(source, at: destination)
        }
        #expect(try String(contentsOf: executable, encoding: .utf8) == "untouched external executable")
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(runner.driverInvocationPaths.isEmpty)
    }

    @Test func placementFailureHasSafeSpecificError() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = CuaDriverInstaller(supportDirectory: root)
        await #expect(throws: CuaDriverInstallError.placementFailed) {
            try await installer.placeValidatedApplication(root.appendingPathComponent("absent"), at: root.appendingPathComponent("CuaDriver.app"))
        }
    }

    @Test func inheritedPipeCannotKeepCommandReaderAlive() throws {
        let start = ProcessInfo.processInfo.systemUptime
        #expect(throws: CuaProcessError.outputDidNotClose) {
            try SystemCuaProcessRunner(timeout: 5).run(URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 2 & exit 0"])
        }
        #expect(ProcessInfo.processInfo.systemUptime - start < 1.9)
    }

    @Test func cancellingOwnedCommandSettlesItsPipesAndTask() async throws {
        let task = Task.detached {
            try SystemCuaProcessRunner(timeout: 10).run(URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "while :; do printf working; done"])
        }
        try await Task.sleep(for: .milliseconds(50))
        let start = ProcessInfo.processInfo.systemUptime
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ProcessInfo.processInfo.systemUptime - start < 2)
    }

    @Test func processLaunchFailureDoesNotExposeSystemError() throws {
        #expect(throws: CuaProcessError.launchFailed) {
            try SystemCuaProcessRunner().run(URL(fileURLWithPath: "/no-such-cua-command"), arguments: [])
        }
    }

    @Test(arguments: [false, true])
    func totalDownloadDeadlineCoversNoResponseAndIncompleteProgress(partial: Bool) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = partial ? [CuaPartialDownloadProtocol.self] : [CuaStalledDownloadProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let app = root.appendingPathComponent("Applications/CuaDriver.app")
        let runner = FixedCuaProcessRunner()
        let installer = CuaDriverInstaller(supportDirectory: root, processRunner: runner,
            session: session, externalApplicationURLs: [app], downloadTimeout: 0.05)
        let start = ProcessInfo.processInfo.systemUptime
        await #expect(throws: CuaDriverInstallError.downloadTimedOut) { try await installer.install() }
        #expect(ProcessInfo.processInfo.systemUptime - start < 2)
        #expect(!FileManager.default.fileExists(atPath: app.path))
        #expect(runner.invocations.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".cua-install-") })
    }

    @Test func cancelDownloadPreservesCancellationAndReleasesStaging() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CuaStalledDownloadProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let installer = CuaDriverInstaller(supportDirectory: root, session: session,
            externalApplicationURLs: [root.appendingPathComponent("Applications/CuaDriver.app")])
        let task = Task { try await installer.install() }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".cua-install-") })
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

private actor CuaInstallStageRecorder {
    var values: [CuaInstallStage] = []
    func append(_ stage: CuaInstallStage) { values.append(stage) }
}

private final class CuaFailedDownloadProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

private class CuaStalledDownloadProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

private final class CuaPartialDownloadProtocol: CuaStalledDownloadProtocol, @unchecked Sendable {
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "1000"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("partial".utf8))
        // Keep the response open: progress must not extend the total deadline.
    }
}
