import Foundation
import Testing
import PersonaStackCore
@testable import PersonaStack

extension DesktopPermissionSystemAccess {
    /// Existing request/readback fixtures exercise the OS request path without
    /// changing the test runner's or installed application's real TCC grants.
    @MainActor static func permissionFixture() -> Self {
        var access = Self()
        access.resetPermission = { _ in Issue.record("Unexpected TCC reset"); return .failed }
        access.accessibility = { false }
        access.screenRecording = { false }
        access.microphone = { .notDetermined }
        access.requestAccessibility = { Issue.record("Unexpected Accessibility prompt") }
        access.requestScreenRecording = { Issue.record("Unexpected Screen Recording prompt"); return false }
        access.requestMicrophone = { Issue.record("Unexpected microphone prompt"); return false }
        access.loginStatus = { .enabled }
        access.registerLogin = { Issue.record("Unexpected login registration") }
        access.legacyLoginStatus = { .notRegistered }
        access.unregisterLegacyLogin = { Issue.record("Unexpected legacy registration change") }
        access.unregisterCrashRecoveryAgent = { Issue.record("Unexpected agent registration change") }
        access.registerLegacyLogin = { Issue.record("Unexpected legacy registration") }
        access.openLoginSettings = { }
        access.notificationSettings = { (.denied, .disabled, .disabled) }
        access.openPrivacySettings = { _ in }
        access.revealApplication = { }
        access.requestNotifications = { }
        access.verifyNotificationDelivery = { true }
        access.unregisterLoginForSetup = { }
        access.unregisterLegacyLoginForSetup = { }
        access.loginSignatureIsValid = { true }
        access.automation = { _ in -1744 }
        access.safariProcessIdentifier = { nil }
        access.safariProcessIdentity = { nil }
        access.verifySafariJavaScript = { Issue.record("Unexpected Safari script"); return false }
        access.selectedBrowserObservation = { .init(.notNeeded, detail: "No selected browsers") }
        access.selectedBrowserSetup = { .init(.notNeeded, detail: "No selected browsers") }
        access.selectedBrowserCheck = { .init(.notNeeded, detail: "No selected browsers") }
        access.openSelectedBrowser = { false }
        access.openSafari = { Issue.record("Unexpected Safari launch") }
        access.requestDirectCapture = { Issue.record("Unexpected capture"); return false }
        access.clipboardAccess = { .ask }
        access.requestClipboardAccess = { Issue.record("Unexpected clipboard read") }
        return access
    }
}

@Suite @MainActor
struct DesktopPermissionResetTests {
    @Test func fullDiskSetupUsesExistingOwnerWithoutResetOrFinder() async {
        var setups = 0
        var access = DesktopPermissionSystemAccess.permissionFixture()
        access.resetPermission = { _ in Issue.record("Full Disk Access setup must preserve approval"); return .failed }
        access.revealApplication = { Issue.record("Finder must be explicit") }
        let adapter = DesktopPermissionChecklistSystemAdapter(hooks: .init(
            setup: { id in
                #expect(id == .fullDiskAccess)
                setups += 1
                return .init(.ready, detail: "Existing access verified", verificationKey: "grant", requiresVerification: true, verified: true)
            }), access: access, openSettings: { _ in Issue.record("Already-enabled setup must not open Settings") })
        #expect(await adapter.setup(.fullDiskAccess).verified)
        #expect(setups == 1)
    }

    @Test func unpackagedTestRunnerCannotResetInstalledAppPermissions() async {
        #expect(Bundle.main.bundleURL.pathExtension != "app")
        #expect(await DesktopPermissionReset.reset(.accessibility) == .failed)
    }

    @Test(arguments: [DesktopPermissionID.accessibility, .screenRecording])
    func explicitSetupPreservesExistingGrantWithoutReset(permission: DesktopPermissionID) async {
        var access = DesktopPermissionSystemAccess.permissionFixture()
        access.accessibility = { true }
        access.screenRecording = { true }
        let adapter = DesktopPermissionChecklistSystemAdapter(access: access)
        #expect(await adapter.setup(permission).state == .ready)
        #expect(await adapter.observe(permission).state == .ready)
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
        (.microphone, "Microphone"), (.fullDiskAccess, "SystemPolicyAllFiles"),
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
            activationNotificationCenter: NotificationCenter(), requestLocalNetwork: { .init(.ready, detail: "Fixture discovery", verified: true) }, requestEndpoint: { _ in throw URLError(code) })
        let result = try #require(await service.adapter.hooks.setup(.localNetwork))
        #expect(result.state == .failed && !result.verified)
        #expect(result.detail.contains(DesktopEnvironmentConfiguration.lan.appURL.host!))
        #expect(result.detail.contains(reason))
        #expect(result.detail.contains("macOS does not expose the Local Network grant"))
    }
}
