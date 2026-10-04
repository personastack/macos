import AppKit
import Combine
import Foundation
import PersonaStackCore
import ServiceManagement

enum DesktopControlActivityKind: String, Sendable {
    case observing = "Observing the desktop"
    case input = "Using keyboard or mouse"
    case application = "Using an application"
    case window = "Managing a window"
    case clipboard = "Using the clipboard"
    case browser = "Using the browser"
    case cua = "Using desktop tools"
    case file = "Working with files"
    case shell = "Running a command"

    init?(operation: String?) {
        switch operation {
        case "desktop_control_observe": self = .observing
        case "desktop_control_input": self = .input
        case "desktop_control_application": self = .application
        case "desktop_control_window": self = .window
        case "desktop_control_clipboard": self = .clipboard
        case "desktop_control_browser": self = .browser
        case "desktop_control_cua": self = .cua
        case "desktop_control_file": self = .file
        case "desktop_control_execute", "desktop_control_exec_read", "desktop_control_exec_write",
             "desktop_control_exec_status", "desktop_control_exec_cancel": self = .shell
        default: return nil
        }
    }
}

struct DesktopControlActivity: Equatable, Sendable {
    var personaName: String?
    var workspaceName: String?
    var operation: DesktopControlActivityKind?
    var elapsedSeconds: Int

    var ownerLabel: String {
        guard let personaName else { return "An authorized persona" }
        guard let workspaceName else { return personaName }
        return "\(personaName) · \(workspaceName)"
    }

    var elapsedLabel: String {
        let minutes = max(0, elapsedSeconds) / 60
        return minutes == 0 ? "Less than a minute" : "\(minutes) min"
    }
}

struct DesktopControlPresentation: Equatable, Sendable {
    enum State: String, Sendable {
        case off, paused, connecting, ready, controlling, needsAttention
    }

    let state: State
    let message: String
    let activity: DesktopControlActivity?
    let connected: Bool
    let cleanupPending: Bool

    init(enabled: Bool, paused: Bool, connected: Bool, readiness: String,
         sessionMessage: String? = nil, hasError: Bool = false,
         cleanupPending: Bool = false, cleanupFailed: Bool = false,
         environmentSwitchPending: Bool = false, trustedConfiguration: Bool = true,
         activity: DesktopControlActivity? = nil) {
        self.connected = connected
        self.cleanupPending = cleanupPending
        if !trustedConfiguration {
            state = .needsAttention
            message = "Set server URLs to enable Desktop Control"
        } else if environmentSwitchPending {
            state = .needsAttention
            message = "Server change needs attention"
        } else if cleanupFailed {
            state = .needsAttention
            message = "Remote control stopped. Cleanup needs attention."
        } else if cleanupPending {
            state = .paused
            message = "Stopping remote control…"
        } else if hasError {
            state = .needsAttention
            message = "Desktop Control needs attention"
        } else if !enabled {
            state = .off
            message = "Desktop Control is off"
        } else if paused {
            state = .paused
            message = connected ? "Remote control paused. Connection active." : "Remote control paused. Disconnected."
        } else if let sessionMessage {
            state = .needsAttention
            message = sessionMessage
        } else if ["permission_required", "cua_unavailable", "upgrade_required", "locked"].contains(readiness) {
            state = .needsAttention
            switch readiness {
            case "permission_required": message = "Desktop permissions need attention"
            case "upgrade_required": message = "Desktop update required"
            case "locked": message = "Mac is locked"
            default: message = "Desktop control service needs attention"
            }
        } else if !connected || readiness != "ready" {
            state = .connecting
            message = "Connecting to PersonaStack…"
        } else if activity != nil {
            state = .controlling
            message = "Remote control active"
        } else {
            state = .ready
            message = "Ready for remote control"
        }
        self.activity = connected && !paused && !cleanupPending && !cleanupFailed && !environmentSwitchPending
            && trustedConfiguration ? activity : nil
    }

    var symbol: String {
        switch state {
        case .off, .paused: "pause.circle"
        case .connecting: "arrow.triangle.2.circlepath"
        case .ready: "dot.radiowaves.left.and.right"
        case .controlling: "cursorarrow.rays"
        case .needsAttention: "exclamationmark.triangle"
        }
    }
}

/// This local report deliberately has no identity, path, or free-form error fields.
struct DesktopControlDiagnosticReport: Sendable {
    enum Login: String, Sendable { case enabled, disabled, approvalRequired, unavailable }
    enum Session: String, Sendable { case unlocked, locked, unavailable }
    let appVersion: String
    let driverVersion: String
    let state: DesktopControlPresentation.State
    let connected: Bool
    let lastConnection: Date?
    let guiReady: Bool
    let nativeReady: Bool
    let session: Session
    let login: Login
    let reconnectPending: Bool
    let cleanupPending: Bool
    let resources: DesktopControlDiagnostics?
    var accessibilityGranted: Bool? = nil
    var screenCaptureGranted: Bool? = nil
    var serviceRecoveryAttempts = 0
    var serviceRecoveryInProgress = false

    var text: String {
        let last = lastConnection.map { $0.ISO8601Format() } ?? "Not observed"
        let resources = resources.map {
            "Processes: \($0.activeProcesses)\nFile handles: \($0.openFileHandles)\nBuffered bytes: \($0.bufferedOutputBytes)\nOutput gaps: \($0.outputGapsTotal)"
        } ?? "Resource counts: unavailable"
        return """
        PersonaStack diagnostics
        App version: \(Self.versionLabel(appVersion))
        Expected Cua version: \(Self.versionLabel(driverVersion))
        State: \(state.rawValue)
        Cloud connected: \(connected)
        Last successful connection: \(last)
        GUI ready: \(guiReady)
        Native executor ready: \(nativeReady)
        Accessibility permission: \(accessibilityGranted.map(String.init) ?? "Unavailable")
        Screen Recording permission: \(screenCaptureGranted.map(String.init) ?? "Unavailable")
        Session: \(session.rawValue)
        Launch at Login: \(login.rawValue)
        Reconnect pending: \(reconnectPending)
        Service recovery in progress: \(serviceRecoveryInProgress)
        Service recovery attempts: \(max(0, serviceRecoveryAttempts))
        Cleanup pending: \(cleanupPending)
        \(resources)
        """
    }

    private static func versionLabel(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        guard !value.isEmpty, value.utf8.count <= 64,
              value.unicodeScalars.allSatisfy(allowed.contains) else { return "Unavailable" }
        return value
    }
}

@MainActor
final class DesktopControlPresentationStore: ObservableObject {
    static let shared = DesktopControlPresentationStore()
    @Published private(set) var snapshot: DesktopControlPresentation
    private var timer: AnyCancellable?
    private let snapshotProvider: () -> DesktopControlPresentation

    init(snapshotProvider: @escaping () -> DesktopControlPresentation = { DesktopControlRuntime.shared.presentationSnapshot() }) {
        self.snapshotProvider = snapshotProvider
        snapshot = snapshotProvider()
        // This projection drives MenuBarExtra as well as its content. Defer
        // polling during native menu tracking so open submenus stay open.
        timer = Timer.publish(every: 1, on: .main, in: .default).autoconnect().sink { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        let current = snapshotProvider()
        guard current != snapshot else { return }
        snapshot = current
    }
}
