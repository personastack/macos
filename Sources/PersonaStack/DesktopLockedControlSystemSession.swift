import CoreGraphics
import Foundation
import IOKit.pwr_mgt

/// OS actions for the locked-control candidate. Nothing invokes these at app
/// startup. Display wake is only a trigger, never authorization or unlock proof.
@MainActor
enum DesktopLockedControlSystemSession {
    enum Failure: Error { case wakeUnavailable, inputUnavailable }

    static func requestDisplayWake() throws {
        var assertion: IOPMAssertionID = 0
        let result = IOPMAssertionDeclareUserActivity("PersonaStack authorized remote task" as CFString,
                                                     kIOPMUserActiveLocal, &assertion)
        guard result == kIOReturnSuccess else { throw Failure.wakeUnavailable }
        if assertion != 0 { _ = IOPMAssertionRelease(assertion) }
    }

    static func restoreLock() async -> Bool {
        let snapshot = DesktopControlSessionLock.currentSnapshot()
        if snapshot == .locked { return true }
        guard snapshot == .unlocked, CGPreflightPostEventAccess(),
              let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: false) else { return false }
        // Apple's built-in Control-Command-Q action. This registers no global
        // shortcut and does not change the user's keyboard or lock preferences.
        down.flags = [.maskControl, .maskCommand]
        up.flags = [.maskControl, .maskCommand]
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return await waitFor(.locked)
    }

    static func waitFor(_ wanted: DesktopControlSessionLock.Snapshot,
                        timeout: Duration = .seconds(10),
                        read: @MainActor () -> DesktopControlSessionLock.Snapshot = DesktopControlSessionLock.currentSnapshot,
                        now: @MainActor () -> ContinuousClock.Instant = { .now },
                        sleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async -> Bool {
        guard wanted == .locked || wanted == .unlocked, timeout > .zero else { return false }
        let deadline = now() + timeout
        while !Task.isCancelled, now() < deadline {
            let current = read()
            if current == wanted { return true }
            if current == .inactive { return false }
            do { try await sleep(.milliseconds(100)) }
            catch { return false }
        }
        return false
    }
}
