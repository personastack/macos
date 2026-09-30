import Foundation
import PersonaStackCore
import ServiceManagement
import Testing
@testable import PersonaStack

private enum PermissionBridgeFixtureError: Error { case unplannedCall, presenterDidNotOpen }

private final class PermissionBridgeCredentials: DesktopControlCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private var saves = 0
    private var installation: DesktopControlInstallation?
    var counts: (reads: Int, saves: Int) { lock.withLock { (reads, saves) } }
    func load() throws -> DesktopControlInstallation? { lock.withLock { reads += 1; return installation } }
    func save(_ installation: DesktopControlInstallation) throws { lock.withLock { saves += 1; self.installation = installation } }
    func delete() throws { Issue.record("Unplanned credential deletion"); throw PermissionBridgeFixtureError.unplannedCall }
}

@MainActor
private final class PermissionBridgeRuntime: DesktopControlSetupRuntime {
    var gatewayConnected = false
    var paused = false
    var nativeExecutorReady = true
    var cuaReady = true
    var calls: [String] = []
    let generation = UUID()
    func isCuaReady() -> Bool { cuaReady }
    func probeNativeCapabilities(generation: UUID) async throws { calls.append("probe") }
    func beginResume() throws -> UUID { calls.append("begin"); return generation }
    func resume(generation: UUID) async throws { Issue.record("Unplanned ordinary resume"); throw PermissionBridgeFixtureError.unplannedCall }
    func resumeForSetup(generation: UUID) async throws { calls.append("resumeForSetup") }
    func finishSetupIfIdle() async { calls.append("finishSetupIfIdle") }
    func disconnect() async throws { Issue.record("Unplanned saved-installation disconnect"); throw PermissionBridgeFixtureError.unplannedCall }
    func repair(resumeRelay: Bool, expectedGeneration: UUID?) async throws -> UUID { Issue.record("Unplanned repair"); throw PermissionBridgeFixtureError.unplannedCall }
    func isCurrentLifecycle(_ generation: UUID) -> Bool { self.generation == generation }
    func connect(installation: DesktopControlInstallation, expectedGeneration: UUID?) async { calls.append("connect"); gatewayConnected = true }
    func savedInstallation(for appURL: URL) async throws -> DesktopControlInstallation? { Issue.record("Unplanned runtime credential read"); throw PermissionBridgeFixtureError.unplannedCall }
}

private actor PermissionBridgeEnrollment: DesktopControlSetupEnrollment {
    private(set) var calls: [String] = []
    let installation: DesktopControlInstallation
    let allowed: Set<String>
    private var configuration = DesktopControlConfigurationState(hasActiveConfig: true, hasConfig: true)
    init(installation: DesktopControlInstallation, allowed: Set<String> = []) { self.installation = installation; self.allowed = allowed }
    private func require(_ name: String) throws {
        calls.append(name)
        guard allowed.contains(name) else { Issue.record("Unplanned enrollment operation: \(name)"); throw PermissionBridgeFixtureError.unplannedCall }
    }
    func enroll(ticket: String, appURL: URL, commitCredential: (@MainActor @Sendable (DesktopControlInstallation) throws -> Void)?) async throws -> DesktopControlInstallation {
        try require("enroll")
        #expect(ticket == String(repeating: "a", count: 43))
        #expect(appURL == DesktopEnvironmentConfiguration.production.appURL)
        try await commitCredential?(installation)
        return installation
    }
    func reportReady(installation: DesktopControlInstallation, appURL: URL) async throws { try require("reportReady") }
    func attach(ticket: String, installation: DesktopControlInstallation, appURL: URL) async throws { try require("attach") }
    func configurationState(installation: DesktopControlInstallation, appURL: URL) async throws -> DesktopControlConfigurationState {
        try require("configurationState")
        return configuration
    }
    func setConfiguration(hasConfig: Bool, active: Bool) { configuration = .init(hasActiveConfig: active, hasConfig: hasConfig) }
    func hasActiveConfig(installation: DesktopControlInstallation, appURL: URL) async throws -> Bool { try require("hasActiveConfig"); return true }
}

@MainActor
private final class PermissionBridgePresenter: DesktopControlPermissionPresenting {
    var isFinishing = false
    var autoFinish = false
    private(set) var opens = 0
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
    let checklistVersion: String?
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

    init(allowEnrollment: Bool = false) throws {
        let configuration = DesktopEnvironmentConfiguration.production
        let payload = try JSONSerialization.data(withJSONObject: [
            "installation_id": "permission-fixture", "machine_credential": String(repeating: "A", count: 43),
            "gateway_websocket_url": configuration.gatewayWebsocketURL.absoluteString,
        ])
        var installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: payload)
        try installation.bindEnvironment(configuration.appURL, configuration: configuration)
        enrollment = PermissionBridgeEnrollment(installation: installation,
            allowed: allowEnrollment ? ["enroll", "reportReady", "configurationState"] : [])
        suite = "permission-bridge-\(UUID().uuidString)"
        preferences = try #require(UserDefaults(suiteName: suite))
        manager = DesktopControlSetupManager(runtime: runtime, enrollment: enrollment, credentials: credentials,
            preferences: preferences, registerLoginItem: { Issue.record("Unplanned login registration") },
            loginItemStatus: { .enabled }, configurationProvider: { configuration }, permissionPresenter: presenter)
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
                    checklistVersion: response?["permissions_checklist_version"] as? String,
                    prerequisitesReady: response?["prerequisites_ready"] as? Bool == true,
                    installationID: response?["installation_id"] as? String))
            }
        }
    }

    func permissions(_ phase: String, scope: String = "workspace-session", message: String? = nil) -> [String: Any] {
        var result: [String: Any] = ["version": "1", "action": "permissions", "scope": scope, "phase": phase]
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
}

@Test @MainActor func permissionBridgeStateAdvertisesChecklistWithoutEnrollmentOrRuntimeMutation() async throws {
    let fixture = try PermissionBridgeFixture()
    defer { fixture.cleanup() }
    let response = await fixture.send(["version": "1", "action": "state", "scope": "workspace-session"])
    #expect(response.ok && response.checklistVersion == "1")
    #expect(response.installationID == nil)
    #expect(fixture.credentials.counts.reads == 1)
    #expect(fixture.credentials.counts.saves == 0)
    #expect(fixture.runtime.calls.isEmpty)
    #expect(await fixture.enrollment.calls.isEmpty)
    #expect(fixture.presenter.opens == 0)
}

@Test @MainActor func permissionBridgeScopeSyncAdvertisesChecklistWithZeroProtectedReads() async throws {
    let fixture = try PermissionBridgeFixture()
    defer { fixture.cleanup() }
    let response = await fixture.send(["version": "1", "action": "sync", "scope": "workspace-session"])
    #expect(response.ok && response.checklistVersion == "1")
    #expect(fixture.credentials.counts.reads == 0 && fixture.credentials.counts.saves == 0)
    #expect(fixture.runtime.calls.isEmpty && fixture.presenter.opens == 0)
    #expect(await fixture.enrollment.calls.isEmpty)
}

@Test @MainActor func permissionBridgePrepareBeforeNativeFinishHasZeroProtectedReadsOrMutations() async throws {
    let fixture = try PermissionBridgeFixture()
    defer { fixture.cleanup() }
    let response = await fixture.send(fixture.prepare)
    #expect(!response.ok && response.error?.contains("native permission checklist") == true)
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
    #expect(ready.ok && ready.prerequisitesReady && ready.checklistVersion == "1")
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

@Test @MainActor func permissionBridgeNativeFinishPrecedesEnrollmentAndCompletionChecksConnection() async throws {
    let fixture = try PermissionBridgeFixture(allowEnrollment: true)
    defer { fixture.cleanup() }
    fixture.presenter.autoFinish = true
    let ready = await fixture.send(fixture.permissions("open"))
    #expect(ready.ok && fixture.credentials.counts.reads == 0)
    #expect(await fixture.enrollment.calls.isEmpty)
    let prepared = await fixture.send(fixture.prepare)
    #expect(prepared.ok && prepared.installationID == "permission-fixture")
    #expect(fixture.credentials.counts.reads == 1 && fixture.credentials.counts.saves == 1)
    #expect(fixture.runtime.calls == ["begin", "resumeForSetup", "probe", "connect"])
    #expect(await fixture.enrollment.calls == ["enroll", "reportReady"])
    fixture.runtime.gatewayConnected = false
    let disconnected = await fixture.send(fixture.permissions("completed"))
    #expect(!disconnected.ok && disconnected.code == "permissions_incomplete")
    #expect(fixture.presenter.completions == 0)
    fixture.runtime.gatewayConnected = true
    let completed = await fixture.send(fixture.permissions("completed"))
    #expect(completed.ok && fixture.presenter.completions == 1)
    #expect(await fixture.enrollment.calls == ["enroll", "reportReady", "configurationState"])
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
