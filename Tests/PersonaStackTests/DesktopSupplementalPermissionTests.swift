import Carbon
import AppKit
import Foundation
import PersonaStackCore
import Testing
@testable import PersonaStack

@Suite @MainActor
struct DesktopSupplementalPermissionTests {
    @Test(arguments: [
        (OSStatus(noErr), DesktopPermissionState.ready),
        (OSStatus(errAEEventNotPermitted), .denied),
        (OSStatus(errAEEventWouldRequireUserConsent), .notGranted),
        (OSStatus(procNotFound), .verificationRequired),
        (OSStatus(paramErr), .verificationRequired),
    ])
    func automationReadsNeverPrompt(status: OSStatus, state: DesktopPermissionState) async {
        var prompts: [Bool] = []
        var access = DesktopPermissionSystemAccess.permissionFixture()
        access.automation = { prompt in prompts.append(prompt); return status }
        access.resetPermission = { _ in Issue.record("Automation must not reset grants"); return .failed }
        let adapter = DesktopPermissionChecklistSystemAdapter(access: access)
        for value in [await adapter.observe(.automation), await adapter.check(.automation), await adapter.setupAutomatically(.automation)] {
            #expect(value.state == state)
            #expect(value.verified == (status == noErr))
        }
        #expect(prompts == [false, false, false])
    }

    @Test(arguments: [false, true])
    func automationSetupRequestsExactGrantAndReadsBack(allowed: Bool) async {
        var prompts: [Bool] = []
        var granted = false
        var settings: [String] = []
        var access = DesktopPermissionSystemAccess.permissionFixture()
        access.automation = { prompt in
            prompts.append(prompt)
            if prompt { granted = allowed }
            return granted ? noErr : OSStatus(errAEEventNotPermitted)
        }
        access.resetPermission = { _ in Issue.record("Setup must preserve other app grants"); return .failed }
        let adapter = DesktopPermissionChecklistSystemAdapter(access: access, openSettings: { settings.append($0) })
        let result = await adapter.setup(.automation)
        #expect(result.state == (allowed ? .ready : .denied))
        #expect(prompts == [true, false])
        #expect(settings == (allowed ? [] : ["com.apple.preference.security?Privacy_Automation"]))
        adapter.openSettings(.automation)
        #expect(settings.last == "com.apple.preference.security?Privacy_Automation")
    }

    @Test func directCaptureRequiresItsOwnExplicitProof() async {
        var captures = 0
        var screenGranted = true
        var succeeds = true
        var settings = 0
        var access = DesktopPermissionSystemAccess.permissionFixture()
        access.screenRecording = { screenGranted }
        access.requestDirectCapture = { captures += 1; return succeeds }
        access.resetPermission = { _ in Issue.record("Direct capture must preserve Screen Recording"); return .failed }
        let adapter = DesktopPermissionChecklistSystemAdapter(access: access, openSettings: { _ in settings += 1 })
        for value in [await adapter.observe(.directCapture), await adapter.check(.directCapture), await adapter.setupAutomatically(.directCapture)] {
            #expect(value.state == .verificationRequired && !value.verified)
        }
        #expect(captures == 0)
        #expect(await adapter.setup(.directCapture).state == .ready)
        #expect(await adapter.check(.directCapture).verified && captures == 1)
        screenGranted = false
        #expect(await adapter.observe(.directCapture).state == .notGranted)
        screenGranted = true
        #expect(await adapter.observe(.directCapture).state == .verificationRequired)
        #expect(await adapter.setup(.directCapture).verified && captures == 2)
        succeeds = false
        #expect(await adapter.setup(.directCapture).state == .failed)
        #expect(await adapter.observe(.directCapture).verified == false && captures == 3)
        #expect(settings == 1)
    }

    @Test func cancelledCaptureCannotStoreProof() async {
        var pending: CheckedContinuation<Bool, Never>?
        var access = DesktopPermissionSystemAccess.permissionFixture()
        access.screenRecording = { true }
        access.requestDirectCapture = { await withCheckedContinuation { pending = $0 } }
        let adapter = DesktopPermissionChecklistSystemAdapter(access: access,
            openSettings: { _ in Issue.record("Cancelled capture must not open Settings") })
        let task = Task { await adapter.setup(.directCapture) }
        while pending == nil { await Task.yield() }
        task.cancel()
        pending?.resume(returning: true)
        #expect(await task.value.verified == false)
        #expect(await adapter.observe(.directCapture).state == .verificationRequired)
    }

    @Test func safariSetupShowsInstructionsAndCheckRequiresCurrentProcessAndGrant() async {
        var pid: Int32? = 12
        var grant: OSStatus = noErr
        var succeeds = true
        var scripts = 0
        var opens = 0
        var access = DesktopPermissionSystemAccess.permissionFixture()
        access.automation = { prompt in #expect(!prompt); return grant }
        access.safariProcessIdentifier = { pid }
        access.safariProcessIdentity = { pid.map { "safari-javascript:\($0):fixture" } }
        access.openSafari = { opens += 1 }
        access.verifySafariJavaScript = { scripts += 1; return succeeds }
        let adapter = DesktopPermissionChecklistSystemAdapter(access: access)
        #expect(await adapter.observe(.safariJavaScript).state == .verificationRequired)
        #expect(await adapter.setupAutomatically(.safariJavaScript).state == .verificationRequired)
        #expect(scripts == 0 && opens == 0)
        let setup = await adapter.setup(.safariJavaScript)
        #expect(setup.verified)
        #expect(opens == 0 && scripts == 1)
        #expect(await adapter.check(.safariJavaScript).verified && scripts == 2)
        #expect(await adapter.observe(.safariJavaScript).verified && scripts == 2)
        pid = 13
        #expect(await adapter.observe(.safariJavaScript).verified == false)
        #expect(await adapter.check(.safariJavaScript).verified && scripts == 3)
        grant = OSStatus(errAEEventNotPermitted)
        #expect(await adapter.check(.safariJavaScript).verified == false && scripts == 3)
        grant = noErr
        #expect(await adapter.observe(.safariJavaScript).verified == false)
        #expect(await adapter.check(.safariJavaScript).verified && scripts == 4)
        succeeds = false
        #expect(await adapter.check(.safariJavaScript).verified == false && scripts == 5)
        pid = nil
        #expect(await adapter.check(.safariJavaScript).verified == false && scripts == 5)
    }

    @Test(arguments: [false, true])
    func lateSafariReplyCannotQualifyChangedOrCancelledCheck(cancel: Bool) async {
        var pending: CheckedContinuation<Bool, Never>?
        var pid: Int32? = 12
        var access = DesktopPermissionSystemAccess.permissionFixture()
        access.automation = { prompt in #expect(!prompt); return noErr }
        access.safariProcessIdentifier = { pid }
        access.safariProcessIdentity = { pid.map { "safari-javascript:\($0):fixture" } }
        access.verifySafariJavaScript = { await withCheckedContinuation { pending = $0 } }
        let adapter = DesktopPermissionChecklistSystemAdapter(access: access)
        let task = Task { await adapter.check(.safariJavaScript) }
        while pending == nil { await Task.yield() }
        if cancel { task.cancel() } else { pid = 13 }
        pending?.resume(returning: true)
        #expect(await task.value.verified == false)
        #expect(await adapter.observe(.safariJavaScript).verified == false)
    }

    @Test func supplementalRowsBlockIncompleteUnattendedEnrollment() async {
        var access = DesktopPermissionSystemAccess.permissionFixture()
        access.accessibility = { true }
        access.screenRecording = { true }
        let adapter = DesktopPermissionChecklistSystemAdapter(hooks: .init(observe: { id in
            if [.accessibility, .directCapture, .automation, .safariJavaScript, .clipboard].contains(id) { return nil }
            return .init(.notNeeded, detail: "Unrelated fixture capability")
        }), access: access)
        let coordinator = DesktopPermissionChecklistCoordinator(adapter: adapter)
        coordinator.open()
        defer { coordinator.cancel() }
        await coordinator.refresh()
        for id in [DesktopPermissionID.directCapture, .automation, .safariJavaScript, .clipboard] {
            let row = coordinator.permissionRows.first { $0.id == id }
            #expect(row != nil && row?.isComplete == false)
            #expect(row?.isRequiredForUnlockedSetup == true)
            #expect(DesktopPermissionReset.arguments(for: id) == nil)
        }
        #expect(!coordinator.canFinish)
    }

    @Test(arguments: [
        (DesktopClipboardAccess.notNeeded, DesktopPermissionState.notNeeded),
        (.notDetermined, .verificationRequired), (.ask, .verificationRequired),
        (.allowed, .ready), (.denied, .denied), (.unknown, .verificationRequired),
    ])
    func clipboardPolicyChecksNeverReadContent(status: DesktopClipboardAccess, expected: DesktopPermissionState) async {
        var access = DesktopPermissionSystemAccess.permissionFixture()
        access.clipboardAccess = { status }
        let adapter = DesktopPermissionChecklistSystemAdapter(access: access)
        for value in [await adapter.observe(.clipboard), await adapter.check(.clipboard), await adapter.setupAutomatically(.clipboard)] {
            #expect(value.state == expected)
        }
    }

    @Test(arguments: [DesktopClipboardAccess.notDetermined, .ask, .allowed, .denied, .notNeeded])
    func clipboardSetupPreservesPolicyAndReadsBackItsRequest(status: DesktopClipboardAccess) async {
        var current = status
        var requests = 0
        var settings = 0
        var access = DesktopPermissionSystemAccess.permissionFixture()
        access.clipboardAccess = { current }
        access.requestClipboardAccess = { requests += 1; current = .allowed }
        let adapter = DesktopPermissionChecklistSystemAdapter(access: access, openSettings: { value in
            #expect(value == "com.apple.preference.security?Privacy_Pasteboard")
            settings += 1
        })
        let value = await adapter.setup(.clipboard)
        let requestExpected = [DesktopClipboardAccess.notDetermined, .ask].contains(status)
        #expect(requests == (requestExpected ? 1 : 0))
        #expect(value.state == (status == .denied ? .denied : status == .notNeeded ? .notNeeded : .ready))
        #expect(settings == (status == .denied ? 1 : 0))
    }

    @Test func clipboardOneTimeApprovalDoesNotClaimUnattendedAccessAndRevocationRemovesReady() async {
        var status = DesktopClipboardAccess.ask
        var access = DesktopPermissionSystemAccess.permissionFixture()
        access.clipboardAccess = { status }
        access.requestClipboardAccess = { }
        let adapter = DesktopPermissionChecklistSystemAdapter(access: access)
        #expect(await adapter.setup(.clipboard).state == .verificationRequired)
        status = .allowed
        #expect(await adapter.check(.clipboard).verified)
        status = .denied
        #expect(await adapter.observe(.clipboard).state == .denied)
    }

    /// Opt-in diagnostic artifacts only. Hidden AppKit omits content and these
    /// bitmaps do not qualify visual acceptance. No permission is requested.
    @Test func supplementalPermissionNativePreview() async throws {
        guard let directory = ProcessInfo.processInfo.environment["CUA_PERMISSION_PREVIEW_DIRECTORY"] else { return }
        _ = NSApplication.shared
        var access = DesktopPermissionSystemAccess.permissionFixture()
        access.screenRecording = { true }
        access.requestDirectCapture = { false }
        let adapter = DesktopPermissionChecklistSystemAdapter(hooks: .init(observe: { id in
            if id == .directCapture { return nil }
            return .init(.ready, detail: "Fixture verified", verified: true)
        }), access: access, evidence: nil)
        let coordinator = DesktopPermissionChecklistCoordinator(adapter: adapter)
        let verifier = DesktopLockedControlSetupVerifier(operations: .init(inspect: { .ready }))
        _ = await verifier.refresh()
        let owner = DesktopPermissionChecklistWindow(coordinator: coordinator,
            browserConsent: .init(inventory: { [] }), lockedControlVerifier: verifier)
        let window = owner.makeWindowIfNeeded()
        defer { coordinator.cancel(); window.close() }
        coordinator.open()
        await coordinator.refresh()
        let view = try #require(window.contentView)
        for state in ["intro", "capture-recovery"] {
            if state == "capture-recovery" {
                coordinator.continueSetup()
                while coordinator.busyPermission != nil { await Task.yield() }
            }
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                for size in [NSSize(width: 670, height: 740), NSSize(width: 560, height: 460)] {
                    window.setContentSize(size)
                    view.layoutSubtreeIfNeeded()
                    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let data = try #require(bitmap.representation(using: .png, properties: [:]))
                    let name = "permissions-\(state)-\(appearance.rawValue)-\(Int(size.width))x\(Int(size.height)).png"
                    try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
                    #expect(view.bounds.size == size && !window.isVisible)
                }
            }
        }
    }
}

@Test func packagedHostDeclaresAppleEventsPurposeAndEntitlement() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let info = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("Resources/Info.plist")), format: nil) as? [String: Any])
    let entitlements = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("Resources/Release.entitlements")), format: nil) as? [String: Any])
    #expect((info["NSAppleEventsUsageDescription"] as? String)?.contains("Safari") == true)
    #expect(entitlements["com.apple.security.automation.apple-events"] as? Bool == true)
}
