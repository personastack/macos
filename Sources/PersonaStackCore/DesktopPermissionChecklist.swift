import Foundation

public enum DesktopPermissionID: String, CaseIterable, Identifiable, Sendable {
    case accessibility, screenRecording, directCapture, microphone, notifications, launchAtLogin
    case backgroundOperation, localNetwork, desktopFiles, documentsFiles, downloadsFiles
    case removableVolumes, networkVolumes, fullDiskAccess, automation, lockedScreenControl
    case inputMonitoring, automaticUpdates, messagingConnection, awakeDuringRemoteWork
    case camera, speechRecognition, systemAudio, safariJavaScript, clipboard, visualPerception

    public var id: String { rawValue }

    /// Required unattended desktop capabilities. Chat microphone consent is owned
    /// by the recording action, never by remote-control setup.
    public static let setupPermissions: [Self] = [.accessibility, .screenRecording, .directCapture, .fullDiskAccess, .automation, .safariJavaScript, .clipboard, .localNetwork]
    public static let automaticSetup: [Self] = [.launchAtLogin, .automaticUpdates, .awakeDuringRemoteWork, .visualPerception]

    public var title: String {
        Self.titles[self] ?? rawValue
    }

    private static let titles: [Self: String] = [
        .accessibility: "Accessibility", .screenRecording: "Screen Capture", .directCapture: "Direct Capture",
        .microphone: "Microphone", .notifications: "Notifications", .launchAtLogin: "Launch at Login",
        .backgroundOperation: "Background Operation", .localNetwork: "Local Network", .desktopFiles: "Desktop Files",
        .documentsFiles: "Documents Files", .downloadsFiles: "Downloads Files", .removableVolumes: "Removable Volumes",
        .networkVolumes: "Network Volumes", .fullDiskAccess: "Full Disk Access", .automation: "Application Automation",
        .lockedScreenControl: "Locked-Screen Control", .inputMonitoring: "Input Monitoring", .automaticUpdates: "Automatic Updates",
        .messagingConnection: "Messaging Connection", .awakeDuringRemoteWork: "Awake During Remote Work",
        .visualPerception: "Visual Perception", .camera: "Camera", .speechRecognition: "Speech Recognition", .systemAudio: "System Audio", .safariJavaScript: "Safari JavaScript", .clipboard: "Clipboard",
    ]
}

public enum DesktopPermissionState: String, Sendable, CaseIterable {
    case checking, verificationRequired, ready, notGranted, denied, restricted, restartRequired, failed, unsupported, notNeeded

    public var title: String {
        switch self {
        case .checking: "Checking"
        case .verificationRequired: "Needs verification"
        case .ready: "Ready"
        case .notGranted: "Not granted"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .restartRequired: "PersonaStack app restart required"
        case .failed: "Failed"
        case .unsupported: "Unsupported"
        case .notNeeded: "Not needed"
        }
    }

    public var satisfiesSetup: Bool { self == .ready || self == .notNeeded }
}

/// Content-free observations. A key must change when the owner identity,
/// relevant OS grant, environment, or runtime generation changes.
public struct DesktopPermissionObservation: Equatable, Sendable {
    public let state: DesktopPermissionState
    public let detail: String
    public let verificationKey: String?
    public let requiresVerification: Bool
    public let verified: Bool

    public init(_ state: DesktopPermissionState, detail: String,
                verificationKey: String? = nil, requiresVerification: Bool = false,
                verified: Bool = false) {
        self.state = state
        self.detail = detail
        self.verificationKey = verificationKey
        self.requiresVerification = requiresVerification
        self.verified = verified
    }
}

public struct DesktopPermissionRow: Identifiable, Equatable, Sendable {
    public let id: DesktopPermissionID
    public var observation: DesktopPermissionObservation
    public var state: DesktopPermissionState {
        if observation.state == .ready && observation.requiresVerification && !observation.verified { return .verificationRequired }
        return observation.state
    }
    public var isComplete: Bool { state.satisfiesSetup }
    /// Keep the historical property for existing consumers. All unattended
    /// prerequisites now use the same aggregate policy.
    public var isRequiredForUnlockedSetup: Bool {
        DesktopPermissionReadiness.requiredPermissions.contains(id)
    }
    public var displayTitle: String { id.title + (isRequiredForUnlockedSetup ? " (Required)" : "") }
    public var setupTitle: String { "Setup \(id.title)" }

    public init(id: DesktopPermissionID, observation: DesktopPermissionObservation) {
        self.id = id
        self.observation = observation
    }
}

/// The six visible stages. Multiple Apple decisions can belong to one stage.
public enum DesktopPermissionStage: Int, CaseIterable, Identifiable, Sendable {
    case controlApps, shareScreen, filesAndCommands, browsers, clipboard, localNetwork
    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .controlApps: "Control apps"
        case .shareScreen: "Share this screen"
        case .filesAndCommands: "Access files and run commands"
        case .browsers: "Set up browsers"
        case .clipboard: "Use the clipboard"
        case .localNetwork: "Connect to the local network"
        }
    }
    public var permissions: [DesktopPermissionID] {
        switch self {
        case .controlApps: [.accessibility]
        case .shareScreen: [.screenRecording, .directCapture]
        case .filesAndCommands: [.fullDiskAccess]
        case .browsers: [.automation, .safariJavaScript]
        case .clipboard: [.clipboard]
        case .localNetwork: [.localNetwork]
        }
    }
}

/// Pure capability policy. Callers supply current observations; this type never
/// probes an OS service or treats a setup acknowledgement as a macOS grant.
public struct DesktopPermissionReadiness: Equatable, Sendable {
    public static let requirementRevision = 3
    public static let requiredPermissions: [DesktopPermissionID] =
        DesktopPermissionID.setupPermissions + [.launchAtLogin, .awakeDuringRemoteWork, .lockedScreenControl, .visualPerception]
    public let missing: [DesktopPermissionID]
    public var isReady: Bool { missing.isEmpty }

    public init(observations: [DesktopPermissionID: DesktopPermissionObservation]) {
        missing = Self.requiredPermissions.filter { id in
            guard let value = observations[id] else { return true }
            return !DesktopPermissionRow(id: id, observation: value).isComplete
        }
    }
    public init(rows: [DesktopPermissionRow]) {
        self.init(observations: Dictionary(rows.map { ($0.id, $0.observation) }, uniquingKeysWith: { _, last in last }))
    }
}
