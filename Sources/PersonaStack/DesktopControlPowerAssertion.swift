import Foundation
import IOKit.pwr_mgt

/// One process-owned assertion for the existing exclusive control lease.
/// It prevents idle system sleep, without changing display or global sleep policy.
final class DesktopControlPowerAssertion: @unchecked Sendable {
    private let lock = NSLock()
    private var assertionID: IOPMAssertionID?
    private let create: @Sendable () -> IOPMAssertionID?
    private let release: @Sendable (IOPMAssertionID) -> Bool

    init(create: @escaping @Sendable () -> IOPMAssertionID? = {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "PersonaStack remote desktop task" as CFString, &id
        )
        return result == kIOReturnSuccess && id != 0 ? id : nil
    }, release: @escaping @Sendable (IOPMAssertionID) -> Bool = {
        IOPMAssertionRelease($0) == kIOReturnSuccess
    }) {
        self.create = create
        self.release = release
    }

    deinit {
        if let assertionID { _ = release(assertionID) }
    }

    var isHeld: Bool { lock.withLock { assertionID != nil } }

    func acquire() -> Bool {
        lock.withLock {
            if assertionID != nil { return true }
            guard let id = create(), id != 0 else { return false }
            assertionID = id
            return true
        }
    }

    @discardableResult
    func relinquish() -> Bool {
        lock.withLock {
            guard let id = assertionID else { return true }
            guard release(id) else { return false }
            assertionID = nil
            return true
        }
    }

    /// An explicit checklist action owns a separate short-lived assertion.
    /// It cannot release the assertion belonging to a concurrent remote task.
    static func verifyAvailability(makeAssertion: () -> DesktopControlPowerAssertion = { .init() }) -> Bool {
        let assertion = makeAssertion()
        return assertion.acquire() && assertion.relinquish()
    }
}
