import CryptoKit
import CoreFoundation
import Darwin
import Foundation
import PersonaStackCore

/// Cached, read-only evidence that the locked-session authorization candidate
/// is installed for this signed app. Construction performs no system reads.
@MainActor
final class DesktopLockedControlSetupVerifier {
    static let shared = DesktopLockedControlSetupVerifier()

    enum Readiness: Equatable, Sendable {
        case absent
        case mismatch
        case ready
    }

    struct Snapshot: Equatable, Sendable {
        let readiness: Readiness
        let detail: String

        nonisolated static let absent = Snapshot(readiness: .absent,
            detail: "Locked-screen control is not installed on this Mac.")
        nonisolated static let mismatch = Snapshot(readiness: .mismatch,
            detail: "The installed locked-screen control policy could not be verified.")
        nonisolated static let ready = Snapshot(readiness: .ready,
            detail: "The installed locked-screen control policy matches this PersonaStack build.")
    }

    struct Operations: Sendable {
        var inspect: @MainActor @Sendable () async -> Snapshot

        static let production = Operations(inspect: {
            await Task.detached(priority: .utility) {
                DesktopLockedControlSetupVerifier.inspectInstalledCandidate()
            }.value
        })
    }

    private(set) var snapshot = Snapshot.absent
    var onChange: (@MainActor () -> Void)?

    private let defaults: UserDefaults
    private let operations: Operations
    private var refreshTask: Task<Snapshot, Never>?

    /// Cached eligibility is synchronous for command-admission paths. Call
    /// `refresh()` from explicit setup or bounded lifecycle maintenance.
    var permitsLockedControl: Bool {
        snapshot.readiness == .ready && DesktopLockedControlAcknowledgement.isAccepted(defaults: defaults)
    }

    init(defaults: UserDefaults = .standard, operations: Operations = .production) {
        self.defaults = defaults
        self.operations = operations
    }

    @discardableResult
    func refresh() async -> Snapshot {
        if let refreshTask { return await refreshTask.value }
        let operations = self.operations
        let task = Task { @MainActor [weak self] in
            let value = await operations.inspect()
            guard let self else { return value }
            self.snapshot = value
            self.onChange?()
            self.refreshTask = nil
            return value
        }
        refreshTask = task
        return await task.value
    }

    /// Persists acknowledgement only after the read-only installed-policy
    /// verifier reports Ready. This is consent evidence, not an enable switch.
    @discardableResult
    func recordAcknowledgement() -> Bool {
        guard snapshot.readiness == .ready else { return false }
        DesktopLockedControlAcknowledgement.record(defaults: defaults)
        onChange?()
        return true
    }

    nonisolated static let candidateBundleIdentifier = DesktopLockedControlPolicy.right
    nonisolated static let candidateRight = DesktopLockedControlPolicy.right
    nonisolated static let candidateMechanism = DesktopLockedControlPolicy.mechanism
    nonisolated static let candidateBundlePath = DesktopLockedControlPolicy.bundlePath
    nonisolated static let policyEvidencePath = DesktopLockedControlPolicy.receiptPath
    nonisolated static let screensaverRight = DesktopLockedControlPolicy.screensaverRight

    /// Pure policy evidence parser. The root-owned receipt at
    /// `policyEvidencePath` is a plist with `version` (1), `right` (the owned
    /// right name), and `manualFallbacks` (the original manual-authentication
    /// delegate names in their original order). The installer must take those
    /// names from the rule it just read before installing our branch. This
    /// parser requires exactly the reviewed delegates. Later operator changes
    /// remain untouched but do not qualify automatically. The installer uses
    /// the same Core policy contract.
    nonisolated static func policyEvidenceMatches(ownedRight: Data, screensaverPolicy: Data,
                                                 baselineReceipt: Data) -> Bool {
        guard let leaf = DesktopLockedControlPolicy.decode(ownedRight),
              let policy = DesktopLockedControlPolicy.decode(screensaverPolicy),
              let receipt = DesktopLockedControlPolicy.decode(baselineReceipt) else { return false }
        return DesktopLockedControlPolicy.matches(leaf: leaf, policy: policy, receipt: receipt)
    }

    nonisolated private static func inspectInstalledCandidate() -> Snapshot {
        let bundleURL = URL(fileURLWithPath: candidateBundlePath, isDirectory: true)
        var metadata = stat()
        guard lstat(bundleURL.path, &metadata) == 0 else {
            return errno == ENOENT ? .absent : .mismatch
        }
        guard validateInstalledBundle(bundleURL), validatePolicyEvidence() else { return .mismatch }
        return .ready
    }

    nonisolated private static func validateInstalledBundle(_ bundleURL: URL) -> Bool {
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let infoURL = contents.appendingPathComponent("Info.plist")
        guard validateProtectedPath(bundleURL, expectedDirectory: true),
              validateProtectedPath(contents, expectedDirectory: true),
              validateProtectedPath(infoURL, expectedDirectory: false),
              let infoData = try? Data(contentsOf: infoURL, options: .mappedIfSafe),
              let infoValue = try? PropertyListSerialization.propertyList(from: infoData, options: [], format: nil),
              let info = infoValue as? [String: Any],
              info["CFBundleIdentifier"] as? String == candidateBundleIdentifier,
              info["CFBundleExecutable"] as? String == "AuthorizationGrantPlugin" else { return false }

        let executable = contents.appendingPathComponent("MacOS/AuthorizationGrantPlugin")
        let embeddedPin = contents.appendingPathComponent("Resources/ReleaseSigningCertificate.der")
        guard validateProtectedPath(contents.appendingPathComponent("MacOS", isDirectory: true),
                                    expectedDirectory: true),
              validateProtectedPath(executable, expectedDirectory: false),
              validateProtectedPath(contents.appendingPathComponent("Resources", isDirectory: true),
                                    expectedDirectory: true),
              validateProtectedPath(embeddedPin, expectedDirectory: false),
              let appPinURL = Bundle.main.url(forResource: "ReleaseSigningCertificate", withExtension: "der"),
              let appPin = try? Data(contentsOf: appPinURL),
              let candidatePin = try? Data(contentsOf: embeddedPin), candidatePin == appPin,
              isExecutable(executable),
              hasPinnedCodeSignature(bundleURL, pin: appPin) else { return false }
        return true
    }

    nonisolated private static func isExecutable(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & mode_t(S_IXUSR | S_IXGRP | S_IXOTH)) != 0
    }

    nonisolated private static func validatePolicyEvidence() -> Bool {
        let receiptURL = URL(fileURLWithPath: policyEvidencePath)
        guard validateProtectedPath(receiptURL, expectedDirectory: false),
              let receipt = try? Data(contentsOf: receiptURL, options: .mappedIfSafe),
              receipt.count <= 64 * 1024,
              let ownedRight = readAuthorizationRight(candidateRight),
              let screensaver = readAuthorizationRight(screensaverRight),
              ownedRight.count <= 1024 * 1024, screensaver.count <= 1024 * 1024 else { return false }
        return policyEvidenceMatches(ownedRight: ownedRight, screensaverPolicy: screensaver,
                                     baselineReceipt: receipt)
    }

    nonisolated private static func hasPinnedCodeSignature(_ bundleURL: URL, pin: Data) -> Bool {
        return runReadOnlyProcess(URL(fileURLWithPath: "/usr/bin/codesign"),
            pinnedCodeSignatureArguments(bundleURL, pin: pin), timeoutNanoseconds: 2_000_000_000) != nil
    }

    nonisolated static func pinnedCodeSignatureArguments(_ bundleURL: URL, pin: Data) -> [String] {
        let digest = Insecure.SHA1.hash(data: pin).map { String(format: "%02x", $0) }.joined()
        // codesign treats requirements without the leading '=' as filenames.
        let requirement = "=identifier \"\(candidateBundleIdentifier)\" and certificate leaf = H\"\(digest)\""
        return ["--verify", "--strict", "--deep", "-R", requirement, bundleURL.path]
    }

    nonisolated private static func readAuthorizationRight(_ right: String) -> Data? {
        runReadOnlyProcess(URL(fileURLWithPath: "/usr/bin/security"),
            ["authorizationdb", "read", right], timeoutNanoseconds: 5_000_000_000)
    }

    /// The invoked commands are fixed read-only system tools with fixed
    /// arguments. Output is capped to avoid unbounded policy reads.
    nonisolated private static func runReadOnlyProcess(_ executable: URL, _ arguments: [String],
                                                       timeoutNanoseconds: UInt64) -> Data? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let handle = pipe.fileHandleForReading
        pipe.fileHandleForWriting.closeFile()
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            terminate(process)
            handle.closeFile()
            return nil
        }
        let start = DispatchTime.now().uptimeNanoseconds
        guard start <= UInt64.max - timeoutNanoseconds else {
            terminate(process)
            handle.closeFile()
            return nil
        }
        let deadline = start + timeoutNanoseconds
        var output = Data()
        var reachedEOF = false
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                terminate(process)
                handle.closeFile()
                return nil
            }

            var readiness = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            let remainingMilliseconds = Int32(min((deadline - now + 999_999) / 1_000_000, 100))
            let pollResult = poll(&readiness, 1, remainingMilliseconds)
            if pollResult < 0 {
                if errno == EINTR { continue }
                terminate(process)
                handle.closeFile()
                return nil
            }
            if pollResult > 0 {
                var buffer = [UInt8](repeating: 0, count: 32 * 1024)
                while true {
                    let amount = buffer.withUnsafeMutableBytes { bytes in
                        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
                    }
                    if amount > 0 {
                        let bytes = Int(amount)
                        guard output.count <= 1024 * 1024 - bytes else {
                            terminate(process)
                            handle.closeFile()
                            return nil
                        }
                        output.append(contentsOf: buffer.prefix(bytes))
                        continue
                    }
                    if amount == 0 { reachedEOF = true; break }
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { break }
                    terminate(process)
                    handle.closeFile()
                    return nil
                }
            }

            if reachedEOF {
                if !process.isRunning { break }
                var noDescriptors = pollfd(fd: -1, events: 0, revents: 0)
                _ = poll(&noDescriptors, 0, 10)
            }
        }
        process.waitUntilExit()
        handle.closeFile()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return output
    }

    nonisolated private static func terminate(_ process: Process) {
        let pid = process.processIdentifier
        guard process.isRunning, pid > 0 else { return }
        process.terminate()
        let graceDeadline = DispatchTime.now().uptimeNanoseconds + 200_000_000
        while process.isRunning && DispatchTime.now().uptimeNanoseconds < graceDeadline {
            var noDescriptors = pollfd(fd: -1, events: 0, revents: 0)
            _ = poll(&noDescriptors, 0, 10)
        }
        if process.isRunning { _ = kill(pid, SIGKILL) }
        let killDeadline = DispatchTime.now().uptimeNanoseconds + 500_000_000
        while process.isRunning && DispatchTime.now().uptimeNanoseconds < killDeadline {
            var noDescriptors = pollfd(fd: -1, events: 0, revents: 0)
            _ = poll(&noDescriptors, 0, 10)
        }
    }

    nonisolated private static func validateProtectedPath(_ url: URL, expectedDirectory: Bool) -> Bool {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix("/") else { return false }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        let components = path.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            current.appendPathComponent(component)
            var info = stat()
            guard lstat(current.path, &info) == 0,
                  (info.st_mode & mode_t(S_IFMT)) != mode_t(S_IFLNK), info.st_uid == 0,
                  (info.st_mode & mode_t(S_IWGRP | S_IWOTH)) == 0 else { return false }
            let isFinal = index == components.count - 1
            if !isFinal || expectedDirectory {
                guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { return false }
            } else {
                guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return false }
            }
        }
        return true
    }


}

/// Local acknowledgement of the updated full-control behavior. This value
/// records informed setup only; relayEnabled remains the sole enable choice.
enum DesktopLockedControlAcknowledgement {
    static let currentVersion = 1
    static let defaultsKey = "desktopControl.lockedControlAcknowledgementVersion"

    static func isAccepted(defaults: UserDefaults) -> Bool {
        defaults.integer(forKey: defaultsKey) == currentVersion
    }

    static func record(defaults: UserDefaults) {
        defaults.set(currentVersion, forKey: defaultsKey)
    }

    static func clear(defaults: UserDefaults) {
        defaults.removeObject(forKey: defaultsKey)
    }
}
