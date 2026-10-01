import AppKit
import Foundation
import Testing
import ServiceManagement
import UserNotifications
@testable import PersonaStack
@testable import PersonaStackCore

@MainActor
private final class PermissionChecklistFake: DesktopPermissionChecklistAdapting {
    var values: [DesktopPermissionID: DesktopPermissionObservation] = [:]
    var setupValues: [DesktopPermissionID: DesktopPermissionObservation] = [:]
    var observed: [DesktopPermissionID] = []
    var requested: [DesktopPermissionID] = []
    var pendingSetup: CheckedContinuation<DesktopPermissionObservation, Never>?
    var delaySetup = false
    var suspendedObservation: DesktopPermissionID?
    var pendingObservation: CheckedContinuation<DesktopPermissionObservation, Never>?

    func observe(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation {
        observed.append(permission)
        if suspendedObservation == permission {
            suspendedObservation = nil
            return await withCheckedContinuation { pendingObservation = $0 }
        }
        return values[permission] ?? .init(.ready, detail: "Ready")
    }

    func setup(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation {
        requested.append(permission)
        if delaySetup {
            return await withCheckedContinuation { pendingSetup = $0 }
        }
        return setupValues[permission] ?? values[permission] ?? .init(.ready, detail: "Ready")
    }
}

@Test @MainActor func permissionChecklistWindowStartsAtUsableSizeAndPreservesResizing() async throws {
    _ = NSApplication.shared
    let fake = PermissionChecklistFake()
    let model = DesktopPermissionChecklistCoordinator(adapter: fake)
    let owner = DesktopPermissionChecklistWindow(coordinator: model)
    let window = owner.makeWindowIfNeeded()
    defer { model.cancel(); window.close() }
    let view = try #require(window.contentView)
    view.layoutSubtreeIfNeeded()
    #expect(view.bounds.size == NSSize(width: 670, height: 740))
    #expect(window.contentMinSize == NSSize(width: 560, height: 460))
    #expect(!window.isVisible)

    model.open()
    await model.refresh()
    view.layoutSubtreeIfNeeded()
    #expect(model.rows.count == DesktopPermissionID.allCases.count)
    #expect(view.bounds.size == NSSize(width: 670, height: 740))
    #expect(fake.requested.isEmpty)

    window.setContentSize(NSSize(width: 800, height: 600))
    await model.refresh()
    view.layoutSubtreeIfNeeded()
    #expect(owner.makeWindowIfNeeded() === window)
    #expect(view.bounds.size == NSSize(width: 800, height: 600))
    #expect(!window.isVisible)
}

@Test @MainActor func permissionChecklistRefreshNeverRequestsPermissions() async {
    let fake = PermissionChecklistFake()
    fake.values[.lockedScreenControl] = .init(.unsupported, detail: "No qualified helper")
    fake.values[.accessibility] = .init(.denied, detail: "Approval required")
    let model = DesktopPermissionChecklistCoordinator(adapter: fake)
    model.open()
    await model.refresh()
    #expect(fake.requested.isEmpty)
    #expect(model.rows.count == DesktopPermissionID.allCases.count)
    #expect(!model.canFinish)
    #expect(model.rows.first { $0.id == .lockedScreenControl }?.state == .unsupported)
    model.finish()
    #expect(!model.isFinishing)
    model.cancel()
}

@Test func permissionChecklistEveryIncompleteStateBlocksFinish() {
    for state in DesktopPermissionState.allCases {
        let row = DesktopPermissionRow(id: .accessibility, observation: .init(state, detail: state.title))
        #expect(row.isComplete == (state == .ready || state == .notNeeded))
    }
    let allowed = DesktopPermissionRow(id: .screenRecording,
                                      observation: .init(.ready, detail: "Allowed", requiresVerification: true))
    #expect(!allowed.isComplete)
    #expect(allowed.state == .verificationRequired)
}

@Test @MainActor func permissionChecklistPrivacyRecoveryMatchesTheSettingsPane() {
    let accessibility = DesktopPermissionChecklistSystemAdapter.privacyDenialObservation(.accessibility)
    #expect(accessibility.state == .notGranted)
    #expect(accessibility.detail.contains("remove the old PersonaStack entry"))
    #expect(accessibility.detail.contains("PersonaStack.app from Applications"))
    for id in [DesktopPermissionID.microphone, .screenRecording, .directCapture] {
        let observation = DesktopPermissionChecklistSystemAdapter.privacyDenialObservation(id)
        #expect(observation.state == (id == .microphone ? .denied : .notGranted))
        #expect(observation.detail.contains("turn it off and on"))
        #expect(observation.detail.contains("Relaunch PersonaStack if macOS requests it"))
        #expect(!observation.detail.contains("remove"))
        #expect(!observation.detail.contains("Click +"))
        #expect(!observation.verified)
    }
}

@Test @MainActor func permissionChecklistReauthorizationStillRequiresGrantAndFunctionalProof() async {
    // Moving from an unsigned release may require fresh TCC approval.
    // Recovery guidance must never turn an enabled Settings entry into proof.
    for id in [DesktopPermissionID.accessibility, .screenRecording, .microphone] {
        let fake = PermissionChecklistFake()
        let denied = DesktopPermissionChecklistSystemAdapter.privacyDenialObservation(id)
        fake.values[id] = denied
        let model = DesktopPermissionChecklistCoordinator(adapter: fake)
        model.open()
        await model.refresh()
        #expect(model.rows.first { $0.id == id }?.state == denied.state)
        #expect(!model.canFinish)
        #expect(fake.requested.isEmpty)

        model.setup(id)
        while model.busyPermission != nil { await Task.yield() }
        #expect(model.rows.first { $0.id == id }?.state == denied.state)
        #expect(!model.canFinish)

        fake.values[id] = .init(.ready, detail: "macOS grant observed", verificationKey: "current-owner",
                                requiresVerification: true)
        await model.refresh()
        #expect(model.rows.first { $0.id == id }?.state == .verificationRequired)
        #expect(!model.canFinish)
        #expect(fake.requested == [id])

        fake.setupValues[id] = .init(.ready, detail: "Operation verified", verificationKey: "current-owner",
                                     requiresVerification: true, verified: true)
        model.setup(id)
        while model.busyPermission != nil { await Task.yield() }
        #expect(model.rows.first { $0.id == id }?.state == .ready)
        #expect(model.canFinish)

        fake.values[id] = denied
        await model.refresh()
        #expect(model.rows.first { $0.id == id }?.state == denied.state)
        #expect(!model.canFinish)
        #expect(fake.requested == [id, id])
        model.cancel()
    }
}

@Test @MainActor func permissionChecklistExplicitProofSurvivesPollingOnlyForItsCurrentKey() async {
    let fake = PermissionChecklistFake()
    fake.values[.accessibility] = .init(.ready, detail: "Allowed", verificationKey: "owner-generation-1", requiresVerification: true)
    fake.setupValues[.accessibility] = .init(.ready, detail: "Verified", verificationKey: "owner-generation-1",
                                           requiresVerification: true, verified: true)
    let model = DesktopPermissionChecklistCoordinator(adapter: fake)
    model.open()
    await model.refresh()
    #expect(!model.canFinish)
    model.setup(.accessibility)
    while model.busyPermission != nil { await Task.yield() }
    #expect(fake.requested == [.accessibility])
    #expect(model.canFinish)
    await model.refresh()
    #expect(model.canFinish)
    fake.values[.accessibility] = .init(.ready, detail: "Owner changed", verificationKey: "owner-generation-2", requiresVerification: true)
    await model.refresh()
    #expect(!model.canFinish)
    fake.values[.accessibility] = .init(.ready, detail: "Original owner returned", verificationKey: "owner-generation-1", requiresVerification: true)
    await model.refresh()
    #expect(!model.canFinish)
    #expect(fake.requested == [.accessibility])
    fake.values[.accessibility] = .init(.denied, detail: "Revoked")
    await model.refresh()
    #expect(model.rows.first { $0.id == .accessibility }?.state == .denied)
    model.cancel()
}

@Test @MainActor func permissionChecklistMicrophoneInvalidationBlocksFinishBeforePolling() async {
    let fake = PermissionChecklistFake()
    fake.values[.microphone] = .init(.ready, detail: "Allowed", verificationKey: "device-document", requiresVerification: true)
    fake.setupValues[.microphone] = .init(.ready, detail: "Verified", verificationKey: "device-document", requiresVerification: true, verified: true)
    let model = DesktopPermissionChecklistCoordinator(adapter: fake)
    model.open()
    await model.refresh()
    model.setup(.microphone)
    while model.busyPermission != nil { await Task.yield() }
    #expect(model.canFinish)
    let requests = fake.requested
    model.invalidateVerification(.microphone)
    #expect(!model.canFinish)
    #expect(model.rows.first { $0.id == .microphone }?.state == .verificationRequired)
    model.finish()
    #expect(!model.isFinishing)
    await model.refresh()
    #expect(!model.canFinish && fake.requested == requests)
    model.setup(.microphone)
    while model.busyPermission != nil { await Task.yield() }
    #expect(model.canFinish && fake.requested == [.microphone, .microphone])
    model.cancel()
}

@Test @MainActor func permissionChecklistCancelFencesLateSetupResultsAndClearsProofOnReopen() async {
    let fake = PermissionChecklistFake()
    fake.delaySetup = true
    fake.values[.microphone] = .init(.denied, detail: "Denied")
    let model = DesktopPermissionChecklistCoordinator(adapter: fake)
    model.open()
    await model.refresh()
    model.setup(.microphone)
    while fake.pendingSetup == nil { await Task.yield() }
    model.cancel()
    fake.pendingSetup?.resume(returning: .init(.ready, detail: "Stale success", verified: true))
    fake.pendingSetup = nil
    await Task.yield()
    model.open()
    await model.refresh()
    #expect(model.rows.first { $0.id == .microphone }?.state == .denied)
    #expect(!model.canFinish)
    model.cancel()
}

@Test @MainActor func permissionChecklistFinishAwaitsNativeClickAndRemainsFinishingUntilCompletion() async throws {
    let fake = PermissionChecklistFake()
    let model = DesktopPermissionChecklistCoordinator(adapter: fake)
    model.open()
    await model.refresh()
    let completion = Task { try await model.waitForFinish() }
    while !model.isAwaitingFinish { await Task.yield() }
    #expect(model.canFinish)
    #expect(!model.isFinishing)
    model.finish()
    try await completion.value
    #expect(model.isFinishing)
    #expect(!model.canFinish)
    model.failSetup("Connection failed")
    #expect(!model.isFinishing)
    #expect(model.completionError.contains("Connection failed"))
    #expect(model.completionError.contains("Desktop Control page to retry setup"))
    #expect(model.needsNewSetupRequest && !model.canFinish)
    model.cancel()
}

@Test @MainActor func permissionChecklistFailedEnrollmentRequiresFreshBrowserRequestBeforeNativeFinish() async throws {
    let model = DesktopPermissionChecklistCoordinator(adapter: PermissionChecklistFake())
    let window = DesktopPermissionChecklistWindow(coordinator: model)
    model.open()
    await model.refresh()
    let firstRequest = Task { try await model.waitForFinish() }
    while !model.isAwaitingFinish { await Task.yield() }
    window.finish()
    try await firstRequest.value
    #expect(model.isFinishing && model.isVisible)

    model.failSetup("Enrollment failed.")
    await model.refresh()
    let rowsComplete = model.rows.allSatisfy(\.isComplete)
    #expect(rowsComplete)
    #expect(model.needsNewSetupRequest && !model.canFinish)
    #expect(model.completionError.contains("Desktop Control page to retry"))
    window.finish()
    #expect(!model.isFinishing && model.isVisible)

    let retryRequest = Task { try await model.waitForFinish() }
    while !model.isAwaitingFinish { await Task.yield() }
    #expect(!model.needsNewSetupRequest && model.canFinish)
    #expect(model.completionError.isEmpty)
    window.finish()
    try await retryRequest.value
    #expect(model.isFinishing && model.isVisible)
    window.completeSetup()
    #expect(!model.isVisible)
}

@Test @MainActor func permissionChecklistRepairFinishRemainsAvailableWithoutEnrollmentRequest() async {
    let model = DesktopPermissionChecklistCoordinator(adapter: PermissionChecklistFake())
    let window = DesktopPermissionChecklistWindow(coordinator: model)
    model.open()
    await model.refresh()
    #expect(model.canFinish && !model.isAwaitingFinish && !model.needsNewSetupRequest)
    window.finish()
    #expect(!model.isVisible && !model.isFinishing)
}

@Test @MainActor func permissionChecklistCancelledWaitThrowsWithoutCompletingSetup() async {
    let model = DesktopPermissionChecklistCoordinator(adapter: PermissionChecklistFake())
    let completion = Task { try await model.waitForFinish() }
    while !model.isAwaitingFinish { await Task.yield() }
    model.cancel()
    do {
        try await completion.value
        Issue.record("Cancelled setup unexpectedly completed")
    } catch { #expect(error is CancellationError) }
    #expect(!model.isFinishing)
}

@Test @MainActor func permissionChecklistReopenCannotFinishUsingOldReadyRows() async {
    let model = DesktopPermissionChecklistCoordinator(adapter: PermissionChecklistFake())
    model.open()
    await model.refresh()
    #expect(model.canFinish)
    model.cancel()
    model.open()
    #expect(!model.canFinish)
    #expect(model.rows.allSatisfy { $0.state == .checking })
    await model.refresh()
    #expect(model.canFinish)
    model.cancel()
}

@Test @MainActor func permissionChecklistNativeStatusMappingAndUnsupportedFeaturesStayTruthful() {
    #expect(DesktopPermissionChecklistSystemAdapter.loginObservation(.requiresApproval).state == .notGranted)
    #expect(DesktopPermissionChecklistSystemAdapter.loginObservation(.notFound).state == .failed)
    #expect(DesktopPermissionChecklistSystemAdapter.loginObservation(.enabled).state == .ready)
    #expect(DesktopPermissionChecklistSystemAdapter.notificationObservation(authorization: .denied, alerts: .disabled, sounds: .disabled).state == .denied)
    #expect(DesktopPermissionChecklistSystemAdapter.notificationObservation(authorization: .authorized, alerts: .enabled, sounds: .disabled).state == .notGranted)
    let allowed = DesktopPermissionChecklistSystemAdapter.notificationObservation(authorization: .authorized, alerts: .enabled, sounds: .enabled)
    #expect(!allowed.requiresVerification)
    #expect(DesktopPermissionRow(id: .notifications, observation: allowed).isComplete)
    #expect(DesktopPermissionChecklistSystemAdapter.unconfiguredObservation(.lockedScreenControl).state == .unsupported)
    #expect(DesktopPermissionChecklistSystemAdapter.unconfiguredObservation(.fullDiskAccess).state == .unsupported)
    #expect(DesktopPermissionChecklistSystemAdapter.unconfiguredObservation(.speechRecognition).state == .notNeeded)
}

@Test @MainActor func permissionChecklistUnlockedEnrollmentKeepsUnavailableFullAccessVisible() async throws {
    let fake = PermissionChecklistFake()
    for id in [DesktopPermissionID.lockedScreenControl, .fullDiskAccess] {
        fake.values[id] = DesktopPermissionChecklistSystemAdapter.unconfiguredObservation(id)
    }
    let model = DesktopPermissionChecklistCoordinator(adapter: fake)
    model.open()
    await model.refresh()
    #expect(model.canFinish)
    for row in model.rows where row.id == .lockedScreenControl || row.id == .fullDiskAccess {
        #expect(row.state == .unsupported)
        #expect(!row.isComplete)
    }
    let request = Task { try await model.waitForFinish() }
    while !model.isAwaitingFinish { await Task.yield() }
    model.finish()
    try await request.value
    #expect(model.isFinishing)
    #expect(fake.requested.isEmpty)
    model.cancel()
}

@Test @MainActor func permissionChecklistOnlyRequiredPermissionsBlockFinish() async {
    for id in DesktopPermissionID.allCases {
        for state in DesktopPermissionState.allCases where !state.satisfiesSetup {
            let fake = PermissionChecklistFake()
            fake.values[id] = .init(state, detail: "Incomplete")
            let model = DesktopPermissionChecklistCoordinator(adapter: fake)
            model.open()
            await model.refresh()
            let required = [.accessibility, .screenRecording, .microphone, .localNetwork].contains(id)
            #expect(model.canFinish == !required, "Finish policy for \(id) \(state)")
            model.finish()
            #expect(model.isFinishing == !required)
            model.cancel()
        }
    }
}


@Test @MainActor func permissionChecklistDesktopServiceFailuresStayInTheirRowsWhileMicrophoneVerifies() async {
    let fake = PermissionChecklistFake()
    let serviceFailure = CuaMCPProxyError.serviceMismatch.localizedDescription
    let desktopRows: [DesktopPermissionID] = [.accessibility, .screenRecording, .directCapture]
    for id in desktopRows {
        fake.values[id] = .init(.ready, detail: "OS grant present", verificationKey: "desktop-grant", requiresVerification: true)
        fake.setupValues[id] = .init(.failed, detail: serviceFailure)
    }
    fake.values[.microphone] = .init(.ready, detail: "Audio grant present", verificationKey: "audio-device-page", requiresVerification: true)
    fake.setupValues[.microphone] = .init(.ready, detail: "Voice recording verified", verificationKey: "audio-device-page", requiresVerification: true, verified: true)
    let model = DesktopPermissionChecklistCoordinator(adapter: fake)
    model.open()
    defer { model.cancel() }
    await model.refresh()
    for id in desktopRows {
        model.setup(id)
        while model.busyPermission != nil { await Task.yield() }
    }
    model.setup(.microphone)
    while model.busyPermission != nil { await Task.yield() }
    for _ in 0..<3 { await model.refresh() }
    for id in desktopRows {
        #expect(model.rows.first { $0.id == id }?.state == .failed)
        #expect(model.rows.first { $0.id == id }?.observation.detail == serviceFailure)
    }
    let microphone = model.rows.first { $0.id == .microphone }
    #expect(microphone?.isComplete == true)
    #expect(microphone?.observation.detail == "Voice recording verified")
    #expect(fake.requested == desktopRows + [.microphone])
    #expect(!model.canFinish)
}

@Test @MainActor func permissionChecklistFailureSurvivesPollingUntilRetryOrGrantChange() async {
    for id in [DesktopPermissionID.accessibility, .screenRecording, .microphone, .notifications, .localNetwork, .launchAtLogin] {
        let fake = PermissionChecklistFake()
        let state: DesktopPermissionState = id == .launchAtLogin ? .notGranted : (id == .localNetwork ? .verificationRequired : .ready)
        fake.values[id] = .init(state, detail: "Approval alone is not functional proof", verificationKey: "owner-grant-A", requiresVerification: true)
        fake.setupValues[id] = .init(.failed, detail: "The actual operation failed")
        let model = DesktopPermissionChecklistCoordinator(adapter: fake)
        model.open()
        await model.refresh()
        #expect(model.rows.first { $0.id == id }?.state == (state == .ready ? .verificationRequired : state))
        model.setup(id)
        while model.busyPermission != nil { await Task.yield() }
        for _ in 0..<3 { await model.refresh() }
        #expect(model.rows.first { $0.id == id }?.state == .failed)
        #expect(model.rows.first { $0.id == id }?.observation.detail == "The actual operation failed")
        #expect(fake.requested == [id])
        #expect(model.canFinish == !DesktopPermissionRow(id: id, observation: .init(.failed, detail: "Failed")).isRequiredForUnlockedSetup)

        fake.values[id] = .init(.ready, detail: "Changed owner or grant", verificationKey: "owner-grant-B", requiresVerification: true)
        await model.refresh()
        #expect(model.rows.first { $0.id == id }?.state == .verificationRequired)
        fake.setupValues[id] = .init(.ready, detail: "Operation verified", verificationKey: "owner-grant-B", requiresVerification: true, verified: true)
        model.setup(id)
        while model.busyPermission != nil { await Task.yield() }
        await model.refresh()
        #expect(model.rows.first { $0.id == id }?.state == .ready)
        #expect(model.rows.first { $0.id == id }?.observation.detail == "Operation verified")
        #expect(fake.requested == [id, id])
        fake.values[id] = .init(.denied, detail: "Permission revoked")
        await model.refresh()
        #expect(model.rows.first { $0.id == id }?.state == .denied)
        #expect(model.canFinish == !DesktopPermissionRow(id: id, observation: .init(.denied, detail: "Denied")).isRequiredForUnlockedSetup)
        model.cancel()
    }
}

@Test @MainActor func permissionChecklistOlderRefreshCannotReplaceCompletedSetup() async {
    let fake = PermissionChecklistFake()
    fake.values[.accessibility] = .init(.ready, detail: "Allowed", verificationKey: "current", requiresVerification: true)
    fake.setupValues[.accessibility] = .init(.ready, detail: "Actual input verified", verificationKey: "current", requiresVerification: true, verified: true)
    let model = DesktopPermissionChecklistCoordinator(adapter: fake)
    model.open()
    await model.refresh()
    fake.suspendedObservation = .accessibility
    let oldRefresh = Task { await model.refresh() }
    while fake.pendingObservation == nil { await Task.yield() }
    model.setup(.accessibility)
    while model.busyPermission != nil { await Task.yield() }
    fake.pendingObservation?.resume(returning: .init(.denied, detail: "Stale denial"))
    fake.pendingObservation = nil
    await oldRefresh.value
    #expect(model.rows.first { $0.id == .accessibility }?.state == .ready)
    #expect(model.rows.first { $0.id == .accessibility }?.observation.detail == "Actual input verified")
    #expect(fake.requested == [.accessibility])
    model.cancel()
}

@Test @MainActor func permissionChecklistInvalidationRejectsPendingSetupProof() async {
    let fake = PermissionChecklistFake()
    fake.delaySetup = true
    fake.values[.microphone] = .init(.ready, detail: "Allowed", verificationKey: "same-device", requiresVerification: true)
    let model = DesktopPermissionChecklistCoordinator(adapter: fake)
    model.open()
    await model.refresh()
    model.setup(.microphone)
    while fake.pendingSetup == nil { await Task.yield() }
    model.invalidateVerification(.microphone)
    fake.pendingSetup?.resume(returning: .init(.ready, detail: "Stale proof", verificationKey: "same-device", requiresVerification: true, verified: true))
    fake.pendingSetup = nil
    while model.busyPermission != nil { await Task.yield() }
    #expect(model.rows.first { $0.id == .microphone }?.state == .verificationRequired)
    #expect(!model.canFinish)
    model.cancel()
}

@Test @MainActor func permissionChecklistActivationKeepsPowerProofAndExpiresProtectedResourceProof() async {
    let notifications = NotificationCenter()
    var powerChecks = 0
    var directoryChecks = 0
    let service = DesktopPermissionChecklist(directoryURL: { _ in URL(fileURLWithPath: "/fake-directory") },
        verifyDirectory: { _ in directoryChecks += 1 }, selectedProfile: { .production },
        verifyPowerAvailability: { powerChecks += 1; return true }, activationNotificationCenter: notifications)
    let power = await service.adapter.setup(.awakeDuringRemoteWork)
    #expect(power.state == .ready)
    #expect(await service.adapter.setup(.desktopFiles).state == .ready)
    notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    #expect(await service.adapter.observe(.awakeDuringRemoteWork) == power)
    #expect(await service.adapter.observe(.desktopFiles).state == .verificationRequired)
    #expect(powerChecks == 1 && directoryChecks == 1)
}

@Test @MainActor func permissionChecklistActivationFencesPendingDirectoryProof() async {
    let notifications = NotificationCenter()
    var pending: CheckedContinuation<Void, Never>?
    let service = DesktopPermissionChecklist(directoryURL: { _ in URL(fileURLWithPath: "/fake-directory") },
        verifyDirectory: { _ in await withCheckedContinuation { pending = $0 } }, selectedProfile: { .production },
        activationNotificationCenter: notifications)
    let check = Task { await service.adapter.setup(.documentsFiles) }
    while pending == nil { await Task.yield() }
    notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    pending?.resume()
    #expect(await check.value.state == .checking)
    #expect(await service.adapter.observe(.documentsFiles).state == .verificationRequired)
}

@Test @MainActor func permissionChecklistRetainsActionablePrerequisiteAndWebKitDenialAcrossPassiveGrantReadback() async {
    for state in [DesktopPermissionState.verificationRequired, .denied, .unsupported] {
        let fake = PermissionChecklistFake()
        fake.values[.microphone] = .init(.ready, detail: "OS grant", verificationKey: "same-device-page", requiresVerification: true)
        fake.setupValues[.microphone] = .init(state, detail: "Specific functional recovery")
        let model = DesktopPermissionChecklistCoordinator(adapter: fake)
        model.open()
        await model.refresh()
        model.setup(.microphone)
        while model.busyPermission != nil { await Task.yield() }
        await model.refresh()
        #expect(model.rows.first { $0.id == .microphone }?.state == state)
        #expect(model.rows.first { $0.id == .microphone }?.observation.detail == "Specific functional recovery")
        fake.values[.microphone] = .init(.ready, detail: "New document", verificationKey: "new-device-page", requiresVerification: true)
        await model.refresh()
        #expect(model.rows.first { $0.id == .microphone }?.state == .verificationRequired)
        #expect(model.rows.first { $0.id == .microphone }?.observation.detail == "New document")
        model.cancel()
    }
}
