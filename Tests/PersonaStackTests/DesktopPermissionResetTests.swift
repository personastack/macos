import Foundation
import Testing
import PersonaStackCore
@testable import PersonaStack

extension DesktopPermissionSystemAccess {
    /// Existing request/readback fixtures exercise the OS request path without
    /// changing the test runner's or installed application's real TCC grants.
    @MainActor static func permissionFixture() -> Self {
        var access = Self()
        access.resetPermission = { _ in .notApplicable }
        access.openPrivacySettings = { _ in }
        access.revealApplication = { }
        access.requestNotifications = { }
        access.verifyNotificationDelivery = { true }
        access.unregisterLoginForSetup = { }
        access.unregisterLegacyLoginForSetup = { }
        access.loginSignatureIsValid = { true }
        return access
    }
}

@Suite @MainActor
struct DesktopPermissionResetTests {
    @Test(arguments: [DesktopPermissionResetResult.cleared, .failed])
    func fullDiskSetupRevealsAppAndReopensSettingsWithoutResettingAgain(result: DesktopPermissionResetResult) async {
        var calls: [String] = []
        var access = DesktopPermissionSystemAccess.permissionFixture()
        access.resetPermission = { id in
            #expect(id == .fullDiskAccess)
            calls.append("reset")
            return result
        }
        access.revealApplication = { calls.append("reveal") }
        let adapter = DesktopPermissionChecklistSystemAdapter(access: access,
            openSettings: { section in
                #expect(section == "com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")
                calls.append("settings")
            })
        let first = await adapter.setup(.fullDiskAccess)
        #expect(first.state == (result == .cleared ? .restartRequired : .failed))
        #expect(first.detail.contains("Click + in Full Disk Access"))
        #expect(first.detail.contains("/Applications/PersonaStack.app"))
        #expect(first.detail.contains("does not add the app"))
        #expect(calls == ["reset", "reveal", "settings"])
        #expect(await adapter.check(.fullDiskAccess) == first)
        #expect(await adapter.observe(.fullDiskAccess) == first)
        #expect(await adapter.setupAutomatically(.fullDiskAccess) == first)
        #expect(calls == ["reset", "reveal", "settings"])
        #expect(await adapter.setup(.fullDiskAccess) == first)
        #expect(calls == ["reset", "reveal", "settings", "reveal", "settings"])
    }

    @Test func unpackagedTestRunnerCannotResetInstalledAppPermissions() async {
        #expect(Bundle.main.bundleURL.pathExtension != "app")
        #expect(await DesktopPermissionReset.reset(.accessibility) == .failed)
    }

    @Test(arguments: [DesktopPermissionID.accessibility, .screenRecording, .microphone, .fullDiskAccess])
    func explicitSetupClearsOnlyItsPermissionThenRequiresFreshProcess(permission: DesktopPermissionID) async {
        var calls: [String] = []
        var access = DesktopPermissionSystemAccess.permissionFixture()
        access.resetPermission = { id in
            #expect(id == permission)
            calls.append("reset")
            return .cleared
        }
        access.requestAccessibility = { calls.append("request") }
        access.requestScreenRecording = { calls.append("request"); return true }
        access.requestMicrophone = { calls.append("request"); return true }
        access.accessibility = { Issue.record("A reset grant must not be read from the old process"); return true }
        access.screenRecording = { Issue.record("A reset grant must not be read from the old process"); return true }
        access.microphone = { Issue.record("A reset grant must not be read from the old process"); return .authorized }
        let adapter = DesktopPermissionChecklistSystemAdapter(hooks: .init(
            observe: { _ in Issue.record("Reset access must not reuse operation proof"); return nil },
            setup: { _ in Issue.record("Reset access must not start an operation"); return nil },
            verifyAutomatically: { _ in Issue.record("Reset access must not verify cached grants"); return nil }
        ), access: access, openSettings: { calls.append($0) })
        let result = await adapter.setup(permission)
        #expect(result.state == .restartRequired && !result.verified)
        #expect(result.detail.contains("Cleared PersonaStack's previous"))
        #expect(calls.first == "reset")
        #expect(calls.filter { $0 == "request" }.count == (permission == .fullDiskAccess ? 0 : 1))
        #expect(calls.last?.contains("Privacy_") == true)
        let count = calls.count
        #expect(await adapter.observe(permission).state == .restartRequired)
        #expect(await adapter.check(permission).state == .restartRequired)
        #expect(await adapter.setupAutomatically(permission).state == .restartRequired)
        #expect(await adapter.setup(permission).state == .restartRequired)
        #expect(calls.count == count + (permission == .fullDiskAccess ? 1 : 0))
        if permission == .screenRecording {
            #expect(await adapter.observe(.directCapture).state == .restartRequired)
        }
    }

    @Test func passiveReadsAndPresentationNeverResetPermissions() async {
        var access = DesktopPermissionSystemAccess.permissionFixture()
        access.resetPermission = { _ in Issue.record("Passive reads must not reset permission"); return .failed }
        access.accessibility = { false }
        access.screenRecording = { false }
        access.microphone = { .denied }
        let adapter = DesktopPermissionChecklistSystemAdapter(hooks: .init(
            observe: { id in id == .fullDiskAccess || id == .localNetwork ? .init(.verificationRequired, detail: "Fixture") : nil },
            verifyAutomatically: { _ in .init(.failed, detail: "Fixture") }
        ), access: access)
        for permission in DesktopPermissionID.setupPermissions {
            _ = await adapter.observe(permission)
            _ = await adapter.setupAutomatically(permission)
        }
    }

    @Test func failedResetNeverRequestsAccessOrRunsItsOperation() async {
        var access = DesktopPermissionSystemAccess.permissionFixture()
        access.resetPermission = { _ in .failed }
        access.requestAccessibility = { Issue.record("Failed reset must not request access") }
        var settings = 0
        let adapter = DesktopPermissionChecklistSystemAdapter(hooks: .init(setup: { _ in
            Issue.record("Failed reset must not run an operation"); return nil
        }), access: access, openSettings: { _ in settings += 1 })
        let result = await adapter.setup(.accessibility)
        #expect(result.state == .failed && !result.detail.contains("Cleared"))
        #expect(settings == 1)
        #expect(await adapter.observe(.accessibility).state == .failed)
    }

    @Test func canceledSuccessfulResetStillInvalidatesCachedGrant() async {
        var pending: CheckedContinuation<DesktopPermissionResetResult, Never>?
        var access = DesktopPermissionSystemAccess.permissionFixture()
        access.resetPermission = { _ in await withCheckedContinuation { pending = $0 } }
        access.requestAccessibility = { Issue.record("Canceled reset must not request access") }
        access.accessibility = { Issue.record("Canceled successful reset cannot reuse cached trust"); return true }
        let adapter = DesktopPermissionChecklistSystemAdapter(access: access,
            openSettings: { _ in Issue.record("Canceled reset must not open Settings") })
        let task = Task { await adapter.setup(.accessibility) }
        while pending == nil { await Task.yield() }
        task.cancel()
        pending?.resume(returning: .cleared)
        #expect(await task.value.state == .checking)
        #expect(await adapter.observe(.accessibility).state == .restartRequired)
    }

    @Test func localNetworkDoesNotInvokeTCCReset() async {
        var access = DesktopPermissionSystemAccess.permissionFixture()
        access.resetPermission = { _ in Issue.record("Local Network is not a TCC reset service"); return .failed }
        let adapter = DesktopPermissionChecklistSystemAdapter(hooks: .init(setup: { id in
            #expect(id == .localNetwork)
            return .init(.failed, detail: "Endpoint failed")
        }), access: access, openSettings: { _ in Issue.record("Setup must attempt network without opening Settings") })
        #expect(await adapter.setup(.localNetwork).state == .failed)
    }

    @Test(arguments: [
        (DesktopPermissionID.accessibility, "Accessibility"), (.screenRecording, "ScreenCapture"),
        (.directCapture, "ScreenCapture"), (.microphone, "Microphone"), (.fullDiskAccess, "SystemPolicyAllFiles"),
        (.desktopFiles, "SystemPolicyDesktopFolder"), (.documentsFiles, "SystemPolicyDocumentsFolder"),
        (.downloadsFiles, "SystemPolicyDownloadsFolder"), (.removableVolumes, "SystemPolicyRemovableVolumes"),
        (.networkVolumes, "SystemPolicyNetworkVolumes")
    ])
    func commandIsFixedToOneBundleAndOneService(permission: DesktopPermissionID, service: String) async {
        let result = await DesktopPermissionReset.reset(permission) { executable, arguments in
            #expect(executable.path == "/usr/bin/tccutil")
            #expect(arguments == ["reset", service, "ai.personastack.desktop"])
            return true
        }
        #expect(result == .cleared)
    }

    @Test(arguments: [DesktopPermissionID.localNetwork, .notifications, .launchAtLogin, .lockedScreenControl])
    func unsupportedResourcesCannotInvokeReset(permission: DesktopPermissionID) async {
        #expect(DesktopPermissionReset.arguments(for: permission) == nil)
        let result = await DesktopPermissionReset.reset(permission) { _, _ in
            Issue.record("Unsupported resource must not invoke a process")
            return true
        }
        #expect(result == .notApplicable)
    }

    @Test(arguments: [
        (URLError.cannotFindHost, "DNS"), (.serverCertificateUntrusted, "certificate"),
        (.timedOut, "in time"), (.notConnectedToInternet, "does not establish"),
        (.cannotConnectToHost, "could not be established")
    ])
    func localNetworkFailureNamesTheEndpointAndCause(code: URLError.Code, reason: String) async throws {
        let service = DesktopPermissionChecklist(access: .permissionFixture(), selectedProfile: { .lan },
            activationNotificationCenter: NotificationCenter(), requestEndpoint: { _ in throw URLError(code) })
        let result = try #require(await service.adapter.hooks.setup(.localNetwork))
        #expect(result.state == .failed && !result.verified)
        #expect(result.detail.contains(DesktopEnvironmentConfiguration.lan.appURL.host!))
        #expect(result.detail.contains(reason))
        #expect(result.detail.contains("macOS does not expose the Local Network grant"))
    }
}
