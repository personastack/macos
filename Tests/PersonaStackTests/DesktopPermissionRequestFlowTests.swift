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
    var captureFailure = false
    func cuaPermissionSnapshot() async throws -> CuaDriverPermissionSnapshot {
        .init(accessibility: accessibility, screenRecording: screenRecording,
              hostAttributionValid: hostAttributionValid, verificationKey: "owned-generation")
    }
    func prepareCuaPermissions() async throws { calls.append("prepare") }
    func restartCuaAfterPermissionChange() async throws { calls.append("restart") }
    func verifyCuaCapabilitiesForPermissions() async throws {
        calls.append("capture")
        if captureFailure { throw CuaMCPProxyError.functionalProbeFailed }
    }
    func verifyCuaInputForPermissions(target: any DesktopInputPermissionTarget) async throws { calls.append("input") }
}

@MainActor
private final class PermissionRequestTarget: DesktopInputPermissionTarget {
    let pid: Int32 = 10
    let windowID = 20
    let clickCount = 0
    let text = ""
    let expectedText = "fixture"
    func present() throws { Issue.record("The fake runtime must own the test target") }
    func requireCurrent() throws {}
    func invalidate() {}
}

@Suite @MainActor
struct DesktopPermissionRequestFlowTests {
    @Test(arguments: [DesktopPermissionID.screenRecording, .directCapture])
    func hostScreenRequestRunsDespiteDeniedPreflightBeforeRuntimeVerification(id: DesktopPermissionID) async {
        var granted = false
        var calls: [String] = []
        var access = DesktopPermissionSystemAccess()
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
        let adapter = DesktopPermissionChecklistSystemAdapter(access: access, openSettings: { calls.append($0) })
        let result = await adapter.setup(id)
        #expect(result.state == .notGranted && !result.verified)
        #expect(calls == ["request", "com.apple.preference.security?Privacy_ScreenCapture"])
    }

    @Test func accessibilityFunctionalCheckDoesNotRequireOrCaptureScreen() async {
        let runtime = PermissionRequestRuntime()
        var access = DesktopPermissionSystemAccess()
        access.accessibility = { true }
        access.requestAccessibility = {}
        access.screenRecording = { false }
        access.requestScreenRecording = { Issue.record("AX must not request screen access"); return false }
        let owner = DesktopPermissionChecklist(access: access, cuaRuntime: runtime, inputTarget: { PermissionRequestTarget() })
        let value = await owner.adapter.setup(.accessibility)
        #expect(value.state == .ready && value.verified)
        #expect(runtime.calls == ["prepare", "input"])
        #expect(value.detail.contains("clicking and text input"))
    }

    @Test func grantedScreenWithoutAccessibilityNamesTheMissingPrerequisite() async {
        let runtime = PermissionRequestRuntime()
        runtime.accessibility = false
        runtime.screenRecording = true
        var access = DesktopPermissionSystemAccess()
        access.accessibility = { false }
        access.screenRecording = { true }
        access.requestScreenRecording = { true }
        let owner = DesktopPermissionChecklist(access: access, cuaRuntime: runtime)
        let value = await owner.adapter.setup(.directCapture)
        #expect(value.state == .verificationRequired && !value.verified)
        #expect(value.detail.contains("Set up Accessibility"))
        #expect(runtime.calls == ["prepare"])
    }

    @Test func failedPixelsNeverBecomeReadyAfterTheHostGrant() async {
        let runtime = PermissionRequestRuntime()
        runtime.screenRecording = true
        runtime.captureFailure = true
        var access = DesktopPermissionSystemAccess()
        access.accessibility = { true }
        access.screenRecording = { true }
        access.requestScreenRecording = { true }
        let owner = DesktopPermissionChecklist(access: access, cuaRuntime: runtime)
        let value = await owner.adapter.setup(.screenRecording)
        #expect(value.state == .failed && !value.verified)
        #expect(runtime.calls == ["prepare", "capture"])
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
    let adapter = DesktopPermissionChecklistSystemAdapter(access: access, openSettings: { section in
        #expect(section == "com.apple.preference.security?Privacy_Accessibility")
        settings += 1
    })
    #expect(await adapter.setup(.accessibility).state == .notGranted)
    #expect(requested == 1 && settings == 1)
    // macOS approves later, independently of the synchronous AX prompt call.
    granted = true
    let observed = await adapter.observe(.accessibility)
    #expect(observed.state == .ready && observed.requiresVerification && !observed.verified)
    #expect(requested == 1 && settings == 1)
}
