import AppKit
import Foundation

@MainActor
final class DesktopApplicationRestart {
    static let shared = DesktopApplicationRestart()
    private var pendingWaiter: Process?
    private let isRunning: (Process) -> Bool
    private let stop: (Process) -> Void

    init(isRunning: @escaping (Process) -> Bool = { $0.isRunning },
         stop: @escaping (Process) -> Void = { $0.terminate() }) {
        self.isRunning = isRunning
        self.stop = stop
    }

    func cancelPendingRestart() {
        guard let waiter = pendingWaiter else { return }
        pendingWaiter = nil
        if isRunning(waiter) { stop(waiter) }
    }
    static let foregroundArgument = "--personastack-permission-relaunch"

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
        if try installUpdate() { cancelPendingRestart(); return }
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
        try start(waiter)
        pendingWaiter = waiter
        terminate()
    }
}
