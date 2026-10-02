import Foundation
import AppKit
@testable import PersonaStack
import Testing

@MainActor
private final class ActivationCandidate: DesktopApplicationActivating {
    let processIdentifier: pid_t
    let activationPolicy: NSApplication.ActivationPolicy
    let isTerminated: Bool
    var activationCount = 0

    init(_ pid: pid_t, policy: NSApplication.ActivationPolicy, terminated: Bool = false) {
        processIdentifier = pid
        activationPolicy = policy
        isTerminated = terminated
    }

    func activate(options: NSApplication.ActivationOptions) -> Bool {
        #expect(options == [.activateAllWindows])
        activationCount += 1
        return true
    }
}

@Suite @MainActor
struct DesktopApplicationInstanceLockTests {
    @Test(arguments: [NSApplication.ActivationPolicy.regular, .accessory])
    func duplicateLaunchActivatesTheAppInsteadOfItsSupervisor(policy: NSApplication.ActivationPolicy) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesktopApplicationInstanceLockTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("owner.lock").path
        let owner = DesktopApplicationInstanceLock(path: path)
        let duplicate = DesktopApplicationInstanceLock(path: path)
        #expect(owner.acquire())
        defer { owner.release() }
        let supervisor = ActivationCandidate(getpid() + 1, policy: .prohibited)
        let exited = ActivationCandidate(getpid() + 2, policy: .regular, terminated: true)
        let current = ActivationCandidate(getpid(), policy: .regular)
        let app = ActivationCandidate(getpid() + 3, policy: policy)

        #expect(!DesktopApplicationInstanceLock.acquireOrActivateExisting(
            lock: duplicate, applications: { [supervisor, exited, current, app] }))

        #expect(supervisor.activationCount == 0)
        #expect(exited.activationCount == 0)
        #expect(current.activationCount == 0)
        #expect(app.activationCount == 1)
    }

    @Test func onlyOneProcessOwnsTheApplicationLock() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesktopApplicationInstanceLockTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("owner.lock").path
        let first = DesktopApplicationInstanceLock(path: path)
        let second = DesktopApplicationInstanceLock(path: path)

        #expect(first.acquire())
        #expect(!second.acquire())
        first.release()
        #expect(second.acquire())
        second.release()
    }

    @Test func unsafeLockFileIsRejected() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesktopApplicationInstanceLockTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("target")
        let path = directory.appendingPathComponent("owner.lock")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)

        #expect(!DesktopApplicationInstanceLock(path: path.path).acquire())
    }
}
