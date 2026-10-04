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
    private static let probeQueue = DispatchQueue(label: "ai.personastack.clipboard-permission")
    private static var pendingProbe: Task<Void, Never>?

    static func request() async {
        guard #available(macOS 15.4, *) else { return }
        if let pendingProbe { await pendingProbe.value; return }
        let task = Task {
            await runDiscardedProbe {
                // Confine this pasteboard and its discarded data to one worker.
                // The main actor must remain available while macOS asks consent.
                autoreleasepool { _ = NSPasteboard(name: .general).data(forType: .string) }
            }
        }
        pendingProbe = task
        await task.value
        pendingProbe = nil
    }

    static func runDiscardedProbe(_ read: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { continuation in
            probeQueue.async {
                read()
                continuation.resume()
            }
        }
    }
}
