import Foundation

/// Local verified state only. Socket presence never means messages are received.
enum IMessageMenuState: Equatable, Sendable, CaseIterable {
    case setupRequired, connecting, connected, paused, offline, needsAttention
    var statusText: String {
        switch self {
        case .setupRequired: "Not set up"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .paused: "Paused"
        case .offline: "Offline"
        case .needsAttention: "Needs attention"
        }
    }
    var offersResume: Bool { self == .paused || self == .offline || self == .needsAttention }
}
