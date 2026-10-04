import AppKit
@preconcurrency import ApplicationServices
import AVFoundation
import CoreGraphics
import Carbon
import ServiceManagement
import ScreenCaptureKit
import UserNotifications
import PersonaStackCore

/// Existing owners supply their content-free observations and deliberate tests.
/// Nothing here creates a second updater, file executor, chat, or relay owner.
@MainActor
struct DesktopPermissionChecklistHooks {
    var observe: (DesktopPermissionID) async -> DesktopPermissionObservation? = { _ in nil }
    var setup: (DesktopPermissionID) async -> DesktopPermissionObservation? = { _ in nil }
    var verifyAutomatically: (DesktopPermissionID) async -> DesktopPermissionObservation? = { _ in nil }
}

/// Injectable OS boundary. Passive reads never request access. ScreenCaptureKit
/// is deliberately attempted by Setup even when CoreGraphics preflight is false.
@MainActor
struct DesktopPermissionSystemAccess {
    var resetPermission: (DesktopPermissionID) async -> DesktopPermissionResetResult = { await DesktopPermissionReset.reset($0) }
    var openPrivacySettings: (String) -> Void = { section in
        if let url = URL(string: "x-apple.systempreferences:\(section)") { NSWorkspace.shared.open(url) }
    }
    var revealApplication: () -> Void = {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
    var accessibility: () -> Bool = { DesktopAccessibilityPermission.isGranted() }
    var requestAccessibility: () -> Void = {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    var screenRecording: () -> Bool = { CGPreflightScreenCaptureAccess() }
    var requestScreenRecording: () async -> Bool = {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            return !content.displays.isEmpty
        } catch { return false }
    }
    var requestDirectCapture: () async -> Bool = {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard !Task.isCancelled, let display = content.displays.first else { return false }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = 1
            configuration.height = 1
            configuration.capturesAudio = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return image.width > 0 && image.height > 0
        } catch { return false }
    }
    var automation: (Bool) async -> OSStatus = { await DesktopBrowserPermission.automation(prompt: $0) }
    var safariProcessIdentifier: () -> Int32? = { DesktopBrowserPermission.safariProcessIdentifier() }
    var safariProcessIdentity: () -> String? = { DesktopBrowserPermission.safariProcessIdentity()?.verificationKey }
    var verifySafariJavaScript: () async -> Bool = { await DesktopBrowserPermission.verifyJavaScript() }
    var selectedBrowserObservation: () async -> DesktopPermissionObservation = { await DesktopBrowserProfileConsentController.shared.observeSelectedBrowsers() }
    var selectedBrowserSetup: () async -> DesktopPermissionObservation = { await DesktopBrowserProfileConsentController.shared.authorizeSelectedBrowsers() }
    var selectedBrowserCheck: () async -> DesktopPermissionObservation = { await DesktopBrowserProfileConsentController.shared.checkSelectedBrowsers() }
    var openSelectedBrowser: () -> Bool = { DesktopBrowserProfileConsentController.shared.openPendingBrowser() }
    var openSafari: () -> Void = { DesktopBrowserPermission.openSafari() }
    var clipboardAccess: () -> DesktopClipboardAccess = { DesktopClipboardPermission.status() }
    var requestClipboardAccess: () async -> Void = { await DesktopClipboardPermission.request() }
    var microphone: () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) }
    var requestMicrophone: () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }
    var microphoneIdentity: () -> String? = { AVCaptureDevice.default(for: .audio)?.uniqueID }
    var hasMicrophone: () -> Bool = { AVCaptureDevice.default(for: .audio) != nil }
    var notificationSettings: () async -> (authorization: UNAuthorizationStatus, alerts: UNNotificationSetting, sounds: UNNotificationSetting) = {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return (settings.authorizationStatus, settings.alertSetting, settings.soundSetting)
    }
    var requestNotifications: () async throws -> Void = {
        _ = try await DesktopNotificationCoordinator.shared.requestAuthorizationForSetup()
    }
    var verifyNotificationDelivery: () async throws -> Bool = {
        try await DesktopNotificationCoordinator.shared.verifyPermissionDelivery()
    }
    var loginStatus: () -> SMAppService.Status = { DesktopLoginItemRegistration.loginStatus() }
    var registerLogin: () throws -> Void = {
        try SMAppService.agent(plistName: DesktopLoginItemRegistration.crashRecoveryAgentPlistName).register()
    }
    var loginSignatureIsValid: () -> Bool = { DesktopLoginItemRegistration.hasValidBundleSignature() }
    var legacyLoginStatus: () -> SMAppService.Status = { SMAppService.mainApp.status }
    var unregisterLegacyLogin: () throws -> Void = { try SMAppService.mainApp.unregister() }
    var unregisterCrashRecoveryAgent: () throws -> Void = {
        try SMAppService.agent(plistName: DesktopLoginItemRegistration.crashRecoveryAgentPlistName).unregister()
    }
    var registerLegacyLogin: () throws -> Void = { try SMAppService.mainApp.register() }
    var unregisterLoginForSetup: () async throws -> Void = {
        try await SMAppService.agent(plistName: DesktopLoginItemRegistration.crashRecoveryAgentPlistName).unregister()
    }
    var unregisterLegacyLoginForSetup: () async throws -> Void = { try await SMAppService.mainApp.unregister() }
    var openLoginSettings: () -> Void = { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor
final class DesktopPermissionChecklistSystemAdapter: DesktopPermissionChecklistAdapting {
    var hooks: DesktopPermissionChecklistHooks
    let access: DesktopPermissionSystemAccess
    private let evidence: DesktopPermissionEvidence?
    private let openSettings: (String) -> Void
    private var directCaptureVerified = false
    private var verifiedSafariProcess: String?

    init(hooks: DesktopPermissionChecklistHooks = .init(),
         access: DesktopPermissionSystemAccess = .init(),
         evidence: DesktopPermissionEvidence? = .shared,
         openSettings: ((String) -> Void)? = nil) {
        self.hooks = hooks
        self.access = access
        self.evidence = evidence
        self.openSettings = openSettings ?? access.openPrivacySettings
    }

    func observe(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation {
        let current = await observeCurrent(permission)
        if [.denied, .notGranted, .restricted, .failed, .unsupported].contains(current.state) {
            evidence?.invalidate(permission)
        }
        return evidence?.restoring(permission, current: current) ?? current
    }

    private func observeCurrent(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation {
        if let value = await hooks.observe(permission) { return value }
        switch permission {
        case .accessibility:
            return accessibilityObservation()
        case .screenRecording:
            return screenCaptureObservation(permission)
        case .directCapture:
            return directCaptureObservation()
        case .automation:
            return await automationObservation()
        case .safariJavaScript:
            return await safariJavaScriptObservation()
        case .clipboard:
            return clipboardObservation()
        case .microphone:
            return microphoneObservation()
        case .notifications:
            return await observeNotifications()
        case .launchAtLogin:
            return observeLogin()
        default:
            return Self.unconfiguredObservation(permission)
        }
    }

    func setup(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation {
        guard !Task.isCancelled else { return .init(.checking, detail: "Setup cancelled.") }
        return await setup(permission, automatic: false)
    }

    func openLocalNetworkSettings() { openPrivacy("LocalNetwork") }

    func openSettings(_ permission: DesktopPermissionID) {
        switch permission {
        case .accessibility: openPrivacy("Accessibility")
        case .screenRecording: openPrivacy("ScreenCapture")
        case .fullDiskAccess: openFullDiskAccess()
        case .localNetwork: openLocalNetworkSettings()
        case .notifications: openNotificationSettings()
        case .launchAtLogin: access.openLoginSettings()
        case .automation: openPrivacy("Automation")
        case .directCapture: openPrivacy("ScreenCapture")
        case .safariJavaScript:
            if !access.openSelectedBrowser() { access.openSafari() }
        case .clipboard: openPrivacy("Pasteboard")
        default: break
        }
    }

    func check(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation {
        guard !Task.isCancelled else { return .init(.checking, detail: "Check cancelled.") }
        if permission == .notifications { return await checkNotifications() }
        if permission == .safariJavaScript { return await checkSafariJavaScript() }
        if DesktopPermissionID.setupPermissions.contains(permission) {
            return await setupAutomatically(permission)
        }
        if permission == .awakeDuringRemoteWork, let value = await hooks.verifyAutomatically(permission) { return value }
        return await observe(permission)
    }

    func setupAutomatically(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation {
        guard !Task.isCancelled else { return .init(.checking, detail: "Check cancelled.") }
        if DesktopPermissionID.setupPermissions.contains(permission) {
            switch permission {
            case .accessibility:
                return accessibilityObservation()
            case .screenRecording:
                return screenCaptureObservation(permission)
            case .microphone:
                guard access.microphone() == .authorized else { return microphoneObservation() }
            default: break
            }
            if let value = await hooks.verifyAutomatically(permission) { return value }
            return await observe(permission)
        }
        guard DesktopPermissionID.automaticSetup.contains(permission) else { return await observe(permission) }
        return await setup(permission, automatic: true)
    }

    private func setup(_ permission: DesktopPermissionID, automatic: Bool) async -> DesktopPermissionObservation {
        guard !Task.isCancelled else { return .init(.checking, detail: "Setup cancelled.") }
        if [.directCapture, .automation, .safariJavaScript, .clipboard].contains(permission) {
            return await setupSupplementalPermission(permission)
        }
        switch permission {
        case .accessibility:
            if !access.accessibility() { access.requestAccessibility() }
            // AX's prompt return value is synchronous. Approval is asynchronous.
            let current = accessibilityObservation()
            if current.state != .ready { openPrivacy("Accessibility") }
            return current
        case .screenRecording:
            // CGRequestScreenCaptureAccess can return false without registering
            // the app on newer macOS. A real host SCK request owns that prompt.
            let alreadyAllowed = access.screenRecording()
            let capturable = alreadyAllowed ? true : await access.requestScreenRecording()
            guard !Task.isCancelled else { return .init(.checking, detail: "Setup cancelled.") }
            if !alreadyAllowed && capturable && !access.screenRecording() {
                return .init(.restartRequired, detail: "macOS allowed the screen request, but PersonaStack's current process still reports the old grant. Quit and reopen PersonaStack, then retry Setup \(permission.title).")
            }
            guard access.screenRecording() else {
                openPrivacy("ScreenCapture")
                return Self.privacyDenialObservation(permission)
            }
            return screenCaptureObservation(permission)
        case .microphone:
            if access.microphone() == .notDetermined {
                _ = await access.requestMicrophone()
            } else if access.microphone() == .denied {
                openPrivacy("Microphone")
            }
        case .notifications:
            return await setupNotifications(automatic: automatic)
        case .launchAtLogin:
            return await setupLogin()
        case .fullDiskAccess:
            if let value = await hooks.setup(permission) {
                if let current = await hooks.observe(permission), current != value {
                    return .init(.checking, detail: "Setup changed. Choose Retry for Full Disk Access.")
                }
                guard !Task.isCancelled else { return .init(.checking, detail: "Setup cancelled.") }
                return value
            }
            openFullDiskAccess()
            return Self.unconfiguredObservation(permission)
        case .desktopFiles, .documentsFiles, .downloadsFiles, .removableVolumes, .networkVolumes:
            // The existing executor's explicit hook owns the resource probe.
            if let value = await hooks.setup(permission) {
                guard !Task.isCancelled else { return .init(.checking, detail: "Setup cancelled.") }
                if value.state == .denied { openPrivacy("FilesAndFolders") }
                return value
            }
            openPrivacy("FilesAndFolders")
            return Self.unconfiguredObservation(permission)
        case .localNetwork:
            if let value = await hooks.setup(permission) {
                guard !Task.isCancelled else { return .init(.checking, detail: "Setup cancelled.") }
                return value
            }
            return Self.unconfiguredObservation(permission)
        default: break
        }
        guard !Task.isCancelled else { return .init(.checking, detail: "Setup cancelled.") }
        if let value = await hooks.setup(permission) { return value }
        return await observe(permission)
    }

    private func setupSupplementalPermission(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation {
        switch permission {
        case .directCapture:
            directCaptureVerified = false
            let captured = await access.requestDirectCapture()
            guard !Task.isCancelled else { return .init(.verificationRequired, detail: "Capture check cancelled. Choose Retry.") }
            guard captured, access.screenRecording() else {
                openPrivacy("ScreenCapture")
                return .init(.failed, detail: "Direct capture was not verified. Allow PersonaStack's screen request, including any request to bypass the private window picker. Then choose Retry. Quit and reopen PersonaStack if macOS requests it.")
            }
            if let driver = await hooks.setup(.directCapture) {
                guard !Task.isCancelled else { return .init(.checking, detail: "Desktop verification was cancelled.") }
                guard driver.state == .ready, driver.verified else { return driver }
            }
            directCaptureVerified = true
            return directCaptureObservation()
        case .automation:
            _ = await access.automation(true)
            guard !Task.isCancelled else { return .init(.verificationRequired, detail: "Automation setup cancelled. Choose Retry to continue.") }
            let current = await automationObservation()
            if current.state != .ready { openPrivacy("Automation") }
            return current
        case .safariJavaScript:
            let current = await checkSafariJavaScript(checkSelectedBrowsers: false)
            guard !Task.isCancelled else { return .init(.checking, detail: "Setup cancelled.") }
            guard current.state == .ready else { access.openSafari(); return current }
            let selected = await access.selectedBrowserSetup()
            guard !Task.isCancelled else { return .init(.checking, detail: "Setup cancelled.") }
            guard selected.state.satisfiesSetup else { return selected }
            return await safariJavaScriptObservation()
        case .clipboard:
            if [.notDetermined, .ask].contains(access.clipboardAccess()) { await access.requestClipboardAccess() }
            guard !Task.isCancelled else { return .init(.verificationRequired, detail: "Clipboard setup cancelled. Choose Retry to continue.") }
            let current = clipboardObservation()
            if !current.state.satisfiesSetup { openPrivacy("Pasteboard") }
            return current
        default: return await observe(permission)
        }
    }

    /// Permission approval is independent of input trust and Cua readiness.
    /// Runtime command admission still verifies the owned capture service.
    func screenCaptureObservation(_ permission: DesktopPermissionID) -> DesktopPermissionObservation {
        guard access.screenRecording() else { return Self.privacyDenialObservation(permission) }
        return .init(.ready, detail: "macOS allows PersonaStack Screen Capture access. No screenshot was taken.",
                     verificationKey: "\(Bundle.main.bundleIdentifier ?? "unpackaged"):\(permission.rawValue):allowed",
                     verified: true)
    }

    private func directCaptureObservation() -> DesktopPermissionObservation {
        guard access.screenRecording() else {
            directCaptureVerified = false
            return Self.privacyDenialObservation(.directCapture)
        }
        guard directCaptureVerified else {
            return .init(.verificationRequired, detail: "Setup verifies direct screen capture. macOS may separately ask to bypass the private window picker. A 1-pixel screen image is discarded without saving or sending it.")
        }
        return .init(.ready, detail: "Direct screen capture worked. No image was saved or sent.", verified: true)
    }

    private func clipboardObservation() -> DesktopPermissionObservation {
        switch access.clipboardAccess() {
        case .notNeeded:
            return .init(.notNeeded, detail: "This macOS version has no programmatic clipboard permission.")
        case .allowed:
            return .init(.ready, detail: "macOS always allows PersonaStack's programmatic clipboard access. No clipboard content was read by this check.", verified: true)
        case .denied:
            return .init(.denied, detail: "Choose Always Allow for PersonaStack in Privacy & Security → Pasteboard. Accessibility does not replace this policy.")
        case .notDetermined, .ask:
            return .init(.verificationRequired, detail: "Setup requests clipboard access using a text read and discards it. Choose Always Allow in Privacy & Security → Pasteboard for unattended access. If PersonaStack is missing, copy harmless text in another app and choose Retry.")
        case .unknown:
            return .init(.verificationRequired, detail: "Clipboard policy could not be read. Review PersonaStack in Privacy & Security → Pasteboard and return to PersonaStack.")
        }
    }

    private func automationObservation() async -> DesktopPermissionObservation {
        let status = await access.automation(false)
        switch status {
        case noErr:
            return .init(.ready, detail: "macOS allows PersonaStack to send Apple Events to Safari. Other apps have separate grants.", verificationKey: "safari-automation:allowed", verified: true)
        case OSStatus(errAEEventNotPermitted):
            verifiedSafariProcess = nil
            return .init(.denied, detail: "Enable Safari under PersonaStack in Privacy & Security → Automation. This grant is separate from Accessibility.")
        case OSStatus(errAEEventWouldRequireUserConsent):
            verifiedSafariProcess = nil
            return .init(.notGranted, detail: "Allow PersonaStack to control Safari when macOS asks. macOS grants access separately for each app.")
        default:
            verifiedSafariProcess = nil
            return .init(.verificationRequired, detail: "Safari Automation access could not be read. Open Safari and choose Retry. A missing or inactive Safari process does not prove permission denial.")
        }
    }

    private func safariJavaScriptObservation(includeSelectedBrowsers: Bool = true) async -> DesktopPermissionObservation {
        let automation = await automationObservation()
        guard automation.state == .ready else {
            return .init(.verificationRequired, detail: "Set up Application Automation for Safari first. " + DesktopBrowserPermission.javascriptInstructions)
        }
        if includeSelectedBrowsers {
            let selected = await access.selectedBrowserObservation()
            guard !Task.isCancelled else { return .init(.checking, detail: "Browser check cancelled.") }
            guard selected.state.satisfiesSetup else { return selected }
        }
        guard let identity = access.safariProcessIdentity(), verifiedSafariProcess == identity else {
            verifiedSafariProcess = nil
            return .init(.verificationRequired, detail: DesktopBrowserPermission.javascriptInstructions,
                         verificationKey: access.safariProcessIdentity())
        }
        return .init(.ready, detail: "Safari allows JavaScript from Apple Events. No page content was read or changed. Return to PersonaStack after changing Safari's developer settings.", verificationKey: identity, verified: true)
    }

    private func checkSafariJavaScript(checkSelectedBrowsers: Bool = true) async -> DesktopPermissionObservation {
        verifiedSafariProcess = nil
        guard await automationObservation().state == .ready else { return await safariJavaScriptObservation() }
        guard !Task.isCancelled, let pid = access.safariProcessIdentifier(), let identity = access.safariProcessIdentity() else { return await safariJavaScriptObservation() }
        let verified = await access.verifySafariJavaScript()
        guard !Task.isCancelled, access.safariProcessIdentifier() == pid, access.safariProcessIdentity() == identity else {
            return .init(.verificationRequired, detail: "Safari changed or the check was cancelled. Return to PersonaStack to verify Safari again.")
        }
        guard verified else { return .init(.verificationRequired, detail: DesktopBrowserPermission.javascriptInstructions) }
        verifiedSafariProcess = identity
        if checkSelectedBrowsers {
            let selected = await access.selectedBrowserCheck()
            guard !Task.isCancelled else { return .init(.checking, detail: "Browser check cancelled.") }
            guard selected.state.satisfiesSetup else { return selected }
        }
        return await safariJavaScriptObservation(includeSelectedBrowsers: checkSelectedBrowsers)
    }

    /// Read OS trust and content-free AX access without exercising input.
    /// Runtime health and action delivery remain owned by DesktopControlRuntime.
    func accessibilityObservation() -> DesktopPermissionObservation {
        guard access.accessibility() else { return Self.privacyDenialObservation(.accessibility) }
        return .init(.ready, detail: "macOS allows PersonaStack Accessibility access. No desktop action was performed.",
                     verificationKey: "\(Bundle.main.bundleIdentifier ?? "unpackaged"):accessibility:allowed",
                     verified: true)
    }

    private func microphoneObservation() -> DesktopPermissionObservation {
        let status = access.microphone()
        switch status {
        case .notDetermined: return .init(.notGranted, detail: "Allow microphone input for voice messages.")
        case .denied: return Self.privacyDenialObservation(.microphone)
        case .restricted: return .init(.restricted, detail: "macOS restricts microphone access. Contact your Mac administrator.")
        case .authorized:
            guard access.hasMicrophone() else {
                return .init(.failed, detail: "No microphone is available. Connect an audio input and retry.")
            }
            return .init(.ready, detail: "Microphone access is allowed. Choose Check to verify voice input.",
                         verificationKey: "\(Bundle.main.bundleIdentifier ?? "unpackaged"):microphone:authorized",
                         requiresVerification: true)
        @unknown default: return .init(.checking, detail: "Microphone authorization is unknown.")
        }
    }

    private func openPrivacy(_ name: String) {
        openSettings("com.apple.preference.security?Privacy_\(name)")
    }

    private func observeNotifications() async -> DesktopPermissionObservation {
        let settings = await access.notificationSettings()
        return Self.notificationObservation(authorization: settings.authorization, alerts: settings.alerts, sounds: settings.sounds)
    }

    private func openNotificationSettings() {
        openSettings("com.apple.Notifications-Settings.extension?id=ai.personastack.desktop")
    }

    private func checkNotifications() async -> DesktopPermissionObservation {
        let observed = await observeNotifications()
        guard !Task.isCancelled else { return .init(.checking, detail: "Check cancelled.") }
        guard observed.state == .ready else { return observed }
        do {
            let delivered = try await access.verifyNotificationDelivery()
            guard !Task.isCancelled else { return .init(.checking, detail: "Check cancelled.") }
            let current = await observeNotifications()
            guard !Task.isCancelled else { return .init(.checking, detail: "Check cancelled.") }
            guard current.state == .ready else { return current }
            guard current.verificationKey == observed.verificationKey else {
                return .init(.verificationRequired, detail: "Notification settings changed. Choose Check again.")
            }
            guard delivered else {
                return .init(.verificationRequired, detail: "Notifications are allowed, but the test was not delivered. Choose Check to retry.")
            }
            return .init(.ready, detail: "PersonaStack verified notification delivery on this Mac.",
                         verificationKey: current.verificationKey, requiresVerification: true, verified: true)
        } catch {
            guard !Task.isCancelled else { return .init(.checking, detail: "Check cancelled.") }
            let current = await observeNotifications()
            guard !Task.isCancelled else { return .init(.checking, detail: "Check cancelled.") }
            guard current.state == .ready else { return current }
            let failure = error as NSError
            let detail = failure.domain == UNErrorDomain && failure.code == UNError.Code.notificationsNotAllowed.rawValue
                ? "Notifications are allowed in Settings, but macOS rejected this app's test notification. Quit and reopen PersonaStack, then choose Check. If it still fails, reinstall a valid signed app."
                : "Notifications are allowed in Settings, but PersonaStack could not deliver the test notification. Choose Check to retry."
            return .init(.failed, detail: detail)
        }
    }

    private func setupNotifications(automatic: Bool) async -> DesktopPermissionObservation {
        let settings = await access.notificationSettings()
        guard !Task.isCancelled else { return .init(.checking, detail: "Setup cancelled.") }
        var requestFailed = false
        if !automatic || settings.authorization == .notDetermined {
            do { try await access.requestNotifications() }
            catch { requestFailed = true }
        }
        guard !Task.isCancelled else { return .init(.checking, detail: "Setup cancelled.") }
        var observed = await checkNotifications()
        guard !Task.isCancelled else { return .init(.checking, detail: "Setup cancelled.") }
        if requestFailed && observed.state == .notGranted {
            let current = await access.notificationSettings()
            guard !Task.isCancelled else { return .init(.checking, detail: "Setup cancelled.") }
            if current.authorization == .notDetermined {
                observed = .init(.failed, detail: "macOS could not request notification approval. Open PersonaStack's Notifications settings, then choose Check.")
            }
        }
        if observed.state != .ready && !automatic { openNotificationSettings() }
        return observed
    }

    private func setupLogin() async -> DesktopPermissionObservation {
        do {
            let status = try DesktopLoginItemRegistration.registerAndMigrateLegacy(
                status: access.loginStatus, register: access.registerLogin,
                unregisterAgent: access.unregisterCrashRecoveryAgent,
                legacyStatus: access.legacyLoginStatus,
                unregisterLegacy: access.unregisterLegacyLogin,
                registerLegacy: access.registerLegacyLogin)
            guard !Task.isCancelled else { return .init(.checking, detail: "Setup cancelled.") }
            if status == .notFound || status == .notRegistered {
                return .init(.failed, detail: DesktopLoginItemRegistration.unconfirmedMessage)
            }
            return observeLogin()
        } catch {
            guard !Task.isCancelled else { return .init(.checking, detail: "Setup cancelled.") }
            let failure = error as NSError
            if #available(macOS 15, *), failure.domain == SMAppServiceErrorDomain && failure.code == kSMErrorInvalidSignature {
                return .init(.failed, detail: DesktopLoginItemRegistration.invalidSignatureMessage)
            }
            return .init(.failed, detail: "PersonaStack could not register Launch at Login. Open Login Items and retry.")
        }
    }

    private func observeLogin() -> DesktopPermissionObservation {
        let status = access.loginStatus()
        guard access.loginSignatureIsValid() else {
            return .init(.failed, detail: DesktopLoginItemRegistration.invalidSignatureMessage)
        }
        return Self.loginObservation(status)
    }

    static func privacyDenialObservation(_ permission: DesktopPermissionID) -> DesktopPermissionObservation {
        switch permission {
        case .accessibility:
            return .init(.notGranted, detail: "Enable PersonaStack in Privacy & Security → Accessibility (Device Control and Data Access on newer macOS). Already enabled? Remove its old entry with −, click +, then add the app shown by Show PersonaStack in Finder. Enable it again. Keep this window open; approval updates automatically.")
        case .microphone:
            return .init(.denied, detail: "Enable PersonaStack in Privacy & Security → Microphone. If it is already enabled, turn it off and on. Relaunch PersonaStack if macOS requests it, then retry Setup Microphone.")
        case .screenRecording, .directCapture:
            return .init(.notGranted, detail: "Allow PersonaStack in Privacy & Security → Screen & System Audio Recording. If it is already enabled, turn it off and on. Relaunch PersonaStack if macOS requests it, then retry Setup \(permission.title).")
        default:
            return .init(.notGranted, detail: "Allow PersonaStack in Privacy & Security → \(permission.title).")
        }
    }

    private func openFullDiskAccess() {
        openSettings("com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")
    }

    static func loginObservation(_ status: SMAppService.Status) -> DesktopPermissionObservation {
        switch status {
        case .enabled: .init(.ready, detail: "PersonaStack starts after you log in to this Mac.")
        case .requiresApproval: .init(.notGranted, detail: DesktopLoginItemRegistration.approvalMessage)
        case .notRegistered: .init(.notGranted, detail: "Register PersonaStack to launch after login.")
        case .notFound: .init(.notGranted, detail: "macOS has no registration for PersonaStack's login item. Retry Launch at Login setup.")
        @unknown default: .init(.checking, detail: "Login service status is unknown.")
        }
    }

    static func notificationObservation(authorization: UNAuthorizationStatus,
                                        alerts: UNNotificationSetting,
                                        sounds: UNNotificationSetting) -> DesktopPermissionObservation {
        switch authorization {
        case .notDetermined: return .init(.notGranted, detail: "Allow message and update alerts.")
        case .denied: return .init(.denied, detail: "Allow PersonaStack notifications in System Settings. macOS remembers this decision and cannot clear it from the app. Turn Allow Notifications on, then choose Check.")
        case .authorized, .provisional, .ephemeral:
            guard alerts == .enabled && sounds == .enabled else {
                return .init(.notGranted, detail: "Enable notification alerts and sounds for PersonaStack in Settings, then choose Check. macOS cannot clear this decision from the app.")
            }
            return .init(.ready, detail: "Notifications are allowed. Choose Check to verify delivery.",
                         verificationKey: "notifications:\(authorization.rawValue):\(alerts.rawValue):\(sounds.rawValue)",
                         requiresVerification: true)
        @unknown default: return .init(.checking, detail: "Notification authorization is unknown.")
        }
    }

    static func unconfiguredObservation(_ id: DesktopPermissionID) -> DesktopPermissionObservation {
        switch id {
        case .lockedScreenControl:
            return .init(.unsupported, detail: "Locked-screen control is unavailable in this release. Remote control stops when macOS locks.")
        case .fullDiskAccess:
            return .init(.verificationRequired, detail: "Enable PersonaStack in Privacy & Security → Full Disk Access. If it is missing, click +, select PersonaStack.app in Applications, click Open, then enable its switch. Return here for automatic verification.")
        case .inputMonitoring:
            return .init(.notNeeded, detail: "Mouse and keyboard control and the active local takeover filter use Accessibility. No separate Input Monitoring grant is required.")
        case .camera: return .init(.notNeeded, detail: "PersonaStack does not use camera capture.")
        case .speechRecognition: return .init(.notNeeded, detail: "Voice messages use audio recording. Native speech recognition is not used.")
        case .systemAudio: return .init(.notNeeded, detail: "The current Cua recorder captures screen video without system audio.")
        case .automation: return .init(.verificationRequired, detail: "Approve Safari access when macOS asks.")
        case .removableVolumes, .networkVolumes:
            return .init(.checking, detail: "Mounted volumes have not been inspected. Use PersonaStack's permission checklist to verify selected resources.")
        case .directCapture:
            return .init(.checking, detail: "Setup verifies a discarded screen capture.")
        default:
            return .init(.checking, detail: "Use Setup \(id.title) to verify this capability through its existing app owner.")
        }
    }
}
