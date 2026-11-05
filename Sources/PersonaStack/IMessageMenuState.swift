import Foundation

/// Local verified state only. Socket presence never means messages are received.
enum IMessageMenuState: Equatable, Sendable, CaseIterable {
    case setupRequired, connecting, connected, paused, syncPending, resumePending, offline, needsAttention
    var statusText: String {
        switch self {
        case .setupRequired: "Not set up"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .paused: "Paused"
        case .syncPending: "Sync pending"
        case .resumePending: "Resume pending"
        case .offline: "Offline"
        case .needsAttention: "Needs attention"
        }
    }
    var offersResume: Bool { [.paused, .syncPending, .resumePending, .offline, .needsAttention].contains(self) }
}
