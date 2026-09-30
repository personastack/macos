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

    func observe(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation {
        observed.append(permission)
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
    #expect(allowed.state == .checking)
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
    fake.values[.accessibility] = .init(.denied, detail: "Revoked")
    await model.refresh()
    #expect(model.rows.first { $0.id == .accessibility }?.state == .denied)
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
    #expect(allowed.requiresVerification && !allowed.verified)
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
    for row in model.rows where !row.isRequiredForUnlockedSetup {
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

@Test @MainActor func permissionChecklistUnlockedSetupStillRequiresEveryImplementedCapability() async {
    for id in DesktopPermissionID.allCases where id != .lockedScreenControl && id != .fullDiskAccess {
        for state in DesktopPermissionState.allCases where !state.satisfiesSetup {
            let fake = PermissionChecklistFake()
            fake.values[id] = .init(state, detail: "Incomplete")
            let model = DesktopPermissionChecklistCoordinator(adapter: fake)
            model.open()
            await model.refresh()
            #expect(!model.canFinish, "Incomplete \(id) \(state) must block enrollment")
            model.finish()
            #expect(!model.isFinishing)
            model.cancel()
        }
    }
}
