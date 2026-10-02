import Darwin
import Foundation
import AppKit

@MainActor
protocol DesktopApplicationActivating {
    var processIdentifier: pid_t { get }
    var activationPolicy: NSApplication.ActivationPolicy { get }
    var isTerminated: Bool { get }
    func activate(options: NSApplication.ActivationOptions) -> Bool
}

extension NSRunningApplication: DesktopApplicationActivating {}

/// Keeps concurrent LaunchServices and supervisor starts from creating two
/// gateway and Cua owners for the same installed application.
@MainActor
final class DesktopApplicationInstanceLock {
    static let shared = DesktopApplicationInstanceLock()

    private let path: String
    private var descriptor: Int32 = -1

    init(path: String? = nil) {
        if let path {
            self.path = path
        } else {
            self.path = FileManager.default.temporaryDirectory
                .appendingPathComponent("ai.personastack.desktop.instance-\(getuid()).lock", isDirectory: false).path
        }
    }

    func acquire() -> Bool {
        guard descriptor < 0 else { return true }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { return false }

        let fd = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return false }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_nlink == 1,
              (metadata.st_mode & (S_IRWXG | S_IRWXO)) == 0,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            return false
        }
        guard fchmod(fd, S_IRUSR | S_IWUSR) == 0 else {
            _ = flock(fd, LOCK_UN)
            Darwin.close(fd)
            return false
        }
        descriptor = fd
        return true
    }

    func release() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }

    /// The second LaunchServices or supervisor launch activates the existing
    /// owner and exits before constructing any app runtime state.
    static func acquireOrActivateExisting(
        lock: DesktopApplicationInstanceLock = shared,
        applications: () -> [any DesktopApplicationActivating] = {
            NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        }
    ) -> Bool {
        guard !lock.acquire() else { return true }
        applications()
            .first {
                $0.processIdentifier != getpid() && !$0.isTerminated && $0.activationPolicy != .prohibited
            }?.activate(options: [.activateAllWindows])
        return false
    }

    deinit {
        if descriptor >= 0 { Darwin.close(descriptor) }
    }
}
