import AppKit
import Foundation
import PersonaStackCore
import WebKit

/// WebKit keeps credential custody. Native lifecycle events request the hosted
/// bootstrap, which renews the existing API session and its HttpOnly cookie.
@MainActor
final class DesktopSessionRefresh {
    private let appURL: URL
    private let currentURL: () -> URL?
    private let evaluate: (String) async throws -> Void
    private let applicationNotifications: NotificationCenter
    private let workspaceNotifications: NotificationCenter
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var request: Task<Void, Never>?
    private var stopped = false

    init(appURL: URL, currentURL: @escaping () -> URL?,
         applicationNotifications: NotificationCenter = .default,
         workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
         evaluate: @escaping (String) async throws -> Void) {
        self.appURL = appURL
        self.currentURL = currentURL
        self.evaluate = evaluate
        self.applicationNotifications = applicationNotifications
        self.workspaceNotifications = workspaceNotifications
    }

    func start() {
        guard timer == nil, !stopped else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        observe(workspaceNotifications, name: NSWorkspace.didWakeNotification)
        observe(applicationNotifications, name: NSApplication.didBecomeActiveNotification)
    }

    func refresh() {
        guard !stopped, request == nil, let url = currentURL(),
              ChatWindowCommand.sameOrigin(url, appURL),
              Self.isAuthenticatedPage(url.path), let script = Self.script(appURL: appURL) else { return }
        request = Task { [weak self] in
            guard let self else { return }
            defer { self.request = nil }
            // Network loss and unavailable authority retain the cookie. The
            // next timer, activation, wake or completed load retries naturally.
            try? await self.evaluate(script)
        }
    }

    func stop() {
        stopped = true
        timer?.invalidate()
        timer = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        request?.cancel()
        request = nil
    }

    private func observe(_ center: NotificationCenter, name: Notification.Name) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        observers.append((center, observer))
    }

    private static func isAuthenticatedPage(_ path: String) -> Bool {
        ["/user", "/admin", "/profile", "/workspace", "/org"].contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    static func script(appURL: URL) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let origin = try? DesktopControlEnvironment.origin(appURL),
              let encoded = try? encoder.encode(origin),
              let literal = String(data: encoded, encoding: .utf8) else { return nil }
        return """
        if (location.origin !== \(literal)) return;
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), 15000);
        try {
          await fetch('/user/mobile/bootstrap', {
            method: 'GET', credentials: 'same-origin', cache: 'no-store', redirect: 'error',
            signal: controller.signal
          });
        } finally {
          clearTimeout(timeout);
        }
        """
    }
}
