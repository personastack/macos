import Foundation
import Testing
@testable import PersonaStackCore

struct CuaStandaloneServiceTests {
    @Test func explicitSetupCreatesIndependentServiceAndReusesItWithoutRewrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = StandaloneProcessRunner()
        let service = CuaStandaloneService(homeDirectory: root, processRunner: runner,
            peerInspector: { _ in
                guard runner.calls.contains(where: { $0.first == "bootstrap" }) else { throw CuaMCPProxyError.notStarted }
                return 1234
            })
        let installation = installation(root)
        #expect(service.socketURL == root.appendingPathComponent("Library/Caches/cua-driver/cua-driver.sock"))
        await #expect(throws: CuaMCPProxyError.notStarted) { try await service.inspectPeer(installation: installation) }
        #expect(runner.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        try await service.setup(installation: installation)
        let plistURL = root.appendingPathComponent("Library/LaunchAgents/com.trycua.cua-driver.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["ProgramArguments"] as? [String] == [installation.executableURL.path, "serve"])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["KeepAlive"] as? Bool == true)
        #expect(!String(decoding: data, as: UTF8.self).contains("PersonaStack"))
        try await service.setup(installation: installation)
        #expect(try Data(contentsOf: plistURL) == data)
        #expect(runner.calls.filter { $0.first == "bootstrap" }.count == 1)
        #expect(runner.calls.filter { $0.first == "kickstart" }.isEmpty)
        #expect(!runner.calls.contains { $0.contains("-k") })
        try await service.requestPermissions(installation: installation)
        #expect(runner.calls.last == ["permissions", "grant"])
        // Dropping a client/service owner has no shutdown path or daemon ownership.
        #expect(FileManager.default.fileExists(atPath: plistURL.path))
        #expect(!runner.calls.contains { $0.contains("bootout") || $0.contains("stop") || $0.contains("kill") })
    }

    @Test func setupPreservesAndRejectsConflictingExistingService() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("com.trycua.cua-driver.plist")
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "Label": "com.trycua.cua-driver", "ProgramArguments": ["/custom/driver", "serve"]
        ], format: .xml, options: 0)
        try data.write(to: url)
        let runner = StandaloneProcessRunner()
        let service = CuaStandaloneService(homeDirectory: root, processRunner: runner)
        await #expect(throws: CuaMCPProxyError.serviceMismatch) { try await service.setup(installation: installation(root)) }
        #expect(try Data(contentsOf: url) == data)
        #expect(runner.calls.isEmpty)
    }

    @Test func existingIndependentDaemonGetsLoginFileWithoutCompetingLaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = StandaloneProcessRunner()
        let service = CuaStandaloneService(homeDirectory: root, processRunner: runner,
            peerInspector: { _ in 1234 })
        try await service.setup(installation: installation(root))
        let file = root.appendingPathComponent("Library/LaunchAgents/com.trycua.cua-driver.plist")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(runner.calls.isEmpty)
        #expect(try await service.inspectPeer(installation: installation(root)) == 1234)
    }

    @Test func incompatibleLoadedServiceIsNeverKickedOrReplaced() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = StandaloneProcessRunner(loadedProgram: "/foreign/CuaDriver.app/Contents/MacOS/cua-driver")
        let service = CuaStandaloneService(homeDirectory: root, processRunner: runner)
        await #expect(throws: CuaMCPProxyError.serviceMismatch) {
            try await service.setup(installation: installation(root))
        }
        #expect(runner.calls.map { $0.first! } == ["print-disabled", "print"])
    }

    @Test func canceledSetupCannotCreateServiceOrRequestPermissions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let runner = StandaloneProcessRunner()
        let service = CuaStandaloneService(homeDirectory: root, processRunner: runner)
        let app = installation(root)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await service.setup(installation: app)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(runner.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func setupWaitsForSocketAfterLaunchWithoutStartingAnotherService() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = StandaloneProcessRunner()
        let attempts = StandalonePeerAttempts(readyAt: 4)
        let service = CuaStandaloneService(homeDirectory: root, processRunner: runner,
            peerInspector: { _ in try attempts.inspect() }, startupPause: {})
        try await service.setup(installation: installation(root))
        #expect(attempts.count == 4)
        #expect(runner.calls.map { $0.first! } == ["print-disabled", "print", "bootstrap"])
    }

    @Test func startupTimeoutIsFiniteAndDoesNotRestartCua() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = StandaloneProcessRunner()
        let attempts = StandalonePeerAttempts(readyAt: 1000)
        let service = CuaStandaloneService(homeDirectory: root, processRunner: runner,
            peerInspector: { _ in try attempts.inspect() }, startupTimeout: 5,
            monotonicNow: { Double(attempts.count) }, startupPause: {})
        await #expect(throws: CuaStandaloneServiceError.startTimedOut) { try await service.setup(installation: installation(root)) }
        #expect(attempts.count == 6)
        #expect(runner.calls.map { $0.first! } == ["print-disabled", "print", "bootstrap"])
    }

    @Test func cancellationDuringStartupStopsWaitingWithoutStoppingCua() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = StandaloneProcessRunner()
        let service = CuaStandaloneService(homeDirectory: root, processRunner: runner,
            peerInspector: { _ in throw CuaMCPProxyError.notStarted },
            startupPause: { throw CancellationError() })
        await #expect(throws: CancellationError.self) { try await service.setup(installation: installation(root)) }
        #expect(runner.calls.map { $0.first! } == ["print-disabled", "print", "bootstrap"])
    }

    @Test func mismatchedPeerAfterLaunchIsRejectedWithoutRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = StandaloneProcessRunner()
        let service = CuaStandaloneService(homeDirectory: root, processRunner: runner,
            peerInspector: { _ in
                if runner.calls.isEmpty { throw CuaMCPProxyError.notStarted }
                throw CuaMCPProxyError.serviceMismatch
            }, startupPause: { Issue.record("Mismatch must not retry") })
        await #expect(throws: CuaMCPProxyError.serviceMismatch) { try await service.setup(installation: installation(root)) }
        #expect(runner.calls.map { $0.first! } == ["print-disabled", "print", "bootstrap"])
    }

    @Test func permissionHandoffKeepsLaunchTimeoutExitAndCancellationDistinct() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cases: [(CuaProcessError, CuaStandaloneServiceError)] = [
            (.launchFailed, .permissionLaunchFailed), (.timedOut, .permissionTimedOut),
            (.outputDidNotClose, .permissionCommandFailed)
        ]
        for (failure, expected) in cases {
            let runner = FailingStandaloneRunner(failure: failure)
            let service = CuaStandaloneService(homeDirectory: root, permissionRunner: runner)
            await #expect(throws: expected) { try await service.requestPermissions(installation: installation(root)) }
            #expect(runner.calls == [["permissions", "grant"]])
        }
        let exited = CuaStandaloneService(homeDirectory: root, permissionRunner: FailingStandaloneRunner(failure: nil))
        await #expect(throws: CuaStandaloneServiceError.permissionCommandFailed) {
            try await exited.requestPermissions(installation: installation(root))
        }
        let cancelled = CuaStandaloneService(homeDirectory: root, permissionRunner: FailingStandaloneRunner(failure: CancellationError()))
        await #expect(throws: CancellationError.self) { try await cancelled.requestPermissions(installation: installation(root)) }
    }

    @Test func failedStartupCommandNeverClaimsReadiness() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = FailingStandaloneRunner(failure: nil)
        let service = CuaStandaloneService(homeDirectory: root, processRunner: runner,
            peerInspector: { _ in throw CuaMCPProxyError.notStarted })
        await #expect(throws: CuaStandaloneServiceError.startFailed) { try await service.setup(installation: installation(root)) }
        #expect(runner.calls.map { $0.first! } == ["print-disabled", "print", "bootstrap"])
    }

    @Test func explicitlyDisabledLoginServiceIsPreserved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = installation(root)
        let directory = root.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(CuaStandaloneService.label + ".plist")
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "Label": CuaStandaloneService.label, "ProgramArguments": [app.executableURL.path, "serve"], "Disabled": true
        ], format: .xml, options: 0)
        try data.write(to: url)
        let runner = StandaloneProcessRunner()
        let service = CuaStandaloneService(homeDirectory: root, processRunner: runner)
        await #expect(throws: CuaStandaloneServiceError.serviceDisabled) { try await service.setup(installation: app) }
        #expect(try Data(contentsOf: url) == data)
        #expect(runner.calls.isEmpty)
    }

    @Test func launchdDisabledOverrideDoesNotGetReenabledOrStarted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = StandaloneProcessRunner(disabled: true)
        let service = CuaStandaloneService(homeDirectory: root, processRunner: runner,
            peerInspector: { _ in throw CuaMCPProxyError.notStarted })
        await #expect(throws: CuaStandaloneServiceError.serviceDisabled) {
            try await service.setup(installation: installation(root))
        }
        #expect(runner.calls.map { $0.first! } == ["print-disabled"])
    }

    @Test func conflictingPeerIsRejectedBeforeCreatingLoginConfiguration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = StandaloneProcessRunner()
        let service = CuaStandaloneService(homeDirectory: root, processRunner: runner,
            peerInspector: { _ in throw CuaMCPProxyError.serviceMismatch })
        await #expect(throws: CuaMCPProxyError.serviceMismatch) {
            try await service.setup(installation: installation(root))
        }
        #expect(runner.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    private func installation(_ root: URL) -> CuaDriverInstallation {
        let app = root.appendingPathComponent("Applications/CuaDriver.app")
        return CuaDriverInstallation(applicationURL: app,
            executableURL: app.appendingPathComponent("Contents/MacOS/cua-driver"),
            version: CuaDriverCompatibility.version, toolNames: CuaDriverCompatibility.requiredTools)
    }
}

private final class StandaloneProcessRunner: CuaProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private var loaded = false
    private var program = ""
    private let disabled: Bool
    init(loadedProgram: String? = nil, disabled: Bool = false) {
        self.disabled = disabled
        if let loadedProgram { loaded = true; program = loadedProgram }
    }
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return recorded }
    func run(_ executable: URL, arguments: [String]) throws -> CuaProcessResult {
        lock.lock(); defer { lock.unlock() }
        recorded.append(arguments)
        if arguments.first == "print-disabled" {
            let output = disabled ? "disabled services = {\n\t\"com.trycua.cua-driver\" => true\n}" : "disabled services = {}"
            return CuaProcessResult(status: 0, stdout: Data(output.utf8), stderr: Data())
        }
        if arguments.first == "print" { return CuaProcessResult(status: loaded ? 0 : 1, stdout: Data("program = \(program)\n".utf8), stderr: Data()) }
        if arguments.first == "bootstrap" {
            loaded = true
            let data = try Data(contentsOf: URL(fileURLWithPath: arguments.last!))
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            program = (plist?["ProgramArguments"] as? [String])?.first ?? ""
        }
        return CuaProcessResult(status: 0, stdout: Data(), stderr: Data())
    }
}

private final class StandalonePeerAttempts: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private let readyAt: Int
    init(readyAt: Int) { self.readyAt = readyAt }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func inspect() throws -> Int32 {
        lock.lock(); defer { lock.unlock() }
        value += 1
        guard value >= readyAt else { throw CuaMCPProxyError.notStarted }
        return 1234
    }
}

private final class FailingStandaloneRunner: CuaProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private let failure: (any Error)?
    init(failure: (any Error)?) { self.failure = failure }
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return recorded }
    func run(_ executable: URL, arguments: [String]) throws -> CuaProcessResult {
        lock.lock(); recorded.append(arguments); lock.unlock()
        if let failure { throw failure }
        if arguments.first == "print-disabled" { return CuaProcessResult(status: 0, stdout: Data(), stderr: Data()) }
        return CuaProcessResult(status: 1, stdout: Data(), stderr: Data("private diagnostic".utf8))
    }
}
