import Foundation
import Testing
import PersonaStackCore
@testable import PersonaStack

private enum IMessageLifecycleAuthorityError: Error { case unavailable }

private actor IMessageLifecycleAuthority: DesktopControlRelayStateReading {
    private var state: DesktopControlConfigurationState
    private var unavailable = false
    private var suspendRead = false
    private var pendingRead: CheckedContinuation<Void, Never>?
    private var pendingEntry: CheckedContinuation<Void, Never>?
    private(set) var reads = 0

    init(desktop: Bool = false, iMessage: Bool = false) {
        state = .init(hasActiveConfig: desktop, hasConfig: desktop,
                      hasActiveIMessageConfig: iMessage, hasIMessageConfig: iMessage)
    }
    func replace(desktop: Bool = false, iMessage: Bool = false) {
        state = .init(hasActiveConfig: desktop, hasConfig: desktop,
                      hasActiveIMessageConfig: iMessage, hasIMessageConfig: iMessage)
    }
    func fail() { unavailable = true }
    func suspendNextRead() { suspendRead = true }
    func waitForRead() async {
        if pendingRead != nil { return }
        await withCheckedContinuation { pendingEntry = $0 }
    }
    func releaseRead() { pendingRead?.resume(); pendingRead = nil }
    func configurationState(installation: DesktopControlInstallation, appURL: URL) async throws -> DesktopControlConfigurationState {
        #expect(installation.installationID == "lifecycle-mac")
        #expect(appURL == DesktopEnvironmentConfiguration.production.appPageURL)
        reads += 1
        let result = state
        if suspendRead {
            suspendRead = false
            await withCheckedContinuation {
                pendingRead = $0
                pendingEntry?.resume()
                pendingEntry = nil
            }
        }
        if unavailable { throw IMessageLifecycleAuthorityError.unavailable }
        return result
    }
}

private actor IMessageLifecycleInstaller: DesktopControlDriverInstalling {
    private(set) var discoveries = 0
    private(set) var installs = 0
    func discoverExisting() async throws -> CuaDriverInstallation? {
        discoveries += 1
        throw CuaMCPProxyError.notStarted
    }
    func install() async throws -> CuaDriverInstallation {
        installs += 1
        Issue.record("Relay intent must not install CUA")
        throw CuaMCPProxyError.notStarted
    }
}

private actor IMessageLifecycleCuaService: DesktopControlCuaServicing {
    nonisolated let socketURL = URL(fileURLWithPath: "/fixture/never-open-cua.sock")
    private(set) var calls = 0
    func setup(installation: CuaDriverInstallation) async throws { calls += 1; Issue.record("Unexpected CUA setup") }
    func requestPermissions(installation: CuaDriverInstallation) async throws { calls += 1; Issue.record("Unexpected permission request") }
    func inspectPeer(installation: CuaDriverInstallation) async throws -> Int32 { calls += 1; Issue.record("Unexpected CUA inspection"); return 0 }
}

private final class IMessageLifecycleCredentials: DesktopControlCredentialStoring, @unchecked Sendable {
    let installation: DesktopControlInstallation
    private let lock = NSLock()
    private var reads = 0
    var readCount: Int { lock.withLock { reads } }
    init(installation: DesktopControlInstallation) { self.installation = installation }
    func load() throws -> DesktopControlInstallation? { lock.withLock { reads += 1; return installation } }
    func save(_ installation: DesktopControlInstallation) throws { Issue.record("Relay lifecycle must not replace credentials") }
    func delete() throws { Issue.record("Relay lifecycle must not delete credentials") }
}

@MainActor
private final class IMessageLifecycleFixture {
    let authority: IMessageLifecycleAuthority
    let installer = IMessageLifecycleInstaller()
    let service = IMessageLifecycleCuaService()
    let credentials: IMessageLifecycleCredentials
    let runtime: DesktopControlRuntime
    var socketAttempts = 0
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    let connectionID = UUID()
    let digest = String(repeating: "A", count: 43)
    var expiry: Date { now.addingTimeInterval(3600) }

    init(desktop: Bool = false, iMessage: Bool = false, connected: Bool = false,
         executor: DesktopControlCommandExecutor? = nil) throws {
        authority = IMessageLifecycleAuthority(desktop: desktop, iMessage: iMessage)
        let installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: Data(#"{"installation_id":"lifecycle-mac","machine_credential":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","gateway_websocket_url":"wss://cluster-agent.personastack.ai/v1/desktop-control/ws","environment_origin":"https://my.personastack.ai"}"#.utf8))
        credentials = IMessageLifecycleCredentials(installation: installation)
        let preferences = try #require(UserDefaults(suiteName: "IMessageRelayLifecycle-\(UUID().uuidString)"))
        runtime = DesktopControlRuntime.makeForTesting(installer: installer, cuaService: service,
            credentials: credentials, executor: executor, connectionID: connectionID, installation: installation, connected: connected,
            sessionLockState: .unlocked, relayStateReader: authority, scheduleReconnect: false, preferences: preferences)
        runtime.setRelayClockForTesting { [weak self] in self?.now ?? .distantFuture }
        runtime.setRelayConnectionAttemptForTesting { [weak self] in self?.socketAttempts += 1 }
    }

    func assertNoCua() async {
        #expect(await installer.discoveries == 0)
        #expect(await installer.installs == 0)
        #expect(await service.calls == 0)
    }
}

@Test(arguments: [false, true], [false, true]) @MainActor
func iMessageRelayLifecycleStartupKeepsEachFamilySeparate(desktop: Bool, iMessage: Bool) async throws {
    let fixture = try IMessageLifecycleFixture(desktop: desktop, iMessage: iMessage)
    if desktop {
        await #expect(throws: CuaMCPProxyError.notStarted) { try await fixture.runtime.resume() }
        #expect(await fixture.installer.discoveries == 1)
    } else {
        try await fixture.runtime.resume()
        await fixture.assertNoCua()
        #expect((fixture.socketAttempts > 0) == iMessage)
        if iMessage {
            #expect(await fixture.runtime.heartbeatReadinessForTesting() == "unknown")
            await fixture.assertNoCua()
        }
    }
    #expect(fixture.runtime.hasDesktopControlIntentForTesting == desktop)
    #expect(await fixture.installer.installs == 0)
    #expect(await fixture.service.calls == 0)
    await fixture.runtime.shutdownForQuit()
}

@Test @MainActor
func iMessageRelayLifecycleTemporarySetupNeverStartsCuaAndReleasesOnlyItself() async throws {
    let fixture = try IMessageLifecycleFixture()
    let generation = try fixture.runtime.beginResume()
    let expiry = fixture.expiry
    try await fixture.runtime.resumeForIMessageSetup(generation: generation,
        setupReferenceSHA256: fixture.digest, journeyGeneration: 1, expiresAt: expiry)
    #expect(fixture.runtime.hasIMessageSetupIntentForTesting)
    #expect(fixture.socketAttempts > 0)
    #expect(!fixture.runtime.hasDesktopControlIntentForTesting)
    #expect(await fixture.runtime.heartbeatReadinessForTesting() == "unknown")
    await fixture.assertNoCua()
    try await fixture.runtime.finishIMessageSetupIfIdle(generation: generation,
        setupReferenceSHA256: fixture.digest, journeyGeneration: 1, expiresAt: expiry)
    #expect(!fixture.runtime.hasIMessageSetupIntentForTesting)
    #expect(!fixture.runtime.hasActiveInstallation)
    #expect(!fixture.runtime.gatewayConnected)
    await fixture.assertNoCua()
    await fixture.runtime.shutdownForQuit()
}

@Test(arguments: ["desktop", "imessage", "desktop_setup"]) @MainActor
func iMessageRelayLifecycleSetupReleasePreservesIndependentIntent(family: String) async throws {
    let fixture = try IMessageLifecycleFixture(desktop: family == "desktop", iMessage: family == "imessage", connected: true)
    let generation = try fixture.runtime.beginResume()
    if family == "desktop_setup" {
        await #expect(throws: CuaMCPProxyError.notStarted) { try await fixture.runtime.resumeForSetup(generation: generation) }
    }
    let expiry = fixture.expiry
    try await fixture.runtime.resumeForIMessageSetup(generation: generation,
        setupReferenceSHA256: fixture.digest, journeyGeneration: 1, expiresAt: expiry)
    try await fixture.runtime.finishIMessageSetupIfIdle(generation: generation,
        setupReferenceSHA256: fixture.digest, journeyGeneration: 1, expiresAt: expiry)
    #expect(!fixture.runtime.hasIMessageSetupIntentForTesting)
    #expect(fixture.runtime.hasActiveInstallation)
    #expect(fixture.runtime.gatewayConnected)
    #expect(fixture.runtime.hasDesktopControlIntentForTesting == (family != "imessage"))
    #expect(await fixture.installer.discoveries == (family == "desktop_setup" ? 1 : 0))
    #expect(await fixture.service.calls == 0)
    await fixture.runtime.shutdownForQuit()
}

@Test @MainActor
func iMessageRelayLifecycleDesktopSetupClosureKeepsIMessageIntent() async throws {
    let fixture = try IMessageLifecycleFixture(connected: true)
    let generation = try fixture.runtime.beginResume()
    await #expect(throws: CuaMCPProxyError.notStarted) { try await fixture.runtime.resumeForSetup(generation: generation) }
    try await fixture.runtime.resumeForIMessageSetup(generation: generation,
        setupReferenceSHA256: fixture.digest, journeyGeneration: 1, expiresAt: fixture.expiry)
    try await fixture.runtime.finishSetupIfIdle()
    #expect(fixture.runtime.hasIMessageSetupIntentForTesting)
    #expect(!fixture.runtime.hasDesktopControlIntentForTesting)
    #expect(fixture.runtime.gatewayConnected)
    await fixture.runtime.shutdownForQuit()
}

@Test @MainActor
func iMessageRelayLifecycleExactReceiptFencesReplacementAndKeepsOriginalExpiry() async throws {
    let fixture = try IMessageLifecycleFixture()
    let generation = try fixture.runtime.beginResume()
    let expiry = fixture.expiry
    for journeyGeneration in [Int64(1), Int64(2)] {
        try await fixture.runtime.resumeForIMessageSetup(generation: generation,
            setupReferenceSHA256: fixture.digest, journeyGeneration: journeyGeneration, expiresAt: expiry)
    }
    try await fixture.runtime.finishIMessageSetupIfIdle(generation: generation,
        setupReferenceSHA256: fixture.digest, journeyGeneration: 1, expiresAt: expiry)
    #expect(fixture.runtime.hasIMessageSetupIntentForTesting)
    await #expect(throws: DesktopControlEnrollmentError.invalidRequest) {
        try await fixture.runtime.resumeForIMessageSetup(generation: generation,
            setupReferenceSHA256: fixture.digest, journeyGeneration: 2, expiresAt: expiry.addingTimeInterval(1))
    }
    await #expect(throws: DesktopControlEnrollmentError.invalidRequest) {
        try await fixture.runtime.resumeForIMessageSetup(generation: generation,
            setupReferenceSHA256: fixture.digest, journeyGeneration: 1, expiresAt: expiry)
    }
    fixture.now = expiry
    #expect(!fixture.runtime.hasIMessageSetupIntentForTesting)
    await #expect(throws: DesktopControlEnrollmentError.invalidRequest) {
        try await fixture.runtime.resumeForIMessageSetup(generation: generation,
            setupReferenceSHA256: fixture.digest, journeyGeneration: 3, expiresAt: expiry.addingTimeInterval(3600))
    }
    try await fixture.runtime.reconcileRelayForTesting()
    #expect(!fixture.runtime.hasActiveInstallation)
    await fixture.assertNoCua()
    await fixture.runtime.shutdownForQuit()
}

@Test(arguments: ["short_digest", "noncanonical_digest", "zero_generation", "expired", "over_24_hours"]) @MainActor
func iMessageRelayLifecycleRejectsInvalidSetupBeforeConnecting(reason: String) async throws {
    let fixture = try IMessageLifecycleFixture()
    let generation = try fixture.runtime.beginResume()
    let digest = reason == "short_digest" ? "A" : (reason == "noncanonical_digest" ? String(repeating: "A", count: 42) + "B" : fixture.digest)
    let journeyGeneration: Int64 = reason == "zero_generation" ? 0 : 1
    let expiry = reason == "expired" ? fixture.now : (reason == "over_24_hours" ? fixture.now.addingTimeInterval(86401) : fixture.expiry)
    await #expect(throws: DesktopControlEnrollmentError.invalidRequest) {
        try await fixture.runtime.resumeForIMessageSetup(generation: generation,
            setupReferenceSHA256: digest, journeyGeneration: journeyGeneration, expiresAt: expiry)
    }
    #expect(fixture.socketAttempts == 0)
    #expect(fixture.credentials.readCount == 0)
    #expect(!fixture.runtime.hasIMessageSetupIntentForTesting)
    await fixture.assertNoCua()
    await fixture.runtime.shutdownForQuit()
}

@Test @MainActor
func iMessageRelayLifecyclePauseAndRecoveryPreserveIMessageWithoutCua() async throws {
    let fixture = try IMessageLifecycleFixture(connected: true)
    let generation = try fixture.runtime.beginResume()
    let expiry = fixture.expiry
    try await fixture.runtime.resumeForIMessageSetup(generation: generation,
        setupReferenceSHA256: fixture.digest, journeyGeneration: 1, expiresAt: expiry)
    await fixture.runtime.pause()
    #expect(fixture.runtime.paused && fixture.runtime.gatewayConnected)
    #expect(fixture.runtime.hasIMessageSetupIntentForTesting)
    fixture.runtime.signalLifecycleLossForTesting()
    await fixture.runtime.waitForLockCleanupForTesting()
    fixture.runtime.requestConnectionRecoveryForTesting()
    await fixture.runtime.waitForSessionLockChangeForTesting()
    #expect(fixture.runtime.hasIMessageSetupIntentForTesting)
    #expect(await fixture.runtime.heartbeatReadinessForTesting() == "paused")
    await fixture.assertNoCua()
    await fixture.authority.replace(desktop: true)
    try await fixture.runtime.finishIMessageSetupIfIdle(generation: generation,
        setupReferenceSHA256: fixture.digest, journeyGeneration: 1, expiresAt: expiry)
    #expect(!fixture.runtime.hasIMessageSetupIntentForTesting)
    #expect(fixture.runtime.gatewayConnected)
    #expect(fixture.runtime.hasDesktopControlIntentForTesting)
    await fixture.assertNoCua()
    await fixture.runtime.shutdownForQuit()
    #expect(!fixture.runtime.gatewayConnected)
}

@Test @MainActor
func iMessageRelayLifecycleAuthorityFailurePreservesSocketWithoutStartingCua() async throws {
    let fixture = try IMessageLifecycleFixture(connected: true)
    await fixture.authority.fail()
    try await fixture.runtime.resume()
    #expect(fixture.runtime.gatewayConnected)
    #expect(await fixture.runtime.heartbeatReadinessForTesting() == "unknown")
    await #expect(throws: IMessageLifecycleAuthorityError.unavailable) { try await fixture.runtime.reconcileRelayForTesting() }
    #expect(fixture.runtime.gatewayConnected)
    await fixture.assertNoCua()
    await fixture.runtime.shutdownForQuit()
}

@Test @MainActor
func iMessageRelayLifecycleLateAuthorityCannotCrossEnvironmentSwitch() async throws {
    let fixture = try IMessageLifecycleFixture(desktop: true, connected: true)
    await fixture.authority.suspendNextRead()
    let read = Task { try await fixture.runtime.finishSetupIfIdle() }
    await fixture.authority.waitForRead()
    try await fixture.runtime.prepareForEnvironmentSwitch()
    await fixture.authority.releaseRead()
    await #expect(throws: CancellationError.self) { try await read.value }
    #expect(!fixture.runtime.hasDesktopControlIntentForTesting)
    #expect(!fixture.runtime.hasIMessageSetupIntentForTesting)
    #expect(!fixture.runtime.gatewayConnected)
    await fixture.assertNoCua()
    await fixture.runtime.shutdownForQuit()
}

@Test @MainActor
func iMessageRelayLifecycleDoesNotGrantDesktopExecutionOrProbeCuaForStatus() async throws {
    let fixture = try IMessageLifecycleFixture(iMessage: true, connected: true)
    try await fixture.runtime.reconcileRelayForTesting()
    let target = DesktopControlTarget(installationID: "lifecycle-mac", workspaceID: "w", configID: "c",
        personaID: "p", runID: "r", generation: 1)
    let acquire = DesktopControlFrame(type: "command", requestID: "acquire", target: target,
        operation: "desktop_control_acquire", arguments: .object([:]), deadlineAt: .distantFuture)
    let denied = await fixture.runtime.handleForTesting(acquire, connectionID: fixture.connectionID)
    #expect(denied.type == "failure" && denied.errorCode == "desktop_executor_unavailable")
    let status = DesktopControlFrame(type: "command", requestID: "status", target: target,
        operation: "desktop_control_status", arguments: .object([:]), deadlineAt: .distantFuture)
    let response = await fixture.runtime.handleForTesting(status, connectionID: fixture.connectionID)
    #expect(response.type == "result")
    guard case .object(let result)? = response.result else { Issue.record("Missing status result"); return }
    #expect(result["available"] == .bool(false))
    #expect(result["gui_ready"] == .bool(false))
    await fixture.assertNoCua()
    await fixture.runtime.shutdownForQuit()
}

@Test @MainActor
func iMessageRelayLifecycleFailedRefreshCannotRestartCuaFromCachedDesktopFlags() async throws {
    let fixture = try IMessageLifecycleFixture(desktop: true, connected: true)
    try await fixture.runtime.reconcileRelayForTesting()
    #expect(fixture.runtime.hasDesktopControlIntentForTesting)
    await fixture.authority.fail()
    try await fixture.runtime.resume()
    #expect(fixture.runtime.gatewayConnected)
    #expect(await fixture.runtime.heartbeatReadinessForTesting() == "unknown")
    await fixture.assertNoCua()
    await fixture.runtime.shutdownForQuit()
}

@Test @MainActor
func iMessageRelayLifecycleOlderAuthorityReadCannotRestoreRemovedDesktopIntent() async throws {
    let fixture = try IMessageLifecycleFixture(desktop: true, connected: true)
    await fixture.authority.suspendNextRead()
    let oldRead = Task { try await fixture.runtime.reconcileRelayForTesting() }
    await fixture.authority.waitForRead()
    await fixture.authority.replace(iMessage: true)
    try await fixture.runtime.reconcileRelayForTesting()
    await fixture.authority.releaseRead()
    await #expect(throws: CancellationError.self) { try await oldRead.value }
    #expect(!fixture.runtime.hasDesktopControlIntentForTesting)
    #expect(fixture.runtime.gatewayConnected)
    #expect(await fixture.runtime.heartbeatReadinessForTesting() == "unknown")
    await fixture.assertNoCua()
    await fixture.runtime.shutdownForQuit()
}

@Test @MainActor
func iMessageRelayLifecycleOlderLocalSetupCallbackCannotReleaseReplacement() async throws {
    let fixture = try IMessageLifecycleFixture()
    let original = try fixture.runtime.beginResume()
    let expiry = fixture.expiry
    try await fixture.runtime.resumeForIMessageSetup(generation: original,
        setupReferenceSHA256: fixture.digest, journeyGeneration: 1, expiresAt: expiry)
    let replacement = try fixture.runtime.beginResume()
    try await fixture.runtime.resumeForIMessageSetup(generation: replacement,
        setupReferenceSHA256: fixture.digest, journeyGeneration: 2, expiresAt: expiry)
    try await fixture.runtime.finishIMessageSetupIfIdle(generation: original,
        setupReferenceSHA256: fixture.digest, journeyGeneration: 1, expiresAt: expiry)
    #expect(fixture.runtime.hasIMessageSetupIntentForTesting)
    await fixture.assertNoCua()
    await fixture.runtime.shutdownForQuit()
}

@Test @MainActor
func iMessageRelayLifecycleReconnectAndExpiryUseTheSameSharedSocketOwner() async throws {
    let fixture = try IMessageLifecycleFixture()
    let generation = try fixture.runtime.beginResume()
    let expiry = fixture.expiry
    try await fixture.runtime.resumeForIMessageSetup(generation: generation,
        setupReferenceSHA256: fixture.digest, journeyGeneration: 1, expiresAt: expiry)
    let attempts = fixture.socketAttempts
    #expect(await fixture.runtime.reconnectRelayForTesting())
    #expect(fixture.socketAttempts == attempts + 1)
    fixture.now = expiry
    #expect(!(await fixture.runtime.reconnectRelayForTesting()))
    #expect(!fixture.runtime.hasActiveInstallation)
    await fixture.assertNoCua()
    await fixture.runtime.shutdownForQuit()
}

@Test @MainActor
func iMessageRelayLifecycleDesktopRemovalClosesItsLeaseAndKeepsIMessageSocket() async throws {
    let executor = DesktopControlCommandExecutor()
    let target = DesktopControlTarget(installationID: "lifecycle-mac", workspaceID: "w", configID: "c",
        personaID: "p", runID: "r", generation: 1)
    let acquire = DesktopControlFrame(type: "command", requestID: "acquire", target: target,
        operation: "desktop_control_acquire", arguments: .object([:]), deadlineAt: .distantFuture)
    #expect(await executor.handle(acquire, proxy: nil).type == "result")
    #expect(executor.currentLease != nil)
    let fixture = try IMessageLifecycleFixture(iMessage: true, connected: true, executor: executor)
    try await fixture.runtime.reconcileRelayForTesting()
    #expect(executor.currentLease == nil)
    #expect(fixture.runtime.gatewayConnected && fixture.runtime.hasActiveInstallation)
    #expect(!fixture.runtime.hasDesktopControlIntentForTesting)
    #expect(!fixture.runtime.executorCleanupFailedForTesting)
    await fixture.assertNoCua()
    await fixture.runtime.shutdownForQuit()
}
