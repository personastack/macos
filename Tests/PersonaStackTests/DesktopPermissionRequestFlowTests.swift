import AVFoundation
import Foundation
import Testing
import PersonaStackCore
@testable import PersonaStack

@Suite @MainActor
struct DesktopPermissionRequestFlowTests {
    @Test(arguments: [DesktopPermissionID.screenRecording, .directCapture])
    func hostScreenRequestRunsDespiteDeniedPreflightAndReadsApproval(id: DesktopPermissionID) async {
        var granted = false
        var calls: [String] = []
        var access = DesktopPermissionSystemAccess.permissionFixture()
        access.accessibility = { Issue.record("Screen approval must not read Accessibility"); return false }
        access.screenRecording = { granted }
        access.requestScreenRecording = { calls.append("host-screen-request"); granted = true; return true }
        let adapter = DesktopPermissionChecklistSystemAdapter(hooks: .init(setup: { _ in
            Issue.record("Screen approval must not run a Cua operation")
            return nil
        }), access: access, openSettings: { _ in Issue.record("Granted request must not open Settings") })
        let before = await adapter.observe(id)
        #expect(before.state == .notGranted && calls.isEmpty)
        let result = await adapter.setup(id)
        #expect(result.state == .ready && result.verified && !result.requiresVerification)
        #expect(calls == ["host-screen-request"])
    }

    @Test(arguments: [DesktopPermissionID.screenRecording, .directCapture])
    func refusedScreenRequestOpensSettingsWithoutGrantingReady(id: DesktopPermissionID) async {
        var calls: [String] = []
        var access = DesktopPermissionSystemAccess.permissionFixture()
        access.screenRecording = { false }
        access.requestScreenRecording = { calls.append("request"); return false }
        let adapter = DesktopPermissionChecklistSystemAdapter(hooks: .init(setup: { _ in
            Issue.record("Denied screen permission must not start the runtime")
            return nil
        }), access: access, openSettings: { calls.append($0) })
        let result = await adapter.setup(id)
        #expect(result.state == .notGranted && !result.verified)
        #expect(calls == ["request", "com.apple.preference.security?Privacy_ScreenCapture"])
    }

    @Test(arguments: [DesktopPermissionID.screenRecording, .directCapture])
    func existingScreenGrantSkipsRequestsAndOperationHooks(id: DesktopPermissionID) async {
        var access = DesktopPermissionSystemAccess.permissionFixture()
        access.accessibility = { Issue.record("Screen access must not depend on Accessibility"); return false }
        access.screenRecording = { true }
        access.requestScreenRecording = { Issue.record("Existing approval must not prompt again"); return false }
        let owner = DesktopPermissionChecklist(access: access, activationNotificationCenter: NotificationCenter())
        let value = await owner.adapter.setup(id)
        #expect(value.state == .ready && value.verified && !value.requiresVerification)
        #expect(value.detail.contains("No screenshot was taken"))
    }

    @Test func screenGrantRevokedDuringSetupDoesNotClaimAnApprovedRequestNeedsRestart() async {
        var reads = 0
        var settings: [String] = []
        var access = DesktopPermissionSystemAccess.permissionFixture()
        access.screenRecording = { reads += 1; return reads == 1 }
        access.requestScreenRecording = { Issue.record("Initial approval must not be requested again"); return false }
        let adapter = DesktopPermissionChecklistSystemAdapter(hooks: .init(setup: { _ in
            Issue.record("Revoked screen access must not start capture verification")
            return nil
        }), access: access, openSettings: { settings.append($0) })
        let value = await adapter.setup(.screenRecording)
        #expect(value.state == .notGranted && !value.verified)
        #expect(settings == ["com.apple.preference.security?Privacy_ScreenCapture"])
    }

    @Test(arguments: [false, true])
    func accessibilityApprovalNeedsNoRuntimeOrScreenOperation(screenGranted: Bool) async {
        var access = DesktopPermissionSystemAccess.permissionFixture()
        access.accessibility = { true }
        access.requestAccessibility = { Issue.record("Existing approval must not prompt again") }
        access.screenRecording = { screenGranted }
        access.requestScreenRecording = { Issue.record("AX must not request screen access"); return false }
        let owner = DesktopPermissionChecklist(access: access, activationNotificationCenter: NotificationCenter())
        for value in [await owner.adapter.observe(.accessibility),
                      await owner.adapter.setupAutomatically(.accessibility),
                      await owner.adapter.setup(.accessibility)] {
            #expect(value.state == .ready && value.verified && !value.requiresVerification)
            #expect(value.detail.contains("No desktop action was performed"))
        }
    }

    @Test func accessibilitySetupReadsApprovalAfterPromptWithoutCallingOperationHooks() async {
        var granted = false
        var requests = 0
        var access = DesktopPermissionSystemAccess.permissionFixture()
        access.accessibility = { granted }
        access.requestAccessibility = { requests += 1; granted = true }
        let adapter = DesktopPermissionChecklistSystemAdapter(hooks: .init(
            setup: { _ in Issue.record("OS approval must not exercise input"); return nil }
        ), access: access, openSettings: { _ in Issue.record("Approved access must not open Settings") })
        let result = await adapter.setup(.accessibility)
        #expect(result.state == .ready && result.verified && !result.requiresVerification)
        #expect(requests == 1)
    }

    @Test(arguments: [DesktopPermissionID.screenRecording, .directCapture], [false, true])
    func screenGrantIsReadyIndependentlyOfAccessibility(id: DesktopPermissionID, accessibility: Bool) async {
        var access = DesktopPermissionSystemAccess.permissionFixture()
        access.accessibility = { accessibility }
        access.screenRecording = { true }
        access.requestScreenRecording = { Issue.record("Existing screen approval must not prompt"); return false }
        let owner = DesktopPermissionChecklist(access: access, activationNotificationCenter: NotificationCenter())
        let adapter = DesktopPermissionChecklistSystemAdapter(hooks: owner.adapter.hooks, access: access,
            openSettings: { _ in Issue.record("Screen approval must not open another permission's settings") })
        for value in [await adapter.observe(id), await adapter.setup(id), await adapter.setupAutomatically(.screenRecording)] {
            #expect(value.state == .ready && value.verified && !value.requiresVerification)
        }
    }

    @Test func microphoneAuthorizationIsReadBackBeforeFunctionalCheckAndNotReprompted() async {
        var status = AVAuthorizationStatus.notDetermined
        var calls: [String] = []
        var access = DesktopPermissionSystemAccess.permissionFixture()
        access.microphone = { status }
        access.hasMicrophone = { true }
        access.requestMicrophone = { calls.append("request"); status = .authorized; return true }
        let adapter = DesktopPermissionChecklistSystemAdapter(hooks: .init(setup: { id in
            #expect(id == .microphone && status == .authorized)
            calls.append("record")
            return .init(.ready, detail: "Recorded", verified: true)
        }), access: access, openSettings: { _ in Issue.record("Approved microphone must not open Settings") })
        #expect(await adapter.setup(.microphone).verified)
        #expect(await adapter.setup(.microphone).verified)
        #expect(calls == ["request", "record", "record"])
    }
}

@Test @MainActor func successfulScreenRequestWithStalePreflightRequiresRestartAndNeverCallsRuntime() async {
    var access = DesktopPermissionSystemAccess.permissionFixture()
    access.screenRecording = { false }
    access.requestScreenRecording = { true }
    let adapter = DesktopPermissionChecklistSystemAdapter(hooks: .init(setup: { _ in
        Issue.record("Stale host process must not start functional capture")
        return nil
    }), access: access, openSettings: { _ in Issue.record("Already approved request must not reopen Settings") })
    let model = DesktopPermissionChecklistCoordinator(adapter: PermissionOnlyAdapter(base: adapter))
    model.open()
    await model.refresh()
    model.setup(.screenRecording)
    while model.busyPermission != nil { await Task.yield() }
    await model.refresh()
    #expect(model.rows.first { $0.id == .screenRecording }?.state == .restartRequired)
    #expect(model.rows.first { $0.id == .screenRecording }?.observation.detail.contains("Quit and reopen") == true)
    model.cancel()
}

@MainActor
private struct PermissionOnlyAdapter: DesktopPermissionChecklistAdapting {
    let base: DesktopPermissionChecklistSystemAdapter
    func observe(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation {
        if permission == .screenRecording { return await base.observe(permission) }
        return .init(.notNeeded, detail: "Fixture")
    }
    func setup(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation { await base.setup(permission) }
}

@Test @MainActor func screenCaptureReadbackTracksItsOwnGrantAcrossAccessibilityChangesAndReopening() async {
    var accessibility = false
    var screenGranted = true
    var access = DesktopPermissionSystemAccess.permissionFixture()
    access.accessibility = { accessibility }
    access.screenRecording = { screenGranted }
    access.requestScreenRecording = { Issue.record("Passive checks must not request access"); return false }
    let owner = DesktopPermissionChecklist(access: access, activationNotificationCenter: NotificationCenter())
    let model = DesktopPermissionChecklistCoordinator(adapter: PermissionOnlyAdapter(base: owner.adapter))
    defer { model.cancel() }
    model.open()
    await model.refresh()
    #expect(model.rows.first { $0.id == .screenRecording }?.isComplete == true)
    model.setup(.screenRecording)
    while model.busyPermission != nil { await Task.yield() }
    await model.refresh()
    #expect(model.rows.first { $0.id == .screenRecording }?.isComplete == true)
    accessibility = true
    await model.refresh()
    #expect(model.rows.first { $0.id == .screenRecording }?.isComplete == true)
    accessibility = false
    await model.refresh()
    #expect(model.rows.first { $0.id == .screenRecording }?.isComplete == true)
    screenGranted = false
    await model.refresh()
    #expect(model.rows.first { $0.id == .screenRecording }?.state == .notGranted)
    screenGranted = true
    model.cancel()
    model.open()
    await model.refresh()
    #expect(model.rows.first { $0.id == .screenRecording }?.isComplete == true)
}

@Test @MainActor func permissionPromptActivationPreservesBusyDirectoryProofButInvalidatesIdleProof() async {
    var release: CheckedContinuation<Void, Never>?
    let owner = DesktopPermissionChecklist(access: .permissionFixture(), directoryURL: { _ in URL(fileURLWithPath: "/fixture") }, verifyDirectory: { _ in
        await withCheckedContinuation { release = $0 }
    }, selectedProfile: { .production }, volumeSnapshot: { [] })
    let observe = owner.adapter.hooks.observe
    owner.adapter.hooks.observe = { id in
        if id == .desktopFiles || id == .documentsFiles { return await observe(id) }
        return .init(.notNeeded, detail: "Fixture")
    }
    let model = owner.window.coordinator
    model.open()
    await model.refresh()
    model.setup(.desktopFiles)
    while release == nil { await Task.yield() }
    owner.invalidateAfterActivation()
    release?.resume()
    release = nil
    while model.busyPermission != nil { await Task.yield() }
    #expect(model.rows.first { $0.id == .desktopFiles }?.state == .ready)
    #expect(model.rows.first { $0.id == .documentsFiles }?.state == .verificationRequired)
    owner.invalidateAfterActivation()
    await model.refresh()
    #expect(model.rows.first { $0.id == .desktopFiles }?.state == .verificationRequired)
    model.cancel()
}

@Test @MainActor func accessibilityRequestReadsAsynchronousApprovalAndDoesNotAssumePromptSuccess() async {
    var granted = false
    var requested = 0
    var settings = 0
    var access = DesktopPermissionSystemAccess.permissionFixture()
    access.accessibility = { granted }
    access.requestAccessibility = { requested += 1 }
    let adapter = DesktopPermissionChecklistSystemAdapter(hooks: .init(setup: { _ in
        Issue.record("Pending AX approval must not start the desktop runtime or verifier")
        return nil
    }), access: access, openSettings: { section in
        #expect(section == "com.apple.preference.security?Privacy_Accessibility")
        settings += 1
    })
    #expect(await adapter.setup(.accessibility).state == .notGranted)
    #expect(requested == 1 && settings == 1)
    // macOS approves later, independently of the synchronous AX prompt call.
    granted = true
    let observed = await adapter.observe(.accessibility)
    #expect(observed.state == .ready && !observed.requiresVerification && observed.verified)
    #expect(requested == 1 && settings == 1)
}

@Test @MainActor func permissionCancelledScreenRequestCannotPublishReady() async {
    var pending: CheckedContinuation<Void, Never>?
    var granted = false
    var access = DesktopPermissionSystemAccess.permissionFixture()
    access.screenRecording = { granted }
    access.requestScreenRecording = {
        await withCheckedContinuation { pending = $0 }
        granted = true
        return true
    }
    let adapter = DesktopPermissionChecklistSystemAdapter(hooks: .init(setup: { _ in
        Issue.record("Cancelled permission request must not invoke an operation")
        return nil
    }), access: access, openSettings: { _ in Issue.record("Cancelled request must not open Settings") })
    let stale = Task { await adapter.setup(.screenRecording) }
    while pending == nil { await Task.yield() }
    stale.cancel()
    pending?.resume()
    let result = await stale.value
    #expect(result.state == .checking && !result.verified)
}

@MainActor
private struct AccessibilityOnlyAdapter: DesktopPermissionChecklistAdapting {
    let base: DesktopPermissionChecklistSystemAdapter
    func observe(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation {
        permission == .accessibility ? await base.observe(permission) : .init(.notNeeded, detail: "Fixture")
    }
    func setup(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation {
        #expect(permission == .accessibility)
        return await base.setup(permission)
    }
    func setupAutomatically(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation {
        permission == .accessibility ? await base.setupAutomatically(permission) : .init(.notNeeded, detail: "Fixture")
    }
}

@Test @MainActor func accessibilityReadbackTracksApprovalRevocationAndReopeningWithoutActions() async {
    var granted = false
    var requests = 0
    var settings = 0
    var access = DesktopPermissionSystemAccess.permissionFixture()
    access.accessibility = { granted }
    access.requestAccessibility = { requests += 1 }
    let adapter = DesktopPermissionChecklistSystemAdapter(hooks: .init(
        setup: { _ in Issue.record("Accessibility must not run an action hook"); return nil },
        verifyAutomatically: { _ in Issue.record("Accessibility must not run a runtime check"); return nil }
    ), access: access, openSettings: { _ in settings += 1 })
    let model = DesktopPermissionChecklistCoordinator(adapter: AccessibilityOnlyAdapter(base: adapter))
    defer { model.cancel() }
    model.open()
    model.startPresentationVerification()
    while model.verificationBusyPermission != nil { await Task.yield() }
    await model.refresh()
    #expect(!model.canFinish && requests == 0 && settings == 0)
    model.setup(.accessibility)
    while model.busyPermission != nil { await Task.yield() }
    #expect(!model.canFinish && requests == 1 && settings == 1)
    // Approval arrives later from Settings. No second Setup click is necessary.
    granted = true
    await model.refresh()
    #expect(model.canFinish && model.permissionRows.first?.state == .ready)
    #expect(requests == 1 && settings == 1)
    granted = false
    await model.refresh()
    #expect(!model.canFinish && model.permissionRows.first?.state == .notGranted)
    model.cancel()
    granted = true
    model.open()
    model.startPresentationVerification()
    while model.verificationBusyPermission != nil { await Task.yield() }
    await model.refresh()
    #expect(model.canFinish && model.permissionRows.first?.state == .ready)
    #expect(requests == 1 && settings == 1)
}
