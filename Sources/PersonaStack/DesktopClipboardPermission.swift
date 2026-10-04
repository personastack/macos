import AppKit

enum DesktopClipboardAccess: Equatable, Sendable {
    case notNeeded, notDetermined, ask, allowed, denied, unknown
}

@MainActor
enum DesktopClipboardPermission {
    /// This property does not read clipboard contents or trigger consent.
    static func status() -> DesktopClipboardAccess {
        guard #available(macOS 15.4, *) else { return .notNeeded }
        switch NSPasteboard.general.accessBehavior {
        case .default: return .notDetermined
        case .ask: return .ask
        case .alwaysAllow: return .allowed
        case .alwaysDeny: return .denied
        @unknown default: return .unknown
        }
    }

    /// macOS has no separate request API. Explicit Setup can attempt a read
    /// to register its consent alert. Do not retain, display or transmit data.
    static func request() {
        guard #available(macOS 15.4, *) else { return }
        _ = NSPasteboard.general.data(forType: .string)
    }
}
