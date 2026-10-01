import AVFoundation
import Foundation
import Testing
import PersonaStackCore
@testable import PersonaStack

@MainActor
private final class PermissionRequestRuntime: DesktopPermissionCuaRuntime {
    var accessibility = true
    var screenRecording = false
    var hostAttributionValid = true
    var calls: [String] = []
    var snapshotReads = 0
    var snapshotFailure = false
    var captureFailure = false
    var suspendSnapshot = false
    var pendingSnapshot: CheckedContinuation<Void, Never>?
    func cuaPermissionSnapshot() async throws -> CuaDriverPermissionSnapshot {
        snapshotReads += 1
        if snapshotFailure { throw CuaMCPProxyError.notStarted }
        if suspendSnapshot {
            suspendSnapshot = false
            await withCheckedContinuation { pendingSnapshot = $0 }
        }
        return .init(accessibility: accessibility, screenRecording: screenRecording,
              hostAttributionValid: hostAttributionValid, verificationKey: "owned-generation")
    }
    func prepareCuaPermissions() async throws { calls.append("prepare") }
    func restartCuaAfterPermissionChange() async throws { calls.append("restart") }
    func verifyCuaCapabilitiesForPermissions() async throws {
        calls.append("capture")
        if captureFailure { throw CuaMCPProxyError.functionalProbeFailed }
    }
}

@Suite @MainActor
struct DesktopPermissionRequestFlowTests {
    @Test(arguments: [DesktopPermissionID.screenRecording, .directCapture])
    func hostScreenRequestRunsDespiteDeniedPreflightBeforeRuntimeVerification(id: DesktopPermissionID) async {
        var granted = false
        var calls: [String] = []
        var access = DesktopPermissionSystemAccess()
        access.accessibility = { true }
        access.screenRecording = { granted }
        access.requestScreenRecording = { calls.append("host-screen-request"); granted = true; return true }
        let adapter = DesktopPermissionChecklistSystemAdapter(hooks: .init(setup: { requested in
            #expect(requested == id && granted)
            calls.append("functional-check")
            return .init(.ready, detail: "Pixels verified", verificationKey: "generation", requiresVerification: true, verified: true)
        }), access: access, openSettings: { _ in Issue.record("Granted request must not open Settings") })
        let before = await adapter.observe(id)
        #expect(before.state == .notGranted && calls.isEmpty)
        let result = await adapter.setup(id)
        #expect(result.verified)
        #expect(calls == ["host-screen-request", "functional-check"])
    }

    @Test(arguments: [DesktopPermissionID.screenRecording, .directCapture])
    func refusedScreenRequestOpensSettingsWithoutGrantingReady(id: DesktopPermissionID) async {
        var calls: [String] = []
        var access = DesktopPermissionSystemAccess()
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

    @Test(arguments: [false, true])
    func accessibilityApprovalNeedsNoRuntimeOrScreenOperation(screenGranted: Bool) async {
        let runtime = PermissionRequestRuntime()
        runtime.accessibility = false
        runtime.hostAttributionValid = false
        // No runtime exists. OS approval must still be sufficient for this row.
        runtime.snapshotFailure = true
        var access = DesktopPermissionSystemAccess()
        access.accessibility = { true }
        access.requestAccessibility = { Issue.record("Existing approval must not prompt again") }
        access.screenRecording = { screenGranted }
        access.requestScreenRecording = { Issue.record("AX must not request screen access"); return false }
        let owner = DesktopPermissionChecklist(access: access, cuaRuntime: runtime)
        for value in [await owner.adapter.observe(.accessibility),
                      await owner.adapter.setupAutomatically(.accessibility),
                      await owner.adapter.setup(.accessibility)] {
            #expect(value.state == .ready && value.verified && !value.requiresVerification)
            #expect(value.detail.contains("No desktop action was performed"))
        }
        #expect(runtime.calls.isEmpty && runtime.snapshotReads == 0)
    }

    @Test func accessibilitySetupReadsApprovalAfterPromptWithoutCallingOperationHooks() async {
        var granted = false
        var requests = 0
        var access = DesktopPermissionSystemAccess()
        access.accessibility = { granted }
        access.requestAccessibility = { requests += 1; granted = true }
        let adapter = DesktopPermissionChecklistSystemAdapter(hooks: .init(
            setup: { _ in Issue.record("OS approval must not exercise input"); return nil }
        ), access: access, openSettings: { _ in Issue.record("Approved access must not open Settings") })
        let result = await adapter.setup(.accessibility)
        #expect(result.state == .ready && result.verified && !result.requiresVerification)
        #expect(requests == 1)
    }

    @Test(arguments: [DesktopPermissionID.screenRecording, .directCapture])
    func grantedScreenWithoutAccessibilityOpensTheMissingPermissionWithoutStartingRuntime(id: DesktopPermissionID) async {
        let runtime = PermissionRequestRuntime()
        runtime.accessibility = false
        runtime.screenRecording = true
        var access = DesktopPermissionSystemAccess()
        access.accessibility = { false }
        access.screenRecording = { true }
        access.requestScreenRecording = { true }
        let owner = DesktopPermissionChecklist(access: access, cuaRuntime: runtime)
        var settings: [String] = []
        let adapter = DesktopPermissionChecklistSystemAdapter(hooks: owner.adapter.hooks, access: access,
                                                              openSettings: { settings.append($0) })
        let value = await adapter.setup(id)
        #expect(value.state == .verificationRequired && !value.verified)
        #expect(value.detail.contains("Set up Accessibility"))
        #expect(value.detail.contains("Screen Capture is allowed"))
        #expect(settings == ["com.apple.preference.security?Privacy_Accessibility"])
        #expect(runtime.calls.isEmpty && runtime.snapshotReads == 0)
        settings.removeAll()
        let automatic = await adapter.setupAutomatically(.screenRecording)
        #expect(automatic == value)
        #expect(await adapter.observe(id) == value)
        #expect(settings.isEmpty && runtime.calls.isEmpty && runtime.snapshotReads == 0)
    }

    @Test(arguments: [false, true])
    func failedPixelsNeverBecomeReadyAfterTheHostGrant(screenRequestSucceeded: Bool) async {
        let runtime = PermissionRequestRuntime()
        runtime.screenRecording = true
        runtime.captureFailure = true
        var access = DesktopPermissionSystemAccess()
        access.accessibility = { true }
        access.screenRecording = { true }
        access.requestScreenRecording = { screenRequestSucceeded }
        let owner = DesktopPermissionChecklist(access: access, cuaRuntime: runtime)
        var settings: [String] = []
        let adapter = DesktopPermissionChecklistSystemAdapter(hooks: owner.adapter.hooks, access: access,
                                                              openSettings: { settings.append($0) })
        let value = await adapter.setup(.screenRecording)
        #expect(value.state == .failed && !value.verified)
        #expect(runtime.calls == ["prepare", "capture"])
        #expect(settings == (screenRequestSucceeded ? [] : ["com.apple.preference.security?Privacy_ScreenCapture"]))
    }

    @Test func microphoneAuthorizationIsReadBackBeforeFunctionalCheckAndNotReprompted() async {
        var status = AVAuthorizationStatus.notDetermined
        var calls: [String] = []
        var access = DesktopPermissionSystemAccess()
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
    var access = DesktopPermissionSystemAccess()
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

@Test @MainActor func screenCaptureSetupRecoversAfterAccessibilityApprovalAndInvalidatesAfterRevocation() async {
    var accessibility = false
    var settings: [String] = []
    var screenRequests = 0
    let runtime = PermissionRequestRuntime()
    runtime.screenRecording = true
    var access = DesktopPermissionSystemAccess()
    access.accessibility = { accessibility }
    access.screenRecording = { true }
    access.requestScreenRecording = { screenRequests += 1; return true }
    access.requestAccessibility = { Issue.record("Screen setup must not request a second permission") }
    let owner = DesktopPermissionChecklist(access: access, cuaRuntime: runtime)
    let adapter = DesktopPermissionChecklistSystemAdapter(hooks: owner.adapter.hooks, access: access,
                                                          openSettings: { settings.append($0) })
    let model = DesktopPermissionChecklistCoordinator(adapter: PermissionOnlyAdapter(base: adapter))
    model.open()
    defer { model.cancel() }
    await model.refresh()
    model.setup(.screenRecording)
    while model.busyPermission != nil { await Task.yield() }
    await model.refresh()
    #expect(model.rows.first { $0.id == .screenRecording }?.observation.detail.contains("Set up Accessibility") == true)
    #expect(settings == ["com.apple.preference.security?Privacy_Accessibility"])
    #expect(runtime.calls.isEmpty && runtime.snapshotReads == 0)

    accessibility = true
    await model.refresh()
    #expect(model.rows.first { $0.id == .screenRecording }?.observation.detail.contains("Set up Accessibility") == false)
    #expect(model.rows.first { $0.id == .screenRecording }?.isComplete == false)
    model.setup(.screenRecording)
    while model.busyPermission != nil { await Task.yield() }
    await model.refresh()
    #expect(model.rows.first { $0.id == .screenRecording }?.isComplete == true)
    #expect(runtime.calls == ["prepare", "capture"] && screenRequests == 2)
    #expect(settings.count == 1)

    accessibility = false
    await model.refresh()
    #expect(model.rows.first { $0.id == .screenRecording }?.isComplete == false)
    #expect(model.rows.first { $0.id == .screenRecording }?.observation.detail.contains("Set up Accessibility") == true)
    #expect(settings.count == 1 && screenRequests == 2)
}

@Test @MainActor func permissionPromptActivationPreservesBusyDirectoryProofButInvalidatesIdleProof() async {
    var release: CheckedContinuation<Void, Never>?
    let owner = DesktopPermissionChecklist(directoryURL: { _ in URL(fileURLWithPath: "/fixture") }, verifyDirectory: { _ in
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
    var access = DesktopPermissionSystemAccess()
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

@Test @MainActor func permissionCancelledOptionalCaptureCannotPrepareOrRestartSuccessorRuntime() async {
    let runtime = PermissionRequestRuntime()
    runtime.suspendSnapshot = true
    var access = DesktopPermissionSystemAccess()
    access.accessibility = { true }
    access.screenRecording = { true }
    access.requestScreenRecording = { true }
    let owner = DesktopPermissionChecklist(access: access, cuaRuntime: runtime)
    let stale = Task { await owner.adapter.setup(.screenRecording) }
    while runtime.pendingSnapshot == nil { await Task.yield() }
    stale.cancel()
    runtime.pendingSnapshot?.resume()
    runtime.pendingSnapshot = nil
    let result = await stale.value
    #expect(result.state == .checking && !result.verified)
    #expect(runtime.calls.isEmpty)
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
    var access = DesktopPermissionSystemAccess()
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
