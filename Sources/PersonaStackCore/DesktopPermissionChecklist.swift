import Foundation

public enum DesktopPermissionID: String, CaseIterable, Identifiable, Sendable {
    case accessibility, screenRecording, directCapture, microphone, notifications, launchAtLogin
    case backgroundOperation, localNetwork, desktopFiles, documentsFiles, downloadsFiles
    case removableVolumes, networkVolumes, fullDiskAccess, automation, lockedScreenControl
    case inputMonitoring, automaticUpdates, messagingConnection, awakeDuringRemoteWork
    case camera, speechRecognition, systemAudio

    public var id: String { rawValue }

    public var title: String {
        Self.titles[self] ?? rawValue
    }

    private static let titles: [Self: String] = [
        .accessibility: "Accessibility", .screenRecording: "Screen Recording", .directCapture: "Direct Capture",
        .microphone: "Microphone", .notifications: "Notifications", .launchAtLogin: "Launch at Login",
        .backgroundOperation: "Background Operation", .localNetwork: "Local Network", .desktopFiles: "Desktop Files",
        .documentsFiles: "Documents Files", .downloadsFiles: "Downloads Files", .removableVolumes: "Removable Volumes",
        .networkVolumes: "Network Volumes", .fullDiskAccess: "Full Disk Access", .automation: "Application Automation",
        .lockedScreenControl: "Locked-Screen Control", .inputMonitoring: "Input Monitoring", .automaticUpdates: "Automatic Updates",
        .messagingConnection: "Messaging Connection", .awakeDuringRemoteWork: "Awake During Remote Work",
        .camera: "Camera", .speechRecognition: "Speech Recognition", .systemAudio: "System Audio",
    ]
}

public enum DesktopPermissionState: String, Sendable, CaseIterable {
    case checking, ready, notGranted, denied, restricted, restartRequired, failed, unsupported, notNeeded

    public var title: String {
        switch self {
        case .checking: "Checking"
        case .ready: "Ready"
        case .notGranted: "Not granted"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .restartRequired: "Restart required"
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
        if observation.state == .ready && observation.requiresVerification && !observation.verified { return .checking }
        return observation.state
    }
    public var isComplete: Bool { state.satisfiesSetup }
    /// This release enrolls unlocked control. Unqualified full-access rows stay
    /// visible with their real state and cannot be mistaken for granted access.
    public var isRequiredForUnlockedSetup: Bool {
        id != .lockedScreenControl && id != .fullDiskAccess
    }
    public var setupTitle: String { "Setup \(id.title)" }

    public init(id: DesktopPermissionID, observation: DesktopPermissionObservation) {
        self.id = id
        self.observation = observation
    }
}
