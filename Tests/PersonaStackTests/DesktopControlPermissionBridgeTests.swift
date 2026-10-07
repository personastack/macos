import Foundation
import PersonaStackCore
import ServiceManagement
import Testing
@testable import PersonaStack

private enum PermissionBridgeFixtureError: Error { case unplannedCall, presenterDidNotOpen, readbackDidNotStart }

private final class PermissionBridgeCredentials: DesktopControlCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private var saves = 0
    private var installation: DesktopControlInstallation?
    private var suspendNextRead = false
    private let readStarted = DispatchSemaphore(value: 0)
    private let continueRead = DispatchSemaphore(value: 0)
    var counts: (reads: Int, saves: Int) { lock.withLock { (reads, saves) } }
    func load() throws -> DesktopControlInstallation? {
        let (value, suspended) = lock.withLock {
            reads += 1
            let suspended = suspendNextRead
            suspendNextRead = false
            return (installation, suspended)
        }
        if suspended {
            readStarted.signal()
            guard continueRead.wait(timeout: .now() + 2) == .success else {
                throw PermissionBridgeFixtureError.readbackDidNotStart
            }
        }
        return value
    }
    func suspendCredentialRead() { lock.withLock { suspendNextRead = true } }
    func waitForCredentialRead() -> Bool { readStarted.wait(timeout: .now() + 2) == .success }
    func releaseCredentialRead() { continueRead.signal() }
    func save(_ installation: DesktopControlInstallation) throws { lock.withLock { saves += 1; self.installation = installation } }
    func delete() throws { Issue.record("Unplanned credential deletion"); throw PermissionBridgeFixtureError.unplannedCall }
}

@MainActor
private final class PermissionBridgeRuntime: DesktopControlSetupRuntime {
    var cuaProbeReady = true
    func refreshCuaReadiness() async -> Bool { cuaProbeReady }
    var gatewayConnected = false
    var paused = false
    var cuaReady = true
    var allowsReplacement = false
    var onDisconnect: (() throws -> Void)?
    var calls: [String] = []
    let generation = UUID()
    func isCuaReady() -> Bool { cuaReady }
    func beginResume() throws -> UUID { calls.append("begin"); return generation }
    func resume(generation: UUID) async throws { Issue.record("Unplanned ordinary resume"); throw PermissionBridgeFixtureError.unplannedCall }
    func resumeForSetup(generation: UUID) async throws { calls.append("resumeForSetup") }
    func finishSetupIfIdle() async throws { calls.append("finishSetupIfIdle") }
    func disconnect() async throws {
        guard allowsReplacement else {
            Issue.record("Unplanned saved-installation disconnect")
            throw PermissionBridgeFixtureError.unplannedCall
        }
        calls.append("disconnect")
        try onDisconnect?()
        gatewayConnected = false
    }
    func repair(resumeRelay: Bool, expectedGeneration: UUID?) async throws -> UUID { Issue.record("Unplanned repair"); throw PermissionBridgeFixtureError.unplannedCall }
    func isCurrentLifecycle(_ generation: UUID) -> Bool { self.generation == generation }
    func connect(installation: DesktopControlInstallation, expectedGeneration: UUID?) async { calls.append("connect"); gatewayConnected = true }
    func savedInstallation(for appURL: URL) async throws -> DesktopControlInstallation? { Issue.record("Unplanned runtime credential read"); throw PermissionBridgeFixtureError.unplannedCall }
}

private actor PermissionBridgeEnrollment: DesktopControlSetupEnrollment {
    private(set) var calls: [String] = []
    let installation: DesktopControlInstallation
    let allowed: Set<String>
    private var rejectEnrollment = false
    private var failAttachment = false
    private(set) var attachedTicket: String?
    private var suspendReady = false
    private var pendingReady: CheckedContinuation<Void, Never>?
    var isReadyPending: Bool { pendingReady != nil }
    private var delayEnrollment = false
    private var pendingEnrollment: CheckedContinuation<Void, Never>?
    var isEnrollmentPending: Bool { pendingEnrollment != nil }
    private var configuration = DesktopControlConfigurationState(hasActiveConfig: true, hasConfig: true)
    private var suspendConfiguration = false
    private var pendingConfiguration: [CheckedContinuation<Void, Never>] = []
    var pendingConfigurationCount: Int { pendingConfiguration.count }
    init(installation: DesktopControlInstallation, allowed: Set<String> = []) { self.installation = installation; self.allowed = allowed }
    private func require(_ name: String) throws {
        calls.append(name)
        guard allowed.contains(name) else { Issue.record("Unplanned enrollment operation: \(name)"); throw PermissionBridgeFixtureError.unplannedCall }
    }
    func enroll(ticket: String, appURL: URL, commitCredential: (@MainActor @Sendable (DesktopControlInstallation) throws -> Void)?) async throws -> DesktopControlInstallation {
        try require("enroll")
        #expect(ticket == String(repeating: "a", count: 43))
        #expect(appURL == DesktopEnvironmentConfiguration.production.appURL)
        if delayEnrollment {
            await withCheckedContinuation { pendingEnrollment = $0 }
        }
        if rejectEnrollment { throw DesktopControlEnrollmentError.rejected }
        try await commitCredential?(installation)
        return installation
    }
    func reportReady(installation: DesktopControlInstallation, appURL: URL) async throws {
        try require("reportReady")
        if suspendReady { await withCheckedContinuation { pendingReady = $0 } }
    }
    func suspendReadyReport() { suspendReady = true }
    func releaseReadyReport() {
        suspendReady = false
        let pending = pendingReady
        pendingReady = nil
        pending?.resume()
    }
    func loseAttachmentResponse() { failAttachment = true }
    func attach(ticket: String, installation: DesktopControlInstallation, appURL: URL) async throws {
        try require("attach")
        #expect(ticket == String(repeating: "a", count: 43))
        #expect(installation == self.installation)
        #expect(appURL == DesktopEnvironmentConfiguration.production.appURL)
        attachedTicket = ticket
        if failAttachment { throw URLError(.networkConnectionLost) }
    }
    func configurationState(installation: DesktopControlInstallation, appURL: URL) async throws -> DesktopControlConfigurationState {
        try require("configurationState")
        if suspendConfiguration { await withCheckedContinuation { pendingConfiguration.append($0) } }
        return configuration
    }
    func suspendConfigurationReadbacks() { suspendConfiguration = true }
    func releaseNextConfigurationReadback() {
        guard !pendingConfiguration.isEmpty else { return }
        pendingConfiguration.removeFirst().resume()
    }
    func releaseConfigurationReadbacks() {
        suspendConfiguration = false
        let pending = pendingConfiguration
        pendingConfiguration.removeAll()
        for continuation in pending { continuation.resume() }
    }
    func setRejectEnrollment(_ value: Bool) { rejectEnrollment = value }
    func suspendRejectedEnrollment() { delayEnrollment = true; rejectEnrollment = true }
    func suspendSuccessfulEnrollment() { delayEnrollment = true; rejectEnrollment = false }
    func releaseEnrollment() { let pending = pendingEnrollment; pendingEnrollment = nil; pending?.resume() }
    func setConfiguration(hasConfig: Bool, active: Bool) { configuration = .init(hasActiveConfig: active, hasConfig: hasConfig) }
    func hasActiveConfig(installation: DesktopControlInstallation, appURL: URL) async throws -> Bool { try require("hasActiveConfig"); return true }
}

@MainActor
private final class PermissionBridgePresenter: DesktopControlPermissionPresenting {
    var isFinishing = false
    var autoFinish = false
    private(set) var opens = 0
    private(set) var repairs = 0
    private(set) var completions = 0
    private(set) var cancellations = 0
    private(set) var failures: [String] = []
    private var pending: CheckedContinuation<Void, Error>?
    var isWaiting: Bool { pending != nil }
    func presentForSetup() async throws {
        opens += 1
        if autoFinish { isFinishing = true; return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in pending = continuation }
    }
    func presentForRepair() { repairs += 1 }
    func finish() { isFinishing = true; let value = pending; pending = nil; value?.resume() }
    func completeWithoutFinish() { let value = pending; pending = nil; value?.resume() }
    func completeSetup() { completions += 1; isFinishing = false }
    func failSetup(message: String) { failures.append(message); isFinishing = false }
    func cancel() { cancellations += 1; isFinishing = false; let value = pending; pending = nil; value?.resume(throwing: CancellationError()) }
}

private struct PermissionBridgeReply: Sendable {
    let ok: Bool
    let code: String?
    let error: String?
    let setupVersion: String?
    let recoveryVersion: String?
    let legacySetupVersion: String?
    let legacyExecutorReady: Bool?
    let cuaReady: Bool?
    let prerequisitesReady: Bool
    let installationID: String?
}

@MainActor
private struct PermissionBridgeFixture {
    let runtime = PermissionBridgeRuntime()
    let credentials = PermissionBridgeCredentials()
    let presenter = PermissionBridgePresenter()
    let enrollment: PermissionBridgeEnrollment
    let preferences: UserDefaults
    let suite: String
    let manager: DesktopControlSetupManager
    let page: DesktopControlSetupManager.Page

    init(allowEnrollment: Bool = false, allowReplacement: Bool = false, automaticTimeout: Duration = .seconds(60)) throws {
        let configuration = DesktopEnvironmentConfiguration.production
        let payload = try JSONSerialization.data(withJSONObject: [
            "installation_id": "permission-fixture", "machine_credential": String(repeating: "A", count: 43),
            "gateway_websocket_url": configuration.gatewayWebsocketURL.absoluteString,
        ])
        var installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: payload)
        try installation.bindEnvironment(configuration.appURL, configuration: configuration)
        enrollment = PermissionBridgeEnrollment(installation: installation,
            allowed: allowEnrollment ? Set(["enroll", "reportReady", "configurationState"] + (allowReplacement ? ["attach"] : [])) : [])
        runtime.allowsReplacement = allowReplacement
        suite = "permission-bridge-\(UUID().uuidString)"
        preferences = try #require(UserDefaults(suiteName: suite))
        manager = DesktopControlSetupManager(runtime: runtime, enrollment: enrollment, credentials: credentials,
            preferences: preferences, configurationProvider: { configuration }, permissionPresenter: presenter, automaticRequestTimeout: automaticTimeout)
        page = DesktopControlSetupManager.Page(appURL: configuration.appURL)
        page.setupScope.synchronize("workspace-session")
    }

    func cleanup() { presenter.cancel(); preferences.removePersistentDomain(forName: suite) }

    func send(_ body: [String: Any], page override: DesktopControlSetupManager.Page? = nil) async -> PermissionBridgeReply {
        await withCheckedContinuation { continuation in
            manager.dispatch(body, page: override ?? page) { value, error in
                let response = value as? [String: Any]
                continuation.resume(returning: .init(ok: response?["ok"] as? Bool == true,
                    code: response?["error_code"] as? String, error: error,
                    setupVersion: response?["cua_setup_version"] as? String,
                    recoveryVersion: response?["setup_recovery_version"] as? String,
                    legacySetupVersion: response?["permissions_checklist_version"] as? String,
                    legacyExecutorReady: response?["native_executor_ready"] as? Bool,
                    cuaReady: response?["cua_ready"] as? Bool,
                    prerequisitesReady: response?["prerequisites_ready"] as? Bool == true,
                    installationID: response?["installation_id"] as? String))
            }
        }
    }

    func permissions(_ phase: String, scope: String = "workspace-session", message: String? = nil, action: String = "cua_setup") -> [String: Any] {
        var result: [String: Any] = ["version": "1", "action": action, "scope": scope, "phase": phase]
        if let message { result["message"] = message }
        return result
    }

    var prepare: [String: Any] {
        ["version": "1", "action": "prepare", "scope": "workspace-session", "enrollment_ticket": String(repeating: "a", count: 43)]
    }

    func waitForOpen() async throws {
        for _ in 0..<1000 {
            if presenter.isWaiting { return }
            await Task.yield()
        }
        throw PermissionBridgeFixtureError.presenterDidNotOpen
    }

    func waitForConfigurationReadbacks(_ count: Int) async throws {
        for _ in 0..<1000 {
            if await enrollment.pendingConfigurationCount == count { return }
            await Task.yield()
        }
        throw PermissionBridgeFixtureError.readbackDidNotStart
    }
}

@Test(arguments: ["workspace-session", ""]) @MainActor
func permissionBridgeRepairOpensWindowWithoutEnrollmentOrRuntimeMutation(_ scope: String) async throws {
    let fixture = try PermissionBridgeFixture()
    defer { fixture.cleanup() }
    fixture.page.setupScope.synchronize(scope)
    let response = await fixture.send(fixture.permissions("repair", scope: scope))
    #expect(response.ok && response.setupVersion == "1" && !response.prerequisitesReady)
    #expect(fixture.presenter.repairs == 1 && fixture.presenter.opens == 0)
    #expect(!fixture.presenter.isFinishing)
    let completion = await fixture.send(fixture.permissions("completed", scope: scope))
    #expect(!completion.ok)
    #expect(scope.isEmpty ? completion.error != nil : completion.code == "permissions_incomplete")
    #expect(fixture.credentials.counts.reads == 0 && fixture.credentials.counts.saves == 0)
    #expect(fixture.runtime.calls.isEmpty)
    #expect(await fixture.enrollment.calls.isEmpty)
}

@Test @MainActor func permissionBridgeRepairRejectsBusyWithoutCancellingEnrollment() async throws {
    let fixture = try PermissionBridgeFixture()
    defer { fixture.cleanup() }
    let pending = Task { await fixture.send(fixture.permissions("open")) }
    try await fixture.waitForOpen()
    let response = await fixture.send(fixture.permissions("repair"))
    #expect(!response.ok && response.code == "setup_busy")
    #expect(fixture.presenter.repairs == 0 && fixture.presenter.cancellations == 0)
    #expect(fixture.presenter.isWaiting)
    fixture.presenter.finish()
    #expect(await pending.value.prerequisitesReady)
    #expect(fixture.credentials.counts.reads == 0 && fixture.runtime.calls.isEmpty)
    #expect(await fixture.enrollment.calls.isEmpty)
}

@Test(arguments: ["stale", "retired", "extra-message"]) @MainActor
func permissionBridgeRepairRejectsInvalidPageAndPayload(_ reason: String) async throws {
    let fixture = try PermissionBridgeFixture()
    defer { fixture.cleanup() }
    if reason == "stale" { fixture.page.setupScope.synchronize("new-scope") }
    if reason == "retired" { fixture.page.retire() }
    let response = await fixture.send(fixture.permissions("repair", message: reason == "extra-message" ? "unexpected" : nil))
    #expect(!response.ok)
    #expect(fixture.presenter.repairs == 0 && fixture.presenter.opens == 0)
    #expect(fixture.credentials.counts.reads == 0 && fixture.credentials.counts.saves == 0)
    #expect(fixture.runtime.calls.isEmpty)
    #expect(await fixture.enrollment.calls.isEmpty)
}

@Test @MainActor func permissionBridgeStateAdvertisesCuaSetupWithoutEnrollmentOrRuntimeMutation() async throws {
    let fixture = try PermissionBridgeFixture()
    defer { fixture.cleanup() }
    let response = await fixture.send(["version": "1", "action": "state", "scope": "workspace-session"])
    #expect(response.ok && response.setupVersion == "1" && response.recoveryVersion == "1")
    #expect(response.installationID == nil)
    #expect(fixture.credentials.counts.reads == 1)
    #expect(fixture.credentials.counts.saves == 0)
    #expect(fixture.runtime.calls.isEmpty)
    #expect(await fixture.enrollment.calls.isEmpty)
    #expect(fixture.presenter.opens == 0)
}

@Test @MainActor func permissionBridgeScopeSyncAdvertisesCuaSetupWithZeroProtectedReads() async throws {
    let fixture = try PermissionBridgeFixture()
    defer { fixture.cleanup() }
    let response = await fixture.send(["version": "1", "action": "sync", "scope": "workspace-session"])
    #expect(response.ok && response.setupVersion == "1" && response.recoveryVersion == "1")
    #expect(fixture.credentials.counts.reads == 0 && fixture.credentials.counts.saves == 0)
    #expect(fixture.runtime.calls.isEmpty && fixture.presenter.opens == 0)
    #expect(await fixture.enrollment.calls.isEmpty)
}

@Test @MainActor func permissionBridgePrepareBeforeNativeFinishHasZeroProtectedReadsOrMutations() async throws {
    let fixture = try PermissionBridgeFixture()
    defer { fixture.cleanup() }
    let pending = Task { await fixture.send(fixture.prepare) }
    try await fixture.waitForOpen()
    #expect(fixture.credentials.counts.reads == 0 && fixture.credentials.counts.saves == 0)
    #expect(fixture.runtime.calls.isEmpty)
    #expect(await fixture.enrollment.calls.isEmpty)
    fixture.presenter.completeWithoutFinish()
    let response = await pending.value
    #expect(!response.ok && response.error?.contains("Complete CUA setup") == true)
    #expect(fixture.credentials.counts.reads == 0 && fixture.credentials.counts.saves == 0)
    #expect(fixture.runtime.calls.isEmpty)
    #expect(await fixture.enrollment.calls.isEmpty)
}

@Test @MainActor func permissionBridgeCancelledPopupDoesNotEnroll() async throws {
    let fixture = try PermissionBridgeFixture()
    defer { fixture.cleanup() }
    let pending = Task { await fixture.send(fixture.permissions("open")) }
    try await fixture.waitForOpen()
    fixture.presenter.cancel()
    let response = await pending.value
    #expect(!response.ok && response.code == "setup_cancelled" && response.error == nil)
    #expect(fixture.credentials.counts.reads == 0 && fixture.credentials.counts.saves == 0)
    #expect(fixture.runtime.calls.isEmpty)
    #expect(await fixture.enrollment.calls.isEmpty)
}

@Test @MainActor func permissionBridgePopupReturnWithoutNativeFinishCannotAuthorizePrepare() async throws {
    let fixture = try PermissionBridgeFixture()
    defer { fixture.cleanup() }
    let pending = Task { await fixture.send(fixture.permissions("open")) }
    try await fixture.waitForOpen()
    fixture.presenter.completeWithoutFinish()
    #expect(await pending.value.code == "permissions_incomplete")
    #expect(!(await fixture.send(fixture.prepare)).ok)
    #expect(fixture.credentials.counts.reads == 0 && fixture.credentials.counts.saves == 0)
    #expect(fixture.runtime.calls.isEmpty)
    #expect(await fixture.enrollment.calls.isEmpty)
}

@Test @MainActor func permissionBridgeMalformedMessagesNeverOpenPopupOrReadCredentials() async throws {
    let fixture = try PermissionBridgeFixture()
    defer { fixture.cleanup() }
    var body = fixture.permissions("open")
    body["approved"] = true
    let response = await fixture.send(body)
    #expect(!response.ok && response.error != nil)
    #expect(fixture.presenter.opens == 0)
    #expect(fixture.credentials.counts.reads == 0)
    #expect(await fixture.enrollment.calls.isEmpty)
}

@Test @MainActor func permissionBridgeRejectsStaleAndRetiredPagesWithoutOpeningPopup() async throws {
    let fixture = try PermissionBridgeFixture()
    defer { fixture.cleanup() }
    let stale = await fixture.send(fixture.permissions("open", scope: "stale-workspace"))
    #expect(stale.code == "setup_scope_changed" && !stale.ok)
    fixture.page.retire()
    let retired = await fixture.send(fixture.permissions("open"))
    #expect(!retired.ok && retired.error != nil)
    #expect(fixture.presenter.opens == 0)
    #expect(fixture.credentials.counts.reads == 0)
    #expect(await fixture.enrollment.calls.isEmpty)
}

@Test @MainActor func permissionBridgeCompetingScopeCannotReplaceActivePopup() async throws {
    let fixture = try PermissionBridgeFixture()
    defer { fixture.cleanup() }
    let pending = Task { await fixture.send(fixture.permissions("open")) }
    try await fixture.waitForOpen()
    let otherPage = DesktopControlSetupManager.Page(appURL: fixture.page.appURL)
    otherPage.setupScope.synchronize("other-session")
    let other = await fixture.send(fixture.permissions("open", scope: "other-session"), page: otherPage)
    #expect(!other.ok && other.code == "setup_busy")
    #expect(fixture.presenter.opens == 1)
    fixture.presenter.cancel()
    #expect(await pending.value.code == "setup_cancelled")
    #expect(fixture.credentials.counts.reads == 0)
    #expect(await fixture.enrollment.calls.isEmpty)
}

@Test @MainActor func permissionBridgeScopeChangeCancelsAwaitedPopupAndCannotReuseItsFinish() async throws {
    let fixture = try PermissionBridgeFixture()
    defer { fixture.cleanup() }
    let pending = Task { await fixture.send(fixture.permissions("open")) }
    try await fixture.waitForOpen()
    let changed = await fixture.send(["version": "1", "action": "sync", "scope": "new-workspace-session"])
    #expect(changed.ok)
    #expect(await pending.value.code == "setup_cancelled")
    let prepared = await fixture.send(fixture.prepare)
    #expect(!prepared.ok)
    #expect(fixture.credentials.counts.reads == 0)
    #expect(fixture.runtime.calls.isEmpty)
    #expect(await fixture.enrollment.calls.isEmpty)
}

@Test @MainActor func permissionBridgeRetiredPageCannotAcceptLateNativeFinish() async throws {
    let fixture = try PermissionBridgeFixture()
    defer { fixture.cleanup() }
    let pending = Task { await fixture.send(fixture.permissions("open")) }
    try await fixture.waitForOpen()
    fixture.page.retire()
    fixture.presenter.finish()
    let response = await pending.value
    #expect(!response.ok && response.code == "setup_scope_changed")
    #expect(fixture.credentials.counts.reads == 0 && fixture.credentials.counts.saves == 0)
    #expect(fixture.runtime.calls.isEmpty)
    #expect(await fixture.enrollment.calls.isEmpty)
}

@Test @MainActor func permissionBridgeBrowserCompletionCannotSkipNativePrepare() async throws {
    let fixture = try PermissionBridgeFixture()
    defer { fixture.cleanup() }
    fixture.presenter.autoFinish = true
    let ready = await fixture.send(fixture.permissions("open"))
    #expect(ready.ok && ready.prerequisitesReady && ready.setupVersion == "1")
    let completed = await fixture.send(fixture.permissions("completed"))
    #expect(!completed.ok && completed.code == "permissions_incomplete")
    #expect(fixture.presenter.completions == 0)
    #expect(fixture.credentials.counts.reads == 0)
    #expect(fixture.runtime.calls.isEmpty)
    #expect(await fixture.enrollment.calls.isEmpty)
}

@Test @MainActor func permissionBridgeFailureEndsFinishingAndRequiresNewNativeApproval() async throws {
    let fixture = try PermissionBridgeFixture()
    defer { fixture.cleanup() }
    fixture.presenter.autoFinish = true
    #expect(await fixture.send(fixture.permissions("open")).ok)
    #expect(await fixture.send(fixture.permissions("failed", message: "Service unavailable")).ok)
    #expect(fixture.presenter.failures == ["Service unavailable"])
    let retry = await fixture.send(fixture.prepare)
    #expect(!retry.ok)
    #expect(fixture.credentials.counts.reads == 0)
    #expect(await fixture.enrollment.calls.isEmpty)
}

@Test(arguments: ["cua_setup", "permissions"]) @MainActor
func permissionBridgeNativeFinishPrecedesEnrollmentAndCompletionChecksConnection(action: String) async throws {
    let fixture = try PermissionBridgeFixture(allowEnrollment: true)
    defer { fixture.cleanup() }
    fixture.presenter.autoFinish = true
    let ready = await fixture.send(fixture.permissions("open", action: action))
    #expect(ready.ok && ready.setupVersion == "1" && ready.legacySetupVersion == "1" && fixture.credentials.counts.reads == 0)
    #expect(await fixture.enrollment.calls.isEmpty)
    let prepared = await fixture.send(fixture.prepare)
    #expect(prepared.ok && prepared.installationID == "permission-fixture")
    #expect(fixture.credentials.counts.reads == 1 && fixture.credentials.counts.saves == 1)
    #expect(fixture.runtime.calls == ["begin", "resumeForSetup", "connect"])
    #expect(await fixture.enrollment.calls == ["enroll", "reportReady"])
    fixture.runtime.gatewayConnected = false
    let disconnected = await fixture.send(fixture.permissions("completed", action: action))
    #expect(!disconnected.ok && disconnected.code == "permissions_incomplete")
    #expect(fixture.presenter.completions == 0)
    fixture.runtime.gatewayConnected = true
    let completed = await fixture.send(fixture.permissions("completed", action: action))
    #expect(completed.ok && fixture.presenter.completions == 1)
    #expect(await fixture.enrollment.calls == ["enroll", "reportReady", "configurationState"])
}

@Test(arguments: [false, true]) @MainActor
func permissionBridgeRemovedConfigurationReattachesSavedMachineWithoutGatewayNotice(noticeReceived: Bool) async throws {
    let fixture = try PermissionBridgeFixture(allowEnrollment: true, allowReplacement: true)
    defer { fixture.cleanup() }
    let saved = fixture.enrollment.installation
    try fixture.credentials.save(saved)
    fixture.runtime.gatewayConnected = !noticeReceived
    await fixture.enrollment.setConfiguration(hasConfig: false, active: false)

    #expect(await fixture.send(["version": "1", "action": "sync", "scope": ""]).ok)
    let unlinked = try await fixture.manager.apply(.state(scope: ""), page: fixture.page)
    #expect(unlinked["installation_id"] as? String == saved.installationID)
    #expect(unlinked["configuration_in_use"] as? Bool == false)
    #expect(unlinked["machine_credential"] == nil)
    #expect(fixture.presenter.opens == 0)
    #expect(fixture.runtime.calls == ["finishSetupIfIdle"])
    #expect(await fixture.enrollment.calls == ["configurationState"])

    // Add is explicit. Native permission Finish still gates attachment.
    #expect(await fixture.send(["version": "1", "action": "sync", "scope": "workspace-session"]).ok)
    fixture.presenter.autoFinish = true
    #expect(await fixture.send(fixture.permissions("open")).ok)
    fixture.runtime.onDisconnect = {
        // A delayed removal notification must not be required to stop the old relay.
        #expect(fixture.runtime.gatewayConnected == !noticeReceived)
    }
    let prepared = await fixture.send(fixture.prepare)
    #expect(prepared.ok && prepared.installationID == saved.installationID)
    #expect(fixture.runtime.calls == ["finishSetupIfIdle", "disconnect", "begin", "resumeForSetup", "connect"])
    #expect(await fixture.enrollment.calls == ["configurationState", "attach", "reportReady"])
    #expect(try fixture.credentials.load() == saved)
    #expect(fixture.credentials.counts.saves == 1)

    // Preparation cannot manufacture the API-owned configuration. Complete only
    // after the canonical web save creates a fresh active mapping.
    let missing = await fixture.send(fixture.permissions("completed"))
    #expect(!missing.ok && missing.code == "permissions_incomplete")
    #expect(fixture.presenter.completions == 0)
    await fixture.enrollment.setConfiguration(hasConfig: true, active: true)
    #expect(await fixture.send(fixture.permissions("completed")).ok)
    #expect(fixture.presenter.completions == 1 && fixture.presenter.repairs == 0)
    #expect(fixture.credentials.counts.saves == 1)
    #expect(await fixture.enrollment.calls == ["configurationState", "attach", "reportReady", "configurationState", "configurationState"])
}

@Test(arguments: ["", "other-workspace-session"]) @MainActor
func permissionBridgeRemovedConfigurationCannotAttachAfterScopeChangesDuringDisconnect(newScope: String) async throws {
    let fixture = try PermissionBridgeFixture(allowEnrollment: true, allowReplacement: true)
    defer { fixture.cleanup() }
    let saved = fixture.enrollment.installation
    try fixture.credentials.save(saved)
    await fixture.enrollment.setConfiguration(hasConfig: false, active: false)
    fixture.presenter.autoFinish = true
    #expect(await fixture.send(fixture.permissions("open")).ok)
    fixture.runtime.onDisconnect = { fixture.page.setupScope.synchronize(newScope) }

    let stale = await fixture.send(fixture.prepare)
    #expect(!stale.ok && stale.error != nil)
    #expect(fixture.runtime.calls == ["disconnect"])
    #expect(await fixture.enrollment.calls.isEmpty)
    #expect(try fixture.credentials.load() == saved)
    #expect(fixture.credentials.counts.saves == 1)
    #expect(fixture.presenter.completions == 0)
}

@Test @MainActor func permissionBridgeCompletionRequiresAuthoritativeActiveConfigurationReadback() async throws {
    let fixture = try PermissionBridgeFixture(allowEnrollment: true)
    defer { fixture.cleanup() }
    fixture.presenter.autoFinish = true
    #expect(await fixture.send(fixture.permissions("open")).ok)
    #expect(await fixture.send(fixture.prepare).ok)
    await fixture.enrollment.setConfiguration(hasConfig: false, active: false)
    let missing = await fixture.send(fixture.permissions("completed"))
    #expect(!missing.ok && missing.code == "permissions_incomplete")
    #expect(fixture.presenter.completions == 0)
    await fixture.enrollment.setConfiguration(hasConfig: true, active: false)
    let inactive = await fixture.send(fixture.permissions("completed"))
    #expect(!inactive.ok && inactive.code == "permissions_incomplete")
    #expect(fixture.presenter.completions == 0)
    await fixture.enrollment.setConfiguration(hasConfig: true, active: true)
    let complete = await fixture.send(fixture.permissions("completed"))
    #expect(complete.ok && fixture.presenter.completions == 1)
    #expect(await fixture.enrollment.calls == ["enroll", "reportReady", "configurationState", "configurationState", "configurationState"])
}

@Test(arguments: ["gui", "connection", "permissions"]) @MainActor
func permissionBridgeCompletionRechecksReadinessAfterConfigurationReadback(lost: String) async throws {
    let fixture = try PermissionBridgeFixture(allowEnrollment: true)
    defer {
        fixture.cleanup()
        Task { await fixture.enrollment.releaseConfigurationReadbacks() }
    }
    fixture.presenter.autoFinish = true
    #expect(await fixture.send(fixture.permissions("open")).ok)
    #expect(await fixture.send(fixture.prepare).ok)
    await fixture.enrollment.suspendConfigurationReadbacks()
    let completion = Task { await fixture.send(fixture.permissions("completed")) }
    try await fixture.waitForConfigurationReadbacks(1)
    switch lost {
    case "gui": fixture.runtime.cuaReady = false
    case "permissions": fixture.runtime.cuaProbeReady = false
    default: fixture.runtime.gatewayConnected = false
    }
    await fixture.enrollment.releaseConfigurationReadbacks()
    let result = await completion.value
    #expect(!result.ok && result.code == "permissions_incomplete")
    #expect(fixture.presenter.completions == 0 && fixture.presenter.isFinishing)
    #expect(fixture.credentials.counts.saves == 1)
    #expect(await fixture.enrollment.calls == ["enroll", "reportReady", "configurationState"])

    // The same current request can confirm once its runtime has recovered.
    fixture.runtime.cuaReady = true
    fixture.runtime.gatewayConnected = true
    fixture.runtime.cuaProbeReady = true
    let retry = await fixture.send(fixture.permissions("completed"))
    #expect(retry.ok && fixture.presenter.completions == 1)
}

@Test(arguments: [false, true]) @MainActor
func permissionBridgeLateCompletionCannotCloseSameScopeSuccessor(finishSuccessor: Bool) async throws {
    let fixture = try PermissionBridgeFixture(allowEnrollment: true, allowReplacement: true)
    defer {
        fixture.cleanup()
        Task { await fixture.enrollment.releaseConfigurationReadbacks() }
    }
    fixture.presenter.autoFinish = true
    #expect(await fixture.send(fixture.permissions("open")).ok)
    #expect(await fixture.send(fixture.prepare).ok)
    await fixture.enrollment.suspendConfigurationReadbacks()
    let first = Task { await fixture.send(fixture.permissions("completed")) }
    try await fixture.waitForConfigurationReadbacks(1)
    let late = Task { await fixture.send(fixture.permissions("completed")) }
    try await fixture.waitForConfigurationReadbacks(2)
    await fixture.enrollment.releaseNextConfigurationReadback()
    #expect(await first.value.ok)
    #expect(fixture.presenter.completions == 1)

    fixture.presenter.autoFinish = false
    let successor = Task { await fixture.send(fixture.permissions("open")) }
    try await fixture.waitForOpen()
    if finishSuccessor {
        fixture.presenter.finish()
        #expect(await successor.value.ok)
        #expect(await fixture.send(fixture.prepare).ok)
    }
    await fixture.enrollment.releaseConfigurationReadbacks()
    let stale = await late.value
    #expect(!stale.ok && stale.code == "permissions_incomplete")
    #expect(fixture.presenter.completions == 1 && fixture.presenter.failures.isEmpty)
    #expect(fixture.presenter.isFinishing == finishSuccessor)
    #expect(fixture.presenter.isWaiting != finishSuccessor)

    // A stale completion must not clear the successor's request or prepared state.
    if !finishSuccessor {
        fixture.presenter.finish()
        #expect(await successor.value.ok)
        #expect(await fixture.send(fixture.prepare).ok)
    }
    let completed = await fixture.send(fixture.permissions("completed"))
    #expect(completed.ok && fixture.presenter.completions == 2)
}

@Test @MainActor func permissionBridgeStaleCredentialReadCannotInspectConfigurationOrCloseSuccessor() async throws {
    let fixture = try PermissionBridgeFixture(allowEnrollment: true)
    defer { fixture.credentials.releaseCredentialRead(); fixture.cleanup() }
    fixture.presenter.autoFinish = true
    #expect(await fixture.send(fixture.permissions("open")).ok)
    #expect(await fixture.send(fixture.prepare).ok)
    fixture.credentials.suspendCredentialRead()
    let completion = Task { await fixture.send(fixture.permissions("completed")) }
    let readStarted = await Task.detached { [credentials = fixture.credentials] in
        credentials.waitForCredentialRead()
    }.value
    try #require(readStarted)
    #expect(await fixture.send(fixture.permissions("failed", message: "Retry setup")).ok)
    fixture.presenter.autoFinish = false
    let successor = Task { await fixture.send(fixture.permissions("open")) }
    try await fixture.waitForOpen()
    fixture.credentials.releaseCredentialRead()
    let stale = await completion.value
    #expect(!stale.ok && stale.code == "permissions_incomplete")
    #expect(fixture.presenter.isWaiting && fixture.presenter.completions == 0)
    #expect(fixture.presenter.failures == ["Retry setup"])
    #expect(fixture.credentials.counts.reads == 2 && fixture.credentials.counts.saves == 1)
    #expect(await fixture.enrollment.calls == ["enroll", "reportReady"])
    #expect(fixture.runtime.calls == ["begin", "resumeForSetup", "connect"])
    fixture.presenter.finish()
    let opened = await successor.value
    #expect(opened.ok && opened.prerequisitesReady && fixture.presenter.isFinishing)
}

@Test @MainActor func permissionBridgeLegacyPrepareWaitsForFinishBeforeEnrollment() async throws {
    let fixture = try PermissionBridgeFixture(allowEnrollment: true)
    defer { fixture.cleanup() }
    let pending = Task { await fixture.send(fixture.prepare) }
    try await fixture.waitForOpen()
    #expect(fixture.credentials.counts.reads == 0 && fixture.credentials.counts.saves == 0)
    #expect(await fixture.enrollment.calls.isEmpty)
    fixture.presenter.finish()
    let response = await pending.value
    #expect(response.ok && response.installationID == "permission-fixture")
    #expect(fixture.credentials.counts.saves == 1)
    #expect(await fixture.enrollment.calls == ["enroll", "reportReady"])
    #expect(fixture.runtime.calls == ["begin", "resumeForSetup", "connect"])
    #expect(fixture.presenter.completions == 0 && fixture.presenter.isFinishing)
    // The old page saves through its existing API then navigates. Scope change
    // clears the permission presentation without asserting native completion.
    let navigation = await fixture.send(["version": "1", "action": "sync", "scope": "next-page"])
    #expect(navigation.ok && !fixture.presenter.isFinishing)
    #expect(fixture.presenter.completions == 0)
}

@Test @MainActor func permissionBridgeLegacyRejectedTicketHasNoCredentialSaveAndAllowsFreshRetry() async throws {
    let fixture = try PermissionBridgeFixture(allowEnrollment: true)
    defer { fixture.cleanup() }
    await fixture.enrollment.setRejectEnrollment(true)
    fixture.presenter.autoFinish = true
    let response = await fixture.send(fixture.prepare)
    #expect(!response.ok)
    #expect(fixture.credentials.counts.saves == 0)
    #expect(await fixture.enrollment.calls == ["enroll"])
    #expect(fixture.runtime.calls == ["begin", "resumeForSetup"])
    #expect(fixture.presenter.failures.count == 1 && !fixture.presenter.isFinishing)
    #expect(fixture.presenter.failures[0].contains("Return to PersonaStack"))
    #expect(fixture.presenter.completions == 0)
    await fixture.enrollment.setRejectEnrollment(false)
    #expect(await fixture.send(["version": "1", "action": "sync", "scope": ""]).ok)
    let refreshed = await fixture.send(["version": "1", "action": "sync", "scope": "workspace-session"])
    #expect(refreshed.ok)
    let retry = await fixture.send(fixture.prepare)
    #expect(retry.ok && fixture.presenter.opens == 2 && fixture.credentials.counts.saves == 1)
}

@Test @MainActor func permissionBridgeLateLegacyFailureCannotClearNewerSamePagePermissionRequest() async throws {
    let fixture = try PermissionBridgeFixture(allowEnrollment: true)
    defer { fixture.cleanup() }
    await fixture.enrollment.suspendRejectedEnrollment()
    fixture.presenter.autoFinish = true
    let old = Task { await fixture.send(fixture.prepare) }
    while !(await fixture.enrollment.isEnrollmentPending) { await Task.yield() }
    let newScope = "new-workspace-session"
    let synchronization = await fixture.send(["version": "1", "action": "sync", "scope": newScope])
    #expect(synchronization.ok)
    fixture.presenter.autoFinish = false
    let fresh = Task { await fixture.send(fixture.permissions("open", scope: newScope)) }
    try await fixture.waitForOpen()
    await fixture.enrollment.releaseEnrollment()
    #expect(!(await old.value).ok)
    #expect(fixture.presenter.isWaiting && fixture.presenter.failures.isEmpty)
    #expect(fixture.credentials.counts.saves == 0 && fixture.presenter.completions == 0)
    fixture.presenter.finish()
    let response = await fresh.value
    #expect(response.ok && response.prerequisitesReady)
    #expect(fixture.presenter.isFinishing)
    #expect(await fixture.enrollment.calls == ["enroll"])
}

@Test(arguments: [false, true]) @MainActor
func cuaBridgeLegacyExecutorWireMirrorsOnlyCuaReadiness(ready: Bool) async throws {
    let fixture = try PermissionBridgeFixture()
    defer { fixture.cleanup() }
    fixture.runtime.cuaReady = ready
    let response = await fixture.send(["version": "1", "action": "state", "scope": "workspace-session"])
    #expect(response.ok && response.cuaReady == ready && response.legacyExecutorReady == ready)
    #expect(response.setupVersion == "1" && response.legacySetupVersion == "1")
    #expect(fixture.presenter.opens == 0 && fixture.runtime.calls.isEmpty)
    #expect(await fixture.enrollment.calls.isEmpty)
}

@Test @MainActor
func cuaSetupRechecksUpstreamReadinessBeforeEnrollment() async throws {
    let fixture = try PermissionBridgeFixture(allowEnrollment: true)
    defer { fixture.cleanup() }
    fixture.presenter.autoFinish = true
    #expect(await fixture.send(fixture.permissions("open")).ok)
    fixture.runtime.cuaProbeReady = false
    let response = await fixture.send(fixture.prepare)
    #expect(!response.ok)
    #expect(fixture.credentials.counts.saves == 0)
    #expect(await fixture.enrollment.calls.isEmpty)
    #expect(fixture.runtime.calls == ["begin", "resumeForSetup"])
    #expect(fixture.presenter.completions == 0)
}

@Test @MainActor func cuaBridgeScopeChangeSettlesPendingAutomaticReplyOnce() async throws {
    let fixture = try PermissionBridgeFixture(allowEnrollment: true)
    defer { fixture.cleanup() }
    try fixture.credentials.save(fixture.enrollment.installation)
    await fixture.enrollment.suspendConfigurationReadbacks()
    var replies = 0
    var failed = false
    fixture.manager.dispatch(["version": "1", "action": "state", "scope": "workspace-session"], page: fixture.page) { value, error in
        replies += 1
        failed = value == nil && error != nil
    }
    try await fixture.waitForConfigurationReadbacks(1)
    #expect(await fixture.send(["version": "1", "action": "sync", "scope": "other-workspace"]).ok)
    #expect(replies == 1 && failed)
    // Reusing the old string cannot revive its prior generation or reply.
    #expect(await fixture.send(["version": "1", "action": "sync", "scope": "workspace-session"]).ok)
    await fixture.enrollment.releaseConfigurationReadbacks()
    for _ in 0..<20 { await Task.yield() }
    #expect(replies == 1 && fixture.presenter.completions == 0)
    #expect(fixture.runtime.calls.isEmpty)
}

@Test @MainActor func cuaBridgeRetirementSettlesPendingAutomaticReplyBeforeDependencyReturns() async throws {
    let fixture = try PermissionBridgeFixture(allowEnrollment: true)
    defer { fixture.cleanup() }
    try fixture.credentials.save(fixture.enrollment.installation)
    await fixture.enrollment.suspendConfigurationReadbacks()
    let pending = Task { await fixture.send(["version": "1", "action": "state", "scope": "workspace-session"]) }
    try await fixture.waitForConfigurationReadbacks(1)
    fixture.page.retire()
    let response = await pending.value
    #expect(!response.ok && response.error != nil)
    #expect(await fixture.enrollment.pendingConfigurationCount == 1)
    await fixture.enrollment.releaseConfigurationReadbacks()
    #expect(fixture.runtime.calls.isEmpty && fixture.presenter.completions == 0)
}

@Test @MainActor func cuaBridgeAutomaticTimeoutSettlesReplyAndRejectsLateReadback() async throws {
    let fixture = try PermissionBridgeFixture(allowEnrollment: true, automaticTimeout: .milliseconds(100))
    defer { fixture.cleanup() }
    try fixture.credentials.save(fixture.enrollment.installation)
    await fixture.enrollment.suspendConfigurationReadbacks()
    let pending = Task { await fixture.send(["version": "1", "action": "state", "scope": "workspace-session"]) }
    try await fixture.waitForConfigurationReadbacks(1)
    let response = await pending.value
    #expect(!response.ok && response.error?.contains("could not be confirmed") == true)
    #expect(await fixture.enrollment.pendingConfigurationCount == 1)
    await fixture.enrollment.releaseConfigurationReadbacks()
    let retry = await fixture.send(["version": "1", "action": "state", "scope": "workspace-session"])
    #expect(retry.ok && retry.installationID == "permission-fixture")
    #expect(fixture.runtime.calls.isEmpty)
}

@Test @MainActor func cuaBridgeHumanConsentOutlastsAutomaticDeadline() async throws {
    let fixture = try PermissionBridgeFixture(allowEnrollment: true, automaticTimeout: .milliseconds(100))
    defer { fixture.cleanup() }
    let pending = Task { await fixture.send(fixture.permissions("open")) }
    try await fixture.waitForOpen()
    try await Task.sleep(for: .milliseconds(150))
    #expect(fixture.presenter.isWaiting && fixture.presenter.failures.isEmpty)
    #expect(await fixture.enrollment.calls.isEmpty)
    fixture.presenter.finish()
    #expect(await pending.value.prerequisitesReady)
    #expect(fixture.presenter.isFinishing)
    // Automatic cloud completion has separate deadline fixtures. Do not make
    // this human-wait assertion depend on completing cloud work within 100ms.
    #expect(await fixture.enrollment.calls.isEmpty)
}

@Test @MainActor func cuaBridgePendingPrepareExcludesRetryEvenAfterTimeout() async throws {
    let fixture = try PermissionBridgeFixture(allowEnrollment: true, automaticTimeout: .milliseconds(100))
    defer { fixture.cleanup() }
    fixture.presenter.autoFinish = true
    #expect(await fixture.send(fixture.permissions("open")).ok)
    await fixture.enrollment.suspendRejectedEnrollment()
    let pending = Task { await fixture.send(fixture.prepare) }
    while !(await fixture.enrollment.isEnrollmentPending) { await Task.yield() }
    let duplicate = await fixture.send(fixture.prepare)
    #expect(!duplicate.ok && duplicate.error?.contains("still finishing") == true)
    #expect(!(await pending.value).ok)
    let lateRetry = await fixture.send(fixture.prepare)
    #expect(!lateRetry.ok && lateRetry.error?.contains("still finishing") == true)
    let repair = await fixture.send(fixture.permissions("repair"))
    #expect(!repair.ok && repair.code == "setup_busy")
    #expect(await fixture.enrollment.calls == ["enroll"])
    #expect(fixture.credentials.counts.saves == 0)
    await fixture.enrollment.releaseEnrollment()
    for _ in 0..<20 { await Task.yield() }
    #expect(fixture.credentials.counts.saves == 0)
    #expect(fixture.presenter.failures.count == 1)
}

@Test @MainActor func cuaBridgeMissingHostedCompletionReturnsWindowToConnectionRecovery() async throws {
    let fixture = try PermissionBridgeFixture(allowEnrollment: true, automaticTimeout: .milliseconds(100))
    defer { fixture.cleanup() }
    fixture.presenter.autoFinish = true
    #expect(await fixture.send(fixture.permissions("open")).ok)
    #expect(await fixture.send(fixture.prepare).ok)
    for _ in 0..<200 {
        if !fixture.presenter.failures.isEmpty { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!fixture.presenter.isFinishing && fixture.presenter.completions == 0)
    #expect(fixture.presenter.failures.count == 1)
    #expect(fixture.presenter.failures.first?.contains("could not be confirmed") == true)
    #expect(fixture.credentials.counts.saves == 1)
    // Authoritative readback survives the presentation timeout.
    let state = await fixture.send(["version": "1", "action": "state", "scope": "workspace-session"])
    #expect(state.ok && state.installationID == "permission-fixture")
    #expect(await fixture.enrollment.calls == ["enroll", "reportReady", "configurationState"])
}

@Test(arguments: [false, true]) @MainActor
func cuaBridgeConfirmedPreparationRecoversWithoutAttachingOrEnrollingAgain(existing: Bool) async throws {
    let fixture = try PermissionBridgeFixture(allowEnrollment: true, allowReplacement: existing,
                                              automaticTimeout: .milliseconds(100))
    defer { fixture.cleanup() }
    if existing { try fixture.credentials.save(fixture.enrollment.installation) }
    fixture.presenter.autoFinish = true
    #expect(await fixture.send(fixture.permissions("open")).ok)
    await fixture.enrollment.suspendReadyReport()
    let pending = Task { await fixture.send(fixture.prepare) }
    while !(await fixture.enrollment.isReadyPending) { await Task.yield() }
    #expect(!(await pending.value).ok)
    #expect(!fixture.runtime.gatewayConnected)
    #expect(fixture.credentials.counts.saves == 1)
    await fixture.enrollment.releaseReadyReport()
    for _ in 0..<20 { await Task.yield() }
    let retry = await fixture.send(fixture.prepare)
    #expect(retry.ok && retry.installationID == "permission-fixture")
    #expect(fixture.runtime.gatewayConnected)
    #expect(await fixture.enrollment.calls == [existing ? "attach" : "enroll", "reportReady", "reportReady"])
    #expect(fixture.credentials.counts.saves == 1)
    #expect(fixture.presenter.opens == 1)
    #expect(fixture.runtime.calls.filter { $0 == "disconnect" }.count == (existing ? 1 : 0))
}

@Test @MainActor func cuaBridgeLostAttachmentResponseRecoversWithoutRepeatingMutation() async throws {
    let fixture = try PermissionBridgeFixture(allowEnrollment: true, allowReplacement: true)
    defer { fixture.cleanup() }
    try fixture.credentials.save(fixture.enrollment.installation)
    fixture.presenter.autoFinish = true
    #expect(await fixture.send(fixture.permissions("open")).ok)
    await fixture.enrollment.loseAttachmentResponse()
    let first = await fixture.send(fixture.prepare)
    #expect(!first.ok && first.error?.contains("could not be confirmed") == true)
    let retry = await fixture.send(fixture.prepare)
    #expect(retry.ok && retry.installationID == "permission-fixture")
    #expect(fixture.runtime.gatewayConnected)
    #expect(await fixture.enrollment.attachedTicket == String(repeating: "a", count: 43))
    var otherTicket = fixture.prepare
    otherTicket["enrollment_ticket"] = String(repeating: "b", count: 43)
    #expect(!(await fixture.send(otherTicket)).ok)
    #expect(await fixture.enrollment.calls == ["attach", "reportReady"])
    #expect(fixture.runtime.calls.filter { $0 == "disconnect" }.count == 1)
    #expect(fixture.credentials.counts.saves == 1)
    // The API-owned save/readback may now confirm this original attachment.
    await fixture.enrollment.setConfiguration(hasConfig: true, active: true)
    #expect(await fixture.send(fixture.permissions("completed")).ok)
    #expect(fixture.presenter.completions == 1)
    #expect(await fixture.enrollment.calls == ["attach", "reportReady", "configurationState"])
}

@Test @MainActor func cuaBridgeRecoveryRequiresOriginalReferenceAndCurrentSavedInstallation() async throws {
    let fixture = try PermissionBridgeFixture(allowEnrollment: true)
    defer { fixture.cleanup() }
    fixture.presenter.autoFinish = true
    #expect(await fixture.send(fixture.permissions("open")).ok)
    #expect(await fixture.send(fixture.prepare).ok)
    var otherTicket = fixture.prepare
    otherTicket["enrollment_ticket"] = String(repeating: "b", count: 43)
    #expect(!(await fixture.send(otherTicket)).ok)
    fixture.runtime.cuaProbeReady = false
    #expect(!(await fixture.send(fixture.prepare)).ok)
    #expect(await fixture.enrollment.calls == ["enroll", "reportReady"])
    #expect(fixture.credentials.counts.saves == 1)
    // A changed installation cannot borrow the prior attempt's local approval.
    let old = fixture.enrollment.installation
    let encoded = try JSONEncoder().encode(old)
    var fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    fields["installation_id"] = "different-installation"
    let different = try JSONDecoder().decode(DesktopControlInstallation.self, from: JSONSerialization.data(withJSONObject: fields))
    try fixture.credentials.save(different)
    fixture.runtime.cuaProbeReady = true
    #expect(!(await fixture.send(fixture.prepare)).ok)
    #expect(await fixture.enrollment.calls == ["enroll", "reportReady"])
}

@Test @MainActor func cuaBridgeLateEnrollmentResponsePreservesCredentialForSameReferenceRecovery() async throws {
    let fixture = try PermissionBridgeFixture(allowEnrollment: true, automaticTimeout: .milliseconds(100))
    defer { fixture.cleanup() }
    fixture.presenter.autoFinish = true
    #expect(await fixture.send(fixture.permissions("open")).ok)
    await fixture.enrollment.suspendSuccessfulEnrollment()
    let pending = Task { await fixture.send(fixture.prepare) }
    while !(await fixture.enrollment.isEnrollmentPending) { await Task.yield() }
    let early = await fixture.send(["version": "1", "action": "state", "scope": "workspace-session"])
    #expect(early.ok && early.installationID == nil)
    #expect(!(await pending.value).ok)
    #expect(!(await fixture.send(fixture.prepare)).ok)
    #expect(await fixture.enrollment.calls == ["enroll"])
    await fixture.enrollment.releaseEnrollment()
    for _ in 0..<20 { await Task.yield() }
    #expect(fixture.credentials.counts.saves == 1)
    #expect(fixture.runtime.gatewayConnected == false)
    let recovered = await fixture.send(fixture.prepare)
    #expect(recovered.ok && recovered.installationID == "permission-fixture")
    #expect(await fixture.enrollment.calls == ["enroll", "reportReady"])
    #expect(fixture.credentials.counts.saves == 1 && fixture.runtime.gatewayConnected)
}
