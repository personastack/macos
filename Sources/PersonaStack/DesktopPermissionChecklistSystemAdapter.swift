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
    var accessibility: () -> Bool = { AXIsProcessTrusted() }
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
        _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
    var loginStatus: () -> SMAppService.Status = { SMAppService.mainApp.status }
    var registerLogin: () throws -> Void = { try SMAppService.mainApp.register() }
    var openLoginSettings: () -> Void = { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor
final class DesktopPermissionChecklistSystemAdapter: DesktopPermissionChecklistAdapting {
    var hooks: DesktopPermissionChecklistHooks
    let access: DesktopPermissionSystemAccess
    private let openSettings: (String) -> Void

    init(hooks: DesktopPermissionChecklistHooks = .init(),
         access: DesktopPermissionSystemAccess = .init(),
         openSettings: @escaping (String) -> Void = { section in
             if let url = URL(string: "x-apple.systempreferences:\(section)") { NSWorkspace.shared.open(url) }
         }) {
        self.hooks = hooks
        self.access = access
        self.openSettings = openSettings
    }

    func observe(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation {
        if let value = await hooks.observe(permission) { return value }
        switch permission {
        case .accessibility:
            return grant(access.accessibility(), permission: permission)
        case .screenRecording, .directCapture:
            return grant(access.screenRecording(), permission: permission)
        case .microphone:
            return microphoneObservation()
        case .notifications:
            return await observeNotifications()
        case .launchAtLogin:
            return Self.loginObservation(access.loginStatus())
        default:
            return Self.unconfiguredObservation(permission)
        }
    }

    func setup(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation {
        await setup(permission, automatic: false)
    }

    func setupAutomatically(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation {
        guard !Task.isCancelled else { return .init(.checking, detail: "Check cancelled.") }
        if DesktopPermissionID.setupPermissions.contains(permission) {
            switch permission {
            case .accessibility:
                guard access.accessibility() else { return Self.privacyDenialObservation(permission) }
            case .screenRecording:
                guard access.screenRecording() else { return Self.privacyDenialObservation(permission) }
                guard access.accessibility() else {
                    return .init(.verificationRequired, detail: "Set up Accessibility before PersonaStack can verify desktop capture.")
                }
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
            access.requestAccessibility()
            // AX's prompt return value is synchronous. Approval is asynchronous.
            guard access.accessibility() else {
                openPrivacy("Accessibility")
                return Self.privacyDenialObservation(permission)
            }
        case .screenRecording, .directCapture:
            // CGRequestScreenCaptureAccess can return false without registering
            // the app on newer macOS. A real host SCK request owns that prompt.
            let capturable = await access.requestScreenRecording()
            guard !Task.isCancelled else { return .init(.checking, detail: "Setup cancelled.") }
            if capturable && !access.screenRecording() {
                return .init(.restartRequired, detail: "macOS allowed the screen request, but PersonaStack's current process still reports the old grant. Quit and reopen PersonaStack, then retry Setup \(permission.title).")
            }
            if !capturable { openPrivacy("ScreenCapture") }
        case .microphone:
            if access.microphone() == .notDetermined {
                _ = await access.requestMicrophone()
            } else if access.microphone() == .denied {
                openPrivacy("Microphone")
            }
        case .notifications:
            return await setupNotifications(automatic: automatic)
        case .launchAtLogin:
            return setupLogin(automatic: automatic)
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
            if let value = await hooks.setup(permission) { return value }
            openPrivacy("LocalNetwork")
            return Self.unconfiguredObservation(permission)
        default: break
        }
        guard !Task.isCancelled else { return .init(.checking, detail: "Setup cancelled.") }
        if let value = await hooks.setup(permission) { return value }
        return await observe(permission)
    }

    private func grant(_ allowed: Bool, permission: DesktopPermissionID) -> DesktopPermissionObservation {
        .init(allowed ? .ready : .notGranted,
              detail: allowed ? "macOS permits PersonaStack. Use Setup \(permission.title) to verify the operation."
                              : Self.privacyDenialObservation(permission).detail,
              verificationKey: "\(Bundle.main.bundleIdentifier ?? "unpackaged"):\(permission.rawValue):\(allowed)",
              requiresVerification: true)
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
            return .init(.ready, detail: "Microphone access is allowed. Use Setup Microphone to verify voice input.",
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

    private func setupNotifications(automatic: Bool) async -> DesktopPermissionObservation {
        let settings = await access.notificationSettings()
        guard !Task.isCancelled else { return .init(.checking, detail: "Setup cancelled.") }
        if settings.authorization == .notDetermined {
            do { try await access.requestNotifications() }
            catch { return .init(.failed, detail: "macOS could not request notification approval. Try again.") }
        }
        guard !Task.isCancelled else { return .init(.checking, detail: "Setup cancelled.") }
        let observed = await observeNotifications()
        guard !Task.isCancelled else { return .init(.checking, detail: "Setup cancelled.") }
        if observed.state != .ready && !automatic { openSettings("com.apple.Notifications-Settings.extension") }
        return observed
    }

    private func setupLogin(automatic: Bool) -> DesktopPermissionObservation {
        do {
            let status = try DesktopLoginItemRegistration.registerIfNeeded(status: access.loginStatus, register: access.registerLogin)
            if !automatic && status != .enabled { access.openLoginSettings() }
            if status == .notFound || status == .notRegistered {
                return .init(.failed, detail: DesktopLoginItemRegistration.unconfirmedMessage)
            }
            return Self.loginObservation(status)
        } catch {
            return .init(.failed, detail: "PersonaStack could not register Launch at Login. Check Login Items and retry.")
        }
    }

    static func privacyDenialObservation(_ permission: DesktopPermissionID) -> DesktopPermissionObservation {
        switch permission {
        case .accessibility:
            return .init(.notGranted, detail: "Allow PersonaStack in Privacy & Security → Accessibility. If it is already enabled, remove the old PersonaStack entry with −. Click + and choose PersonaStack.app from Applications. Enable it, then retry Setup Accessibility.")
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
        case .denied: return .init(.denied, detail: "Allow PersonaStack notifications in System Settings.")
        case .authorized, .provisional, .ephemeral:
            guard alerts == .enabled && sounds == .enabled else {
                return .init(.notGranted, detail: "Enable notification alerts and sounds for PersonaStack.")
            }
            return .init(.ready, detail: "macOS allows PersonaStack alerts and sounds.",
                         verificationKey: "notifications:\(authorization.rawValue):\(alerts.rawValue):\(sounds.rawValue)")
        @unknown default: return .init(.checking, detail: "Notification authorization is unknown.")
        }
    }

    static func unconfiguredObservation(_ id: DesktopPermissionID) -> DesktopPermissionObservation {
        switch id {
        case .lockedScreenControl:
            return .init(.unsupported, detail: "Locked-screen control is unavailable in this release. Remote control stops when macOS locks.")
        case .fullDiskAccess:
            return .init(.verificationRequired, detail: "Already enabled in System Settings? Choose Setup Full Disk Access, then Check Access to verify it. If needed, add PersonaStack.app from Applications with the + button in Full Disk Access settings and enable it.")
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
