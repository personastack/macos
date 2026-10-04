import AppKit
import Foundation

@MainActor
final class DesktopApplicationRestart {
    static let shared = DesktopApplicationRestart(defaults: .standard)
    // Navigation only. Never resumes a native scope, ticket, or permission grant.
    static let resumesPermissionSetup = shared.consumeResumeHint(arguments: CommandLine.arguments)
    private static let resumeHintKey = "desktop.permissionSetup.resumeUntil"
    private let defaults: UserDefaults?
    private let now: () -> Date
    private var pendingWaiter: Process?
    private let isRunning: (Process) -> Bool
    private let stop: (Process) -> Void

    init(isRunning: @escaping (Process) -> Bool = { $0.isRunning },
         stop: @escaping (Process) -> Void = { $0.terminate() },
         defaults: UserDefaults? = nil, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        self.isRunning = isRunning
        self.stop = stop
    }

    func cancelPendingRestart() {
        defaults?.removeObject(forKey: Self.resumeHintKey)
        _ = defaults?.synchronize()
        stopPendingWaiter()
    }

    private func stopPendingWaiter() {
        guard let waiter = pendingWaiter else { return }
        pendingWaiter = nil
        if isRunning(waiter) { stop(waiter) }
    }
    static let foregroundArgument = "--personastack-permission-relaunch"

    func consumeResumeHint(arguments: [String] = []) -> Bool {
        let expiry = defaults?.double(forKey: Self.resumeHintKey) ?? 0
        defaults?.removeObject(forKey: Self.resumeHintKey)
        _ = defaults?.synchronize()
        let remaining = expiry - now().timeIntervalSince1970
        return arguments.contains(Self.foregroundArgument) || (remaining > 0 && remaining <= 30 * 60)
    }

    static func initialPageURL(_ appURL: URL, resume: Bool) -> URL {
        guard resume, var components = URLComponents(url: appURL, resolvingAgainstBaseURL: false) else { return appURL }
        components.path = "/user/desktop-control"
        components.queryItems = [URLQueryItem(name: "resume_setup", value: "1")]
        components.fragment = nil
        return components.url ?? appURL
    }

    /// Wait for normal application termination before asking LaunchServices to
    /// reopen the bundle. Opening earlier would hit the single-instance guard.
    static func request(applicationURL: URL = Bundle.main.bundleURL,
                        processID: Int32 = ProcessInfo.processInfo.processIdentifier,
                        installUpdate: () throws -> Bool = { try DesktopUpdater.shared.restartForPermissionRepairIfNeeded() },
                        start: (Process) throws -> Void = { try $0.run() },
                        terminate: () -> Void = { NSApp.terminate(nil) }) throws {
        try shared.request(applicationURL: applicationURL, processID: processID,
                           installUpdate: installUpdate, start: start, terminate: terminate)
    }

    func request(applicationURL: URL = Bundle.main.bundleURL,
                 processID: Int32 = ProcessInfo.processInfo.processIdentifier,
                 installUpdate: () throws -> Bool = { try DesktopUpdater.shared.restartForPermissionRepairIfNeeded() },
                 start: (Process) throws -> Void = { try $0.run() },
                 terminate: () -> Void = { NSApp.terminate(nil) }) throws {
        guard applicationURL.isFileURL, applicationURL.pathExtension == "app", processID > 0 else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        defaults?.set(now().addingTimeInterval(30 * 60).timeIntervalSince1970, forKey: Self.resumeHintKey)
        _ = defaults?.synchronize()
        do {
            if try installUpdate() { stopPendingWaiter(); return }
        } catch {
            cancelPendingRestart()
            throw error
        }
        if let waiter = pendingWaiter, isRunning(waiter) { terminate(); return }
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Fixed script, positional arguments only. Never force termination or
        // launch a duplicate when shutdown is cancelled or takes too long.
        waiter.arguments = ["-c", """
        remaining=300
        while /bin/kill -0 "$1" 2>/dev/null; do
            [ "$remaining" -gt 0 ] || exit 1
            /bin/sleep 1
            remaining=$((remaining - 1))
        done
        exec /usr/bin/open -a "$2" --args "$3"
        """, "personastack-restart", String(processID), applicationURL.path, Self.foregroundArgument]
        waiter.standardInput = FileHandle.nullDevice
        waiter.standardOutput = FileHandle.nullDevice
        waiter.standardError = FileHandle.nullDevice
        do { try start(waiter) }
        catch { cancelPendingRestart(); throw error }
        pendingWaiter = waiter
        terminate()
    }
}
