import Foundation
import Testing
@testable import PersonaStack
@testable import PersonaStackCore

@MainActor
private final class GuidedPermissionFixture: DesktopPermissionChecklistAdapting {
    var values = Dictionary(uniqueKeysWithValues: DesktopPermissionID.allCases.map { ($0, DesktopPermissionObservation(.ready, detail: "Fixture ready")) })
    var requested: [DesktopPermissionID] = []
    var checked: [DesktopPermissionID] = []
    var openedSettings: [DesktopPermissionID] = []
    func openSettings(_ id: DesktopPermissionID) { openedSettings.append(id) }
    var grantsOnRequest = true
    var delayed: DesktopPermissionID?
    var pending: CheckedContinuation<DesktopPermissionObservation, Never>?
    func observe(_ id: DesktopPermissionID) async -> DesktopPermissionObservation { values[id]! }
    func setup(_ id: DesktopPermissionID) async -> DesktopPermissionObservation {
        requested.append(id)
        if delayed == id { return await withCheckedContinuation { pending = $0 } }
        if !grantsOnRequest { return values[id]! }
        let result = DesktopPermissionObservation(.ready, detail: "Fixture verified", verified: true)
        values[id] = result
        return result
    }
    func check(_ id: DesktopPermissionID) async -> DesktopPermissionObservation {
        checked.append(id)
        values[id] = .init(.ready, detail: "Fixture checked", verified: true)
        return values[id]!
    }
}

@Test func guidedPermissionModelHasSixStagesAndNoAudioOrNotificationRequirement() {
    #expect(DesktopPermissionStage.allCases.count == 6)
    #expect(DesktopPermissionStage.allCases.flatMap(\.permissions) == DesktopPermissionID.setupPermissions)
    #expect(!DesktopPermissionID.setupPermissions.contains(.microphone))
    #expect(!DesktopPermissionID.automaticSetup.contains(.notifications))
    for missing in DesktopPermissionReadiness.requiredPermissions {
        var observations = Dictionary(uniqueKeysWithValues: DesktopPermissionReadiness.requiredPermissions.map {
            ($0, DesktopPermissionObservation(.ready, detail: "Verified", verified: true))
        })
        #expect(DesktopPermissionReadiness(observations: observations).isReady)
        observations[missing] = .init(.verificationRequired, detail: "Unverified")
        #expect(DesktopPermissionReadiness(observations: observations).missing == [missing])
        observations.removeValue(forKey: missing)
        #expect(!DesktopPermissionReadiness(observations: observations).isReady)
    }
}

@Test @MainActor func guidedPermissionPresentationAndPollingNeverRequestCapabilities() async {
    let fixture = GuidedPermissionFixture()
    fixture.values[.microphone] = .init(.denied, detail: "Denied")
    fixture.values[.notifications] = .init(.denied, detail: "Denied")
    let coordinator = DesktopPermissionChecklistCoordinator(adapter: fixture)
    coordinator.open()
    defer { coordinator.cancel() }
    coordinator.startPresentationVerification()
    coordinator.startAutomaticSetup()
    await coordinator.refresh()
    fixture.values[.microphone] = .init(.ready, detail: "Granted", requiresVerification: true)
    fixture.values[.notifications] = .init(.ready, detail: "Granted", requiresVerification: true)
    await coordinator.resumeAfterActivation()
    #expect(fixture.requested.isEmpty && fixture.checked.isEmpty)
    #expect(!coordinator.hasStarted)
}

@Test @MainActor func guidedPermissionOneContinueAdvancesInOrderAndCompletesOnce() async {
    let fixture = GuidedPermissionFixture()
    for id in DesktopPermissionReadiness.guidedPermissions { fixture.values[id] = .init(.notGranted, detail: "Needs setup") }
    let coordinator = DesktopPermissionChecklistCoordinator(adapter: fixture)
    coordinator.open()
    await coordinator.refresh()
    let completion = Task { try await coordinator.waitForFinish() }
    while !coordinator.isAwaitingFinish { await Task.yield() }
    var completions = 0
    coordinator.onReady = { completions += 1; coordinator.finish() }
    coordinator.continueSetup()
    coordinator.continueSetup()
    try? await completion.value
    #expect(coordinator.isFinishing && completions == 1)
    #expect(fixture.requested == DesktopPermissionReadiness.guidedPermissions)
    #expect(!fixture.requested.contains(.microphone) && !fixture.requested.contains(.notifications))
    coordinator.cancel()
}

@Test(arguments: [DesktopPermissionState.denied, .verificationRequired, .unsupported, .checking, .restartRequired])
func guidedPermissionBrowserAccessDoesNotBlockRuntimeReadiness(state: DesktopPermissionState) {
    var observations = Dictionary(uniqueKeysWithValues: DesktopPermissionReadiness.requiredPermissions.map {
        ($0, DesktopPermissionObservation(.ready, detail: "Verified", verified: true))
    })
    for id in DesktopPermissionStage.browsers.permissions {
        observations[id] = .init(state, detail: "Optional browser permission", requiresVerification: true)
        #expect(!DesktopPermissionReadiness.requiredPermissions.contains(id))
        #expect(!DesktopPermissionRow(id: id, observation: observations[id]!).isRequiredForUnlockedSetup)
    }
    #expect(DesktopPermissionReadiness(observations: observations).isReady)
}

@Test(arguments: [DesktopPermissionID.automation, .safariJavaScript]) @MainActor
func guidedPermissionBrowserSkipContinuesWithoutGrantingBrowserAccess(blocked: DesktopPermissionID) async {
    let fixture = GuidedPermissionFixture()
    fixture.grantsOnRequest = false
    fixture.values[blocked] = .init(.denied, detail: "Browser access denied")
    fixture.values[.clipboard] = .init(.notGranted, detail: "Next required permission")
    let coordinator = DesktopPermissionChecklistCoordinator(adapter: fixture)
    coordinator.open()
    defer { coordinator.cancel() }
    await coordinator.refresh()
    coordinator.skipBrowsers()
    #expect(!coordinator.browsersSkipped && !coordinator.canSkipBrowsers)
    var completions = 0
    coordinator.onReady = { completions += 1; coordinator.finish() }
    coordinator.continueSetup()
    while coordinator.busyPermission != nil { await Task.yield() }
    #expect(coordinator.currentStage == .browsers && coordinator.canSkipBrowsers)
    coordinator.skipBrowsers()
    while coordinator.busyPermission != nil { await Task.yield() }
    #expect(coordinator.browsersSkipped && coordinator.currentStage == .clipboard)
    #expect(fixture.requested == [blocked, .clipboard])
    #expect(coordinator.rows.first { $0.id == blocked }?.state == .denied)
    #expect(coordinator.rows.first { $0.id == blocked }?.observation.verified == false)
    #expect(!coordinator.canFinish && completions == 0)
    await coordinator.refresh()
    #expect(fixture.requested == [blocked, .clipboard])
    fixture.grantsOnRequest = true
    coordinator.retryCurrentPermission()
    while coordinator.busyPermission != nil { await Task.yield() }
    #expect(coordinator.isFinishing && completions == 1)
    #expect(DesktopPermissionReadiness(rows: coordinator.rows).isReady)
    coordinator.skipBrowsers()
    #expect(completions == 1 && !coordinator.canSkipBrowsers)
    coordinator.cancel()
    #expect(!coordinator.browsersSkipped)
}

@Test(arguments: [DesktopPermissionID.automation, .safariJavaScript]) @MainActor
func guidedPermissionBrowserSkipFencesLateCheckWhileNextPermissionRuns(blocked: DesktopPermissionID) async {
    let fixture = GuidedPermissionFixture()
    fixture.values[blocked] = .init(.verificationRequired, detail: "Browser setting not verified")
    fixture.values[.clipboard] = .init(.notGranted, detail: "Clipboard approval required")
    fixture.delayed = blocked
    let coordinator = DesktopPermissionChecklistCoordinator(adapter: fixture)
    coordinator.open()
    defer { coordinator.cancel() }
    await coordinator.refresh()
    coordinator.continueSetup()
    while fixture.pending == nil { await Task.yield() }
    let browserCheck = fixture.pending
    fixture.pending = nil
    fixture.delayed = .clipboard
    coordinator.skipBrowsers()
    while fixture.pending == nil { await Task.yield() }
    browserCheck?.resume(returning: .init(.ready, detail: "Late browser result", verified: true))
    await Task.yield()
    await coordinator.refresh()
    #expect(coordinator.currentPermission == .clipboard && coordinator.busyPermission == .clipboard)
    #expect(coordinator.currentStage == .clipboard && coordinator.browsersSkipped)
    #expect(coordinator.rows.first { $0.id == blocked }?.state == .verificationRequired)
    #expect(fixture.checked.isEmpty && fixture.requested == [blocked, .clipboard])
    fixture.pending?.resume(returning: .init(.ready, detail: "Clipboard verified", verified: true))
    while coordinator.busyPermission != nil { await Task.yield() }
    #expect(coordinator.canFinish)
}

@Test @MainActor func guidedPermissionBrowserSettingsReturnWaitsForPendingCheckAndVerifiesAgain() async {
    let fixture = GuidedPermissionFixture()
    fixture.values[.safariJavaScript] = .init(.verificationRequired, detail: "Browser setting not yet enabled")
    fixture.delayed = .safariJavaScript
    let coordinator = DesktopPermissionChecklistCoordinator(adapter: fixture)
    coordinator.open()
    defer { coordinator.cancel() }
    await coordinator.refresh()
    coordinator.continueSetup()
    while fixture.pending == nil { await Task.yield() }
    var activationStarted = false
    let activation = Task {
        activationStarted = true
        await coordinator.resumeAfterActivation()
    }
    while !activationStarted { await Task.yield() }
    fixture.pending?.resume(returning: .init(.verificationRequired, detail: "Earlier setting read"))
    await activation.value
    while coordinator.busyPermission != nil { await Task.yield() }
    #expect(fixture.requested == [.safariJavaScript] && fixture.checked == [.safariJavaScript])
    #expect(coordinator.rows.first { $0.id == .safariJavaScript }?.state == .ready)
    #expect(coordinator.canFinish)
}

@Test @MainActor func guidedPermissionValidGrantsNeedNoRequestsAndNoFinishClick() async {
    let fixture = GuidedPermissionFixture()
    let coordinator = DesktopPermissionChecklistCoordinator(adapter: fixture)
    coordinator.open()
    await coordinator.refresh()
    var completions = 0
    coordinator.onReady = { completions += 1; coordinator.finish() }
    coordinator.continueSetup()
    #expect(completions == 1 && coordinator.isFinishing)
    #expect(fixture.requested.isEmpty && fixture.checked.isEmpty)
    coordinator.cancel()
}

@Test @MainActor func guidedPermissionCancelFencesLateResultAndNextPrompt() async {
    let fixture = GuidedPermissionFixture()
    fixture.values[.accessibility] = .init(.notGranted, detail: "Needs approval")
    fixture.values[.screenRecording] = .init(.notGranted, detail: "Needs approval")
    fixture.delayed = .accessibility
    let coordinator = DesktopPermissionChecklistCoordinator(adapter: fixture)
    coordinator.open()
    await coordinator.refresh()
    coordinator.continueSetup()
    while fixture.pending == nil { await Task.yield() }
    coordinator.cancel()
    fixture.pending?.resume(returning: .init(.ready, detail: "Late success", verified: true))
    await Task.yield()
    #expect(!coordinator.isVisible && !coordinator.hasStarted)
    #expect(fixture.requested == [.accessibility])
}

@Test @MainActor func guidedPermissionSetupPreservesExistingTCCChoices() async {
    var access = DesktopPermissionSystemAccess.permissionFixture()
    access.accessibility = { true }
    access.screenRecording = { true }
    access.resetPermission = { _ in Issue.record("Normal setup must not reset TCC"); return .failed }
    access.requestAccessibility = { Issue.record("Existing AX grant must not prompt") }
    access.requestScreenRecording = { Issue.record("Existing screen grant must not prompt"); return false }
    let adapter = DesktopPermissionChecklistSystemAdapter(access: access)
    #expect(await adapter.setup(.accessibility).state == .ready)
    #expect(await adapter.setup(.screenRecording).state == .ready)
}

@Test @MainActor func guidedPermissionCloudLANNeedsPrivacyProofBeforeEndpointSuccess() async {
    var networkRequests = 0
    var endpointRequests = 0
    let service = DesktopPermissionChecklist(access: .permissionFixture(), selectedProfile: { .production },
        activationNotificationCenter: NotificationCenter(), requestLocalNetwork: {
            networkRequests += 1
            return .init(.verificationRequired, detail: "No peer is not consent")
        }, requestEndpoint: { _ in
            endpointRequests += 1
            throw URLError(.cannotConnectToHost)
        })
    #expect(await service.adapter.observe(.localNetwork).state == .verificationRequired)
    #expect(networkRequests == 0 && endpointRequests == 0)
    #expect(await service.adapter.setup(.localNetwork).state == .verificationRequired)
    #expect(networkRequests == 1 && endpointRequests == 0)
    await service.window.coordinator.refresh()
    #expect(networkRequests == 1)
}

@Test @MainActor func guidedPermissionSettingsGrantAdvancesWithoutAnotherNativeClick() async {
    let fixture = GuidedPermissionFixture()
    fixture.grantsOnRequest = false
    fixture.values[.accessibility] = .init(.notGranted, detail: "Enable in Settings")
    fixture.values[.screenRecording] = .init(.notGranted, detail: "Next approval")
    let coordinator = DesktopPermissionChecklistCoordinator(adapter: fixture)
    coordinator.open()
    defer { coordinator.cancel() }
    await coordinator.refresh()
    coordinator.continueSetup()
    while coordinator.busyPermission != nil { await Task.yield() }
    #expect(fixture.requested == [.accessibility])
    #expect(coordinator.currentPermission == .accessibility)
    for _ in 0..<3 { await coordinator.refresh() }
    #expect(fixture.requested == [.accessibility])
    fixture.values[.accessibility] = .init(.ready, detail: "Granted", verified: true)
    fixture.grantsOnRequest = true
    await coordinator.refresh()
    while coordinator.busyPermission != nil { await Task.yield() }
    #expect(fixture.requested == [.accessibility, .screenRecording])
    #expect(coordinator.canFinish)
}

@Test @MainActor func guidedPermissionActivationChecksOnlyCurrentAuthorizedStep() async {
    let fixture = GuidedPermissionFixture()
    fixture.grantsOnRequest = false
    fixture.values[.fullDiskAccess] = .init(.notGranted, detail: "Enable Full Disk Access")
    let coordinator = DesktopPermissionChecklistCoordinator(adapter: fixture)
    coordinator.open()
    defer { coordinator.cancel() }
    await coordinator.refresh()
    await coordinator.resumeAfterActivation()
    #expect(fixture.checked.isEmpty)
    coordinator.continueSetup()
    while coordinator.busyPermission != nil { await Task.yield() }
    #expect(fixture.requested == [.fullDiskAccess])
    await coordinator.resumeAfterActivation()
    while coordinator.busyPermission != nil { await Task.yield() }
    #expect(fixture.checked == [.fullDiskAccess] && coordinator.canFinish)
    #expect(!fixture.requested.contains(.microphone))
}

@Test @MainActor func guidedPermissionHostCaptureAloneCannotQualifyOwnedDriver() async {
    var captures = 0
    var driverChecks = 0
    var driverWorks = false
    var access = DesktopPermissionSystemAccess.permissionFixture()
    access.screenRecording = { true }
    access.requestDirectCapture = { captures += 1; return true }
    let service = DesktopPermissionChecklist(access: access, evidence: nil, selectedProfile: { .production },
        verifyDesktopCapabilities: {
            driverChecks += 1
            if !driverWorks { throw CocoaError(.executableNotLoadable) }
        }, activationNotificationCenter: NotificationCenter())
    #expect(await service.adapter.observe(.directCapture).state == .verificationRequired)
    #expect(captures == 0 && driverChecks == 0)
    #expect(await service.adapter.setup(.directCapture).state == .failed)
    #expect(captures == 1 && driverChecks == 1)
    #expect(await service.adapter.observe(.directCapture).state == .verificationRequired)
    driverWorks = true
    #expect(await service.adapter.setup(.directCapture).verified)
    #expect(captures == 2 && driverChecks == 2)
    #expect(await service.adapter.observe(.directCapture).verified)
    #expect(captures == 2 && driverChecks == 2)
}

@Test @MainActor func guidedPermissionCancellationDiscardsLateOwnedDriverProof() async {
    var pending: CheckedContinuation<Void, Never>?
    var access = DesktopPermissionSystemAccess.permissionFixture()
    access.screenRecording = { true }
    access.requestDirectCapture = { true }
    let service = DesktopPermissionChecklist(access: access, evidence: nil, selectedProfile: { .production },
        verifyDesktopCapabilities: { await withCheckedContinuation { pending = $0 } },
        activationNotificationCenter: NotificationCenter())
    let operation = Task { await service.adapter.setup(.directCapture) }
    while pending == nil { await Task.yield() }
    service.cancelVerification()
    pending?.resume()
    #expect(await operation.value.state == .checking)
    #expect(await service.adapter.observe(.directCapture).verified == false)
}

@Test @MainActor func guidedPermissionBrowserStageIncludesSelectedTargetsAndKeepsPollingPassive() async {
    var selectedReady = false
    var selectedRequests = 0
    var selectedChecks = 0
    var safariChecks = 0
    var access = DesktopPermissionSystemAccess.permissionFixture()
    access.automation = { prompt in #expect(!prompt); return 0 }
    access.safariProcessIdentifier = { 42 }
    access.safariProcessIdentity = { "safari-javascript:42:fixture" }
    access.verifySafariJavaScript = { safariChecks += 1; return true }
    access.selectedBrowserObservation = {
        .init(selectedReady ? .ready : .verificationRequired, detail: "Selected browser", verified: selectedReady)
    }
    access.selectedBrowserSetup = {
        selectedRequests += 1
        return .init(.verificationRequired, detail: "Enable selected browser JavaScript")
    }
    access.selectedBrowserCheck = {
        selectedChecks += 1
        selectedReady = true
        return .init(.ready, detail: "Selected browser verified", verified: true)
    }
    let adapter = DesktopPermissionChecklistSystemAdapter(access: access, evidence: nil)
    #expect(await adapter.observe(.safariJavaScript).state == .verificationRequired)
    #expect(safariChecks == 0 && selectedRequests == 0 && selectedChecks == 0)
    #expect(await adapter.setup(.safariJavaScript).state == .verificationRequired)
    #expect(safariChecks == 1 && selectedRequests == 1 && selectedChecks == 0)
    #expect(await adapter.observe(.safariJavaScript).state == .verificationRequired)
    #expect(selectedChecks == 0)
    #expect(await adapter.check(.safariJavaScript).verified)
    #expect(selectedChecks == 1 && safariChecks == 2)
    selectedReady = false
    #expect(await adapter.observe(.safariJavaScript).state == .verificationRequired)
}

@Test @MainActor func guidedPermissionClipboardProbeKeepsMainActorResponsive() async {
    let (entered, signalEntered) = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    let probe = Task {
        await DesktopClipboardPermission.runDiscardedProbe {
            #expect(!Thread.isMainThread)
            signalEntered.yield(())
            signalEntered.finish()
            release.wait()
        }
    }
    for await _ in entered { break }
    // Running here proves that a blocked read does not block native close events.
    let fixture = GuidedPermissionFixture()
    let coordinator = DesktopPermissionChecklistCoordinator(adapter: fixture)
    coordinator.open()
    coordinator.cancel()
    #expect(!coordinator.isVisible)
    release.signal()
    await probe.value
}

@Test @MainActor func guidedPermissionRestartHintDoesNotAuthorizeOrStartSetup() {
    let fixture = GuidedPermissionFixture()
    let coordinator = DesktopPermissionChecklistCoordinator(adapter: fixture)
    let window = DesktopPermissionChecklistWindow(coordinator: coordinator, resumesPermissionSetup: true)
    #expect(window.setupActionTitle == "Resume setup")
    #expect(!coordinator.hasStarted)
    #expect(fixture.requested.isEmpty)
}

private actor GuidedInstalledPerceptionFixture: CuaPerceptionInstalling {
    var catalogURL: URL { URL(fileURLWithPath: "/fixture/catalog.json") }
    func status(driver: CuaDriverInstallation) async throws -> CuaPerceptionStatus {
        .init(installed: true, healthy: true, version: CuaPerceptionCompatibility.version)
    }
    func prepareReview(driver: CuaDriverInstallation) async throws -> CuaPerceptionInstallReview {
        Issue.record("A healthy installed component must not download another review")
        throw CuaPerceptionError.invalidReview
    }
    func install(review: CuaPerceptionInstallReview) async throws -> CuaPerceptionStatus {
        Issue.record("A healthy installed component must not be reinstalled")
        throw CuaPerceptionError.approvalRequired
    }
    func cancelReview() async {}
}

@Test @MainActor func guidedPermissionPerceptionReusesInstallButRequiresCurrentParserProof() async {
    var checks = 0
    var identity = "installed-v1"
    let perception = DesktopPerceptionSetupController(installer: GuidedInstalledPerceptionFixture())
    let service = DesktopPermissionChecklist(access: .permissionFixture(), evidence: nil,
        observeVisualPerception: { .init(.verificationRequired, detail: "Needs parser proof", verificationKey: identity) },
        prepareVisualPerception: { .init(applicationURL: URL(fileURLWithPath: "/fixture/Cua.app"), executableURL: URL(fileURLWithPath: "/fixture/cua"), version: "test", toolNames: []) },
        verifyVisualPerception: { checks += 1 },
        windowFactory: { .init(coordinator: $0, perception: perception) })
    #expect(await service.adapter.observe(.visualPerception).state == .verificationRequired)
    #expect(checks == 0)
    #expect(await service.adapter.setup(.visualPerception).verified)
    #expect(checks == 1 && perception.review == nil)
    #expect(await service.adapter.observe(.visualPerception).verified)
    identity = "installed-v2"
    #expect(await service.adapter.observe(.visualPerception).state == .verificationRequired)
}

@Test @MainActor func guidedPermissionPerceptionCancellationDiscardsLateParserProof() async {
    var pending: CheckedContinuation<Void, Never>?
    let perception = DesktopPerceptionSetupController(installer: GuidedInstalledPerceptionFixture())
    let service = DesktopPermissionChecklist(access: .permissionFixture(), evidence: nil,
        observeVisualPerception: { .init(.verificationRequired, detail: "Needs parser proof", verificationKey: "installed") },
        prepareVisualPerception: { .init(applicationURL: URL(fileURLWithPath: "/fixture/Cua.app"), executableURL: URL(fileURLWithPath: "/fixture/cua"), version: "test", toolNames: []) },
        verifyVisualPerception: { await withCheckedContinuation { pending = $0 } },
        windowFactory: { .init(coordinator: $0, perception: perception) })
    let task = Task { await service.adapter.setup(.visualPerception) }
    while pending == nil { await Task.yield() }
    service.window.cancel()
    pending?.resume()
    let result = await task.value
    #expect(!result.verified)
    #expect(await service.adapter.observe(.visualPerception).state == .verificationRequired)
}

@Test(arguments: [true, false]) @MainActor
func guidedPermissionBusyLeaseCannotChangeConsent(busyInitially: Bool) async throws {
    let suite = "GuidedBusyConsent-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    var lockedChecks = 0
    var availabilityChecks = 0
    var authorizations = 0
    let verifier = DesktopLockedControlSetupVerifier(defaults: preferences, operations: .init(inspect: {
        lockedChecks += 1
        return .ready
    }))
    let target = DesktopBrowserConsentTarget(pid: 42, windowID: 7, bundleIdentifier: "com.google.Chrome",
        launchedAt: Date(timeIntervalSince1970: 100), codeIdentity: "fixture")
    let browsers = DesktopBrowserProfileConsentController(inventory: { [target] }, evidence: nil)
    browsers.refresh()
    browsers.setSelected(true, id: target.id)
    let fixture = GuidedPermissionFixture()
    let coordinator = DesktopPermissionChecklistCoordinator(adapter: fixture)
    let window = DesktopPermissionChecklistWindow(coordinator: coordinator, browserConsent: browsers,
        canStartSetup: { availabilityChecks += 1; return !busyInitially && availabilityChecks == 1 },
        supportsFullControl: { true }, lockedControlVerifier: verifier,
        authorizeFullControl: { _ in authorizations += 1; return true })
    coordinator.open()
    defer { coordinator.cancel() }
    await window.continueSetup()
    #expect(lockedChecks == (busyInitially ? 0 : 1))
    #expect(authorizations == 0 && !verifier.permitsLockedControl)
    #expect(!browsers.hasApprovedTargets && !coordinator.hasStarted)
    #expect(fixture.requested.isEmpty)
    #expect(coordinator.completionError.contains("remote task"))
}

@Test @MainActor func guidedPermissionScreenRecordingStaleDenialOffersExplicitRestartWithoutRepeatedRequests() async {
    let fixture = GuidedPermissionFixture()
    fixture.grantsOnRequest = false
    fixture.values[.screenRecording] = .init(.notGranted, detail: "Initial host request returned false")
    let coordinator = DesktopPermissionChecklistCoordinator(adapter: fixture)
    coordinator.open()
    defer { coordinator.cancel() }
    await coordinator.refresh()
    #expect(!coordinator.canRestart && !coordinator.screenRecordingNeedsRestartRecheck)
    coordinator.continueSetup()
    while coordinator.busyPermission != nil { await Task.yield() }
    coordinator.openSettings(.screenRecording)
    // Settings can grant access while this process's public preflight stays false.
    for _ in 0..<3 { await coordinator.resumeAfterActivation() }
    #expect(fixture.requested == [.screenRecording] && fixture.checked.isEmpty)
    #expect(coordinator.canRestart && coordinator.screenRecordingNeedsRestartRecheck)
    #expect(coordinator.primaryActionTitle == "Restart PersonaStack" && !coordinator.canFinish)
    // If the public check becomes current, the ordinary flow continues directly.
    fixture.values[.screenRecording] = .init(.ready, detail: "Fresh OS grant", verified: true)
    await coordinator.refresh()
    #expect(!coordinator.requiresAppRestart && coordinator.canFinish)
    #expect(fixture.requested == [.screenRecording])
}

@Test @MainActor func guidedPermissionScreenRestartHonorsBusyCancellationAndFreshScope() async {
    let fixture = GuidedPermissionFixture()
    fixture.values[.screenRecording] = .init(.notGranted, detail: "Pending OS approval")
    fixture.delayed = .screenRecording
    let coordinator = DesktopPermissionChecklistCoordinator(adapter: fixture)
    coordinator.open()
    await coordinator.refresh()
    var available = true
    var restarts = 0
    let window = DesktopPermissionChecklistWindow(coordinator: coordinator, canStartSetup: { available },
        restartApplication: { restarts += 1 })
    coordinator.continueSetup()
    while fixture.pending == nil { await Task.yield() }
    window.restart()
    #expect(restarts == 0 && !coordinator.canRestart)
    fixture.pending?.resume(returning: fixture.values[.screenRecording]!)
    fixture.pending = nil
    while coordinator.busyPermission != nil { await Task.yield() }
    available = false
    window.restart()
    #expect(restarts == 0 && coordinator.isVisible)
    #expect(coordinator.completionError.contains("remote task"))
    available = true
    coordinator.failSetup("Scope expired.")
    window.restart()
    #expect(restarts == 0)
    coordinator.cancel()
    window.restart()
    #expect(restarts == 0 && !coordinator.canRestart)
    coordinator.open()
    await coordinator.refresh()
    #expect(!coordinator.screenRecordingNeedsRestartRecheck)
    fixture.delayed = nil
    fixture.grantsOnRequest = false
    coordinator.continueSetup()
    while coordinator.busyPermission != nil { await Task.yield() }
    window.restart()
    window.restart()
    #expect(restarts == 1 && !coordinator.isVisible)
}

@Test(arguments: DesktopPermissionReadiness.requiredPermissions) @MainActor
func guidedPermissionWaitingStatesKeepSettingsAndCancellationWithoutUnrelatedRestart(_ permission: DesktopPermissionID) async {
    let fixture = GuidedPermissionFixture()
    fixture.grantsOnRequest = false
    fixture.values[permission] = .init(.notGranted, detail: "Waiting for approval")
    let coordinator = DesktopPermissionChecklistCoordinator(adapter: fixture)
    coordinator.open()
    await coordinator.refresh()
    coordinator.continueSetup()
    while coordinator.busyPermission != nil { await Task.yield() }
    await coordinator.refresh()
    #expect(fixture.requested == [permission])
    #expect(coordinator.currentPermission == permission)
    #expect(coordinator.screenRecordingNeedsRestartRecheck == (permission == .screenRecording))
    if permission != .visualPerception {
        coordinator.openSettings(permission)
        #expect(fixture.openedSettings == [permission])
    }
    coordinator.cancel()
    #expect(!coordinator.isVisible && !coordinator.canRestart)
}
