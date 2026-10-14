import AppKit
import Foundation
import PersonaStackCore
import Testing
@testable import PersonaStack

private struct QuitInstaller: DesktopControlDriverInstalling {
    func discoverExisting() async throws -> CuaDriverInstallation? {
        Issue.record("Quit must not inspect or install CUA")
        return nil
    }
    func install() async throws -> CuaDriverInstallation {
        throw CuaDriverInstallError.invalidLayout
    }
}

private struct QuitCredentials: DesktopControlCredentialStoring {
    func load() throws -> DesktopControlInstallation? {
        Issue.record("Quit must not read credentials")
        return nil
    }
    func save(_ installation: DesktopControlInstallation) throws {
        Issue.record("Quit must not change credentials")
    }
    func delete() throws { Issue.record("Quit must not delete credentials") }
}

@MainActor private final class QuitCleanupBarrier {
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
}

@Test @MainActor func productionQuitRefusesFailedControlCleanupAndRetries() async throws {
    let preferences = try #require(UserDefaults(suiteName: "DesktopControlQuitTests." + UUID().uuidString))
    let executor = DesktopControlCommandExecutor()
    executor.failNextCleanupForTesting()
    let runtime = DesktopControlRuntime.makeForTesting(installer: QuitInstaller(), credentials: QuitCredentials(),
        executor: executor, preferences: preferences)
    var exits = 0
    var failures = 0
    var intents = 0
    var cleaned = false
    let delegate = PersonaStackTerminationDelegate(shutdown: {
        let result = await PersonaStackTerminationDelegate.cleanupControlForQuit(runtime)
        cleaned = true
        return result
    }, terminate: { _ in exits += 1 }, timeout: .seconds(1),
        hasActiveSessions: { PersonaStackTerminationDelegate.controlCleanupPendingForQuit(runtime) },
        showCleanupFailure: { failures += 1 }, recordQuitIntent: { intents += 1 })
    #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
    while !cleaned { await Task.yield() }
    #expect(runtime.executorCleanupFailedForTesting)
    #expect(!runtime.isDisconnecting)
    #expect(PersonaStackTerminationDelegate.controlCleanupPendingForQuit(runtime))
    #expect(failures == 1)
    try #require(exits == 0 && intents == 0 && failures == 1)

    cleaned = false
    #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
    while !cleaned { await Task.yield() }
    #expect(!runtime.executorCleanupFailedForTesting)
    #expect(!PersonaStackTerminationDelegate.controlCleanupPendingForQuit(runtime))
    #expect(exits == 1 && intents == 1 && failures == 1)
    #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
}

@Test @MainActor func productionQuitDeadlineWaitsForPendingControlCleanup() async throws {
    let preferences = try #require(UserDefaults(suiteName: "DesktopControlQuitTests." + UUID().uuidString))
    let executor = DesktopControlCommandExecutor()
    let barrier = QuitCleanupBarrier()
    executor.pauseCleanupBeforeResourceCloseForTesting { await barrier.wait() }
    let runtime = DesktopControlRuntime.makeForTesting(installer: QuitInstaller(), credentials: QuitCredentials(),
        executor: executor, preferences: preferences)
    var exits = 0
    var failures = 0
    var cleaned = false
    let delegate = PersonaStackTerminationDelegate(shutdown: {
        let result = await PersonaStackTerminationDelegate.cleanupControlForQuit(runtime)
        cleaned = true
        return result
    }, terminate: { _ in exits += 1 }, timeout: .milliseconds(10),
        hasActiveSessions: { PersonaStackTerminationDelegate.controlCleanupPendingForQuit(runtime) },
        showCleanupFailure: { failures += 1 })
    #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
    while barrier.continuation == nil { await Task.yield() }
    #expect(PersonaStackTerminationDelegate.controlCleanupPendingForQuit(runtime))
    while exits + failures == 0 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(exits == 0 && failures == 1)
    barrier.continuation?.resume()
    while !cleaned { await Task.yield() }
    #expect(!PersonaStackTerminationDelegate.controlCleanupPendingForQuit(runtime))
    #expect(exits == 1 && failures == 1)
}
