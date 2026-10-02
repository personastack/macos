import AppKit
@preconcurrency import ApplicationServices
import AVFoundation
import CoreGraphics
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
    private let openSettings: (String) -> Void
    private var resetObservations: [DesktopPermissionID: DesktopPermissionObservation] = [:]

    init(hooks: DesktopPermissionChecklistHooks = .init(),
         access: DesktopPermissionSystemAccess = .init(),
         openSettings: ((String) -> Void)? = nil) {
        self.hooks = hooks
        self.access = access
        self.openSettings = openSettings ?? access.openPrivacySettings
    }

    func observe(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation {
        if let value = resetObservations[permission] { return value }
        if let value = await hooks.observe(permission) { return value }
        switch permission {
        case .accessibility:
            return accessibilityObservation()
        case .screenRecording, .directCapture:
            return screenCaptureObservation(permission)
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
        if let value = resetObservations[permission] {
            if permission == .fullDiskAccess { openFullDiskAccess() }
            return value
        }
        if let reset = await resetForSetup(permission) { return reset }
        return await setup(permission, automatic: false)
    }

    func openLocalNetworkSettings() { openPrivacy("LocalNetwork") }

    func openSettings(_ permission: DesktopPermissionID) {
        switch permission {
        case .localNetwork: openLocalNetworkSettings()
        case .notifications: openNotificationSettings()
        case .launchAtLogin: access.openLoginSettings()
        default: break
        }
    }

    func check(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation {
        guard !Task.isCancelled else { return .init(.checking, detail: "Check cancelled.") }
        if let value = resetObservations[permission] { return value }
        if permission == .notifications { return await checkNotifications() }
        if DesktopPermissionID.setupPermissions.contains(permission) {
            return await setupAutomatically(permission)
        }
        if permission == .awakeDuringRemoteWork, let value = await hooks.verifyAutomatically(permission) { return value }
        return await observe(permission)
    }

    func setupAutomatically(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation {
        guard !Task.isCancelled else { return .init(.checking, detail: "Check cancelled.") }
        if let value = resetObservations[permission] { return value }
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
        switch permission {
        case .accessibility:
            if !access.accessibility() { access.requestAccessibility() }
            // AX's prompt return value is synchronous. Approval is asynchronous.
            let current = accessibilityObservation()
            if current.state != .ready { openPrivacy("Accessibility") }
            return current
        case .screenRecording, .directCapture:
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
            return await setupLogin(automatic: automatic)
        case .fullDiskAccess:
            if let value = await hooks.setup(permission) {
                if let current = await hooks.observe(permission), current != value {
                    return .init(.checking, detail: "Setup changed. Retry Setup Full Disk Access.")
                }
                guard !Task.isCancelled else { return .init(.checking, detail: "Setup cancelled.") }
                if value.state == .notGranted || value.state == .denied { openFullDiskAccess() }
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

    private func resetForSetup(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation? {
        guard DesktopPermissionReset.arguments(for: permission) != nil else { return nil }
        let result = await access.resetPermission(permission)
        // Reset may have changed OS state even when cancellation or a tool
        // failure prevents confirmation. Never reuse this process's cached grant.
        if result != .notApplicable {
            resetObservations[permission] = Self.resetObservation(permission, confirmed: result == .cleared)
            if permission == .screenRecording || permission == .directCapture {
                for id in [DesktopPermissionID.screenRecording, .directCapture] {
                    resetObservations[id] = Self.resetObservation(id, confirmed: result == .cleared)
                }
            }
        }
        guard !Task.isCancelled else { return .init(.checking, detail: "Setup cancelled.") }
        guard result != .notApplicable else { return nil }
        if result == .cleared {
            // Register the current application for resources that have a prompt.
            // Its in-process cached answer cannot prove access after a reset.
            switch permission {
            case .accessibility: access.requestAccessibility()
            case .screenRecording, .directCapture: _ = await access.requestScreenRecording()
            case .microphone: _ = await access.requestMicrophone()
            default: break
            }
        }
        guard !Task.isCancelled else { return .init(.checking, detail: "Setup cancelled.") }
        if permission == .fullDiskAccess { openFullDiskAccess() }
        else { openPrivacy(Self.privacySection(permission)) }
        return resetObservations[permission]
    }

    private static func privacySection(_ permission: DesktopPermissionID) -> String {
        switch permission {
        case .accessibility: return "Accessibility"
        case .screenRecording, .directCapture: return "ScreenCapture"
        case .microphone: return "Microphone"
        case .fullDiskAccess: return "AllFiles"
        default: return "FilesAndFolders"
        }
    }

    private static func resetObservation(_ permission: DesktopPermissionID, confirmed: Bool) -> DesktopPermissionObservation {
        if permission == .fullDiskAccess {
            let prefix = confirmed
                ? "Cleared PersonaStack's previous Full Disk Access decision."
                : "macOS could not confirm the Full Disk Access reset."
            return .init(confirmed ? .restartRequired : .failed,
                detail: "\(prefix) macOS does not add the app to this list automatically. Click + in Full Disk Access, select /Applications/PersonaStack.app, click Open and enable it. Finder shows the current app. Quit and reopen PersonaStack, then choose Check. Setup reopens these steps without resetting again.")
        }
        let message = confirmed
            ? "Cleared PersonaStack's previous \(permission.title) decision. Enable access for the current PersonaStack.app in Settings. Use + to add it if available. Quit and reopen PersonaStack to check the new grant."
            : "macOS could not confirm the reset of PersonaStack's \(permission.title) decision. Check its entry in Settings. Quit and reopen PersonaStack before retrying."
        return .init(confirmed ? .restartRequired : .failed, detail: message)
    }

    /// Permission approval is independent of input trust and Cua readiness.
    /// Runtime command admission still verifies the owned capture service.
    func screenCaptureObservation(_ permission: DesktopPermissionID) -> DesktopPermissionObservation {
        if let value = resetObservations[permission] { return value }
        guard access.screenRecording() else { return Self.privacyDenialObservation(permission) }
        return .init(.ready, detail: "macOS allows PersonaStack Screen Capture access. No screenshot was taken.",
                     verificationKey: "\(Bundle.main.bundleIdentifier ?? "unpackaged"):\(permission.rawValue):allowed",
                     verified: true)
    }

    /// Read OS trust and content-free AX access without exercising input.
    /// Runtime health and action delivery remain owned by DesktopControlRuntime.
    func accessibilityObservation() -> DesktopPermissionObservation {
        if let value = resetObservations[.accessibility] { return value }
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
        var observed = automatic ? await observeNotifications() : await checkNotifications()
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

    private func setupLogin(automatic: Bool) async -> DesktopPermissionObservation {
        do {
            let status: SMAppService.Status
            if automatic {
                status = try DesktopLoginItemRegistration.registerAndMigrateLegacy(
                    status: access.loginStatus, register: access.registerLogin,
                    unregisterAgent: access.unregisterCrashRecoveryAgent,
                    legacyStatus: access.legacyLoginStatus,
                    unregisterLegacy: access.unregisterLegacyLogin,
                    registerLegacy: access.registerLegacyLogin)
            } else {
                status = try await DesktopLoginItemRegistration.resetAndRegister(
                    status: access.loginStatus, unregister: access.unregisterLoginForSetup,
                    legacyStatus: access.legacyLoginStatus, unregisterLegacy: access.unregisterLegacyLoginForSetup,
                    register: access.registerLogin)
            }
            guard !Task.isCancelled else { return .init(.checking, detail: "Setup cancelled.") }
            if !automatic && status != .enabled { access.openLoginSettings() }
            if status == .notFound || status == .notRegistered {
                return .init(.failed, detail: DesktopLoginItemRegistration.unconfirmedMessage)
            }
            return observeLogin()
        } catch {
            guard !Task.isCancelled else { return .init(.checking, detail: "Setup cancelled.") }
            if !automatic { access.openLoginSettings() }
            let setupFailure = error as? DesktopLoginItemRegistration.SetupFailure
            let failure = (setupFailure?.underlying ?? error) as NSError
            if #available(macOS 15, *), failure.domain == SMAppServiceErrorDomain && failure.code == kSMErrorInvalidSignature {
                let operation: String
                switch setupFailure?.phase {
                case .removeAgent: operation = "macOS refused to remove PersonaStack's previous recovery login item. "
                case .removeLegacy: operation = "macOS refused to remove PersonaStack's previous main-app login item. "
                default: operation = "macOS refused the new login registration. "
                }
                return .init(.failed, detail: operation + DesktopLoginItemRegistration.invalidSignatureMessage)
            }
            if let setupFailure, setupFailure.phase != .registerCurrent {
                return .init(.failed, detail: "macOS could not confirm removal of PersonaStack's previous login registration. Both login owners were checked. Setup did not register a replacement. Check Login Items and retry.")
            }
            return .init(.failed, detail: "PersonaStack could not register Launch at Login. Check Login Items and retry.")
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
        access.revealApplication()
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
            return .init(.verificationRequired, detail: "Already enabled in System Settings? Choose Check to verify it. If needed, choose Setup and add PersonaStack.app from Applications with the + button in Full Disk Access settings.")
        case .inputMonitoring:
            return .init(.notNeeded, detail: "Ordinary mouse and keyboard control does not require Input Monitoring. No locked-control listener is installed.")
        case .camera: return .init(.notNeeded, detail: "PersonaStack does not use camera capture.")
        case .speechRecognition: return .init(.notNeeded, detail: "Voice messages use audio recording. Native speech recognition is not used.")
        case .systemAudio: return .init(.notNeeded, detail: "The current Cua recorder captures screen video without system audio.")
        case .automation: return .init(.notNeeded, detail: "No target-specific Apple Events integration is configured.")
        case .removableVolumes, .networkVolumes:
            return .init(.checking, detail: "Mounted volumes have not been inspected. Use PersonaStack's permission checklist to verify selected resources.")
        case .directCapture:
            return .init(.checking, detail: "Use Setup Direct Capture to verify the actual screen-capture operation.")
        default:
            return .init(.checking, detail: "Use Setup \(id.title) to verify this capability through its existing app owner.")
        }
    }
}
