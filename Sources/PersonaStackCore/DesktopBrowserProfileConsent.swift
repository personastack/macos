import Foundation

/// A live browser window, independently observed by the native host. The process
/// launch and code identity fence PID/window reuse. CUA attests the profile and
/// endpoint behind this exact target before attachment. Local approval covers
/// all windows and authenticated profiles of this live browser instance.
public struct DesktopBrowserConsentTarget: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let pid: Int32
    public let windowID: UInt32
    public let bundleIdentifier: String
    public let launchedAt: Date
    public let codeIdentity: String

    public var instanceIdentity: String { "\(bundleIdentifier):\(pid):\(launchedAt.timeIntervalSinceReferenceDate):\(codeIdentity)" }
    public var id: String { "\(pid):\(windowID):\(launchedAt.timeIntervalSinceReferenceDate):\(codeIdentity)" }
    public var browserName: String {
        bundleIdentifier == "com.google.Chrome" ? "Google Chrome" : "Microsoft Edge"
    }
    public var isSupported: Bool {
        pid > 0 && windowID > 0 && !codeIdentity.isEmpty &&
        ["com.google.Chrome", "com.microsoft.edgemac"].contains(bundleIdentifier)
    }

    public init(pid: Int32, windowID: UInt32, bundleIdentifier: String, launchedAt: Date, codeIdentity: String) {
        self.pid = pid
        self.windowID = windowID
        self.bundleIdentifier = bundleIdentifier
        self.launchedAt = launchedAt
        self.codeIdentity = codeIdentity
    }
}

/// Local consent only. Neither CUA arguments nor a persona's confirm flag can
/// write this state. Each effect must supply a fresh native target observation.
public struct DesktopBrowserProfileConsent: Sendable {
    public private(set) var approvedTargets: Set<DesktopBrowserConsentTarget> = []

    public init() {}

    public mutating func approveSelection(_ selected: Set<DesktopBrowserConsentTarget>, current: [DesktopBrowserConsentTarget]) {
        // A changed or disappeared target between presentation and Continue
        // requires a new explicit selection. Never replace it with another PID.
        approvedTargets = selected.intersection(Set(current.filter(\.isSupported)))
    }

    public mutating func restore(_ recorded: Set<DesktopBrowserConsentTarget>, current: [DesktopBrowserConsentTarget]) {
        approvedTargets = Set(recorded.filter(\.isSupported))
        refresh(current: current)
    }

    public mutating func refresh(current: [DesktopBrowserConsentTarget]) {
        approvedTargets = approvedTargets.filter { anchor in
            current.contains { $0.isSupported && sameInstance(anchor, $0) }
        }
    }

    public func allows(pid: Int32, windowID: UInt32, current: [DesktopBrowserConsentTarget]) -> Bool {
        let matches = current.filter { $0.pid == pid && $0.windowID == windowID && $0.isSupported }
        guard matches.count == 1, let target = matches.first else { return false }
        return approvedTargets.contains { anchor in
            sameInstance(anchor, target)
        }
    }

    public mutating func revokeAll() { approvedTargets.removeAll() }

    private func sameInstance(_ first: DesktopBrowserConsentTarget, _ second: DesktopBrowserConsentTarget) -> Bool {
        first.pid == second.pid && first.bundleIdentifier == second.bundleIdentifier &&
        first.launchedAt == second.launchedAt && first.codeIdentity == second.codeIdentity
    }
}
