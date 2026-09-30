import AppKit
@preconcurrency import ApplicationServices
import AVFoundation
import CoreGraphics
import ServiceManagement
import UserNotifications
import PersonaStackCore

/// Existing owners supply their content-free observations and deliberate tests.
/// Nothing here creates a second updater, file executor, chat, or relay owner.
@MainActor
struct DesktopPermissionChecklistHooks {
    var observe: (DesktopPermissionID) async -> DesktopPermissionObservation? = { _ in nil }
    var setup: (DesktopPermissionID) async -> DesktopPermissionObservation? = { _ in nil }
}

@MainActor
final class DesktopPermissionChecklistSystemAdapter: DesktopPermissionChecklistAdapting {
    var hooks: DesktopPermissionChecklistHooks
    private let notificationCenter: UNUserNotificationCenter
    private let openSettings: (String) -> Void

    init(hooks: DesktopPermissionChecklistHooks = .init(),
         notificationCenter: UNUserNotificationCenter = .current(),
         openSettings: @escaping (String) -> Void = { section in
             if let url = URL(string: "x-apple.systempreferences:\(section)") { NSWorkspace.shared.open(url) }
         }) {
        self.hooks = hooks
        self.notificationCenter = notificationCenter
        self.openSettings = openSettings
    }

    func observe(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation {
        if let value = await hooks.observe(permission) { return value }
        switch permission {
        case .accessibility:
            return grant(AXIsProcessTrusted(), permission: permission)
        case .screenRecording:
            return grant(CGPreflightScreenCaptureAccess(), permission: permission)
        case .microphone:
            return microphoneObservation()
        case .notifications:
            let settings = await notificationCenter.notificationSettings()
            return Self.notificationObservation(authorization: settings.authorizationStatus,
                                                alerts: settings.alertSetting, sounds: settings.soundSetting)
        case .launchAtLogin:
            return Self.loginObservation(SMAppService.mainApp.status)
        default:
            return Self.unconfiguredObservation(permission)
        }
    }

    func setup(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation {
        guard !Task.isCancelled else { return .init(.checking, detail: "Setup cancelled.") }
        switch permission {
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(options) { openPrivacy("Accessibility") }
        case .screenRecording:
            if !CGRequestScreenCaptureAccess() { openPrivacy("ScreenCapture") }
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            } else if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
                openPrivacy("Microphone")
            }
        case .notifications:
            let settings = await notificationCenter.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                do { _ = try await notificationCenter.requestAuthorization(options: [.alert, .sound]) }
                catch { return .init(.failed, detail: "macOS could not request notification approval. Try again.") }
            } else {
                openSettings("com.apple.Notifications-Settings.extension")
            }
        case .launchAtLogin:
            do {
                if SMAppService.mainApp.status == .notRegistered { try SMAppService.mainApp.register() }
                if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            } catch {
                return .init(.failed, detail: "PersonaStack could not register Launch at Login. Check Login Items and retry.")
            }
        case .fullDiskAccess: openPrivacy("AllFiles")
        case .desktopFiles, .documentsFiles, .downloadsFiles, .removableVolumes, .networkVolumes:
            // The existing executor's explicit hook owns the resource probe.
            if let value = await hooks.setup(permission) { return value }
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
                              : "Allow PersonaStack in Privacy & Security → \(permission.title).",
              verificationKey: "\(Bundle.main.bundleIdentifier ?? "unpackaged"):\(permission.rawValue):\(allowed)",
              requiresVerification: true)
    }

    private func microphoneObservation() -> DesktopPermissionObservation {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .notDetermined: return .init(.notGranted, detail: "Allow microphone input for voice messages.")
        case .denied: return .init(.denied, detail: "Enable PersonaStack in Privacy & Security → Microphone.")
        case .restricted: return .init(.restricted, detail: "macOS restricts microphone access. Contact your Mac administrator.")
        case .authorized:
            guard AVCaptureDevice.default(for: .audio) != nil else {
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

    static func loginObservation(_ status: SMAppService.Status) -> DesktopPermissionObservation {
        switch status {
        case .enabled: .init(.ready, detail: "PersonaStack starts after you log in to this Mac.")
        case .requiresApproval: .init(.notGranted, detail: "Allow PersonaStack in General → Login Items & Extensions.")
        case .notRegistered: .init(.notGranted, detail: "Register PersonaStack to launch after login.")
        case .notFound: .init(.failed, detail: "The login service is missing. Install PersonaStack in Applications.")
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
            return .init(.ready, detail: "Alerts and sounds are allowed. Use Setup Notifications to send a test alert.",
                         verificationKey: "notifications:\(authorization.rawValue):\(alerts.rawValue):\(sounds.rawValue)",
                         requiresVerification: true)
        @unknown default: return .init(.checking, detail: "Notification authorization is unknown.")
        }
    }

    static func unconfiguredObservation(_ id: DesktopPermissionID) -> DesktopPermissionObservation {
        switch id {
        case .lockedScreenControl:
            return .init(.unsupported, detail: "Locked-screen control has no proven helper in this release. Full setup cannot finish yet.")
        case .fullDiskAccess:
            return .init(.unsupported, detail: "Enable PersonaStack in Full Disk Access. A qualified protected-file check is still required to prove access.")
        case .inputMonitoring:
            return .init(.notNeeded, detail: "Ordinary mouse and keyboard control does not require Input Monitoring. No locked-control listener is installed.")
        case .camera: return .init(.notNeeded, detail: "PersonaStack does not use camera capture.")
        case .speechRecognition: return .init(.notNeeded, detail: "Voice messages use audio recording. Native speech recognition is not used.")
        case .systemAudio: return .init(.notNeeded, detail: "The current Cua recorder captures screen video without system audio.")
        case .automation: return .init(.notNeeded, detail: "No target-specific Apple Events integration is configured.")
        case .removableVolumes, .networkVolumes:
            return .init(.notNeeded, detail: "No \(id.title.lowercased()) are selected for remote file access.")
        case .directCapture:
            return .init(.checking, detail: "Use Setup Direct Capture to verify the actual screen-capture operation.")
        default:
            return .init(.checking, detail: "Use Setup \(id.title) to verify this capability through its existing app owner.")
        }
    }
}
