import Foundation
import Testing
@testable import PersonaStack

@Test func cuaDaemonRecoveryBackoffIsBoundedAndUsesCooldowns() {
    var backoff = CuaDaemonRecoveryBackoff()
    let start = Date(timeIntervalSince1970: 1_000)

    let firstAttempt = backoff.beginAttempt(at: start)
    #expect(firstAttempt)
    backoff.recordFailure(at: start)
    let earlySecondAttempt = backoff.beginAttempt(at: start.addingTimeInterval(1.9))
    #expect(!earlySecondAttempt)
    let secondAttempt = backoff.beginAttempt(at: start.addingTimeInterval(2))
    #expect(secondAttempt)
    backoff.recordFailure(at: start.addingTimeInterval(2))
    let earlyThirdAttempt = backoff.beginAttempt(at: start.addingTimeInterval(6.9))
    #expect(!earlyThirdAttempt)
    let thirdAttempt = backoff.beginAttempt(at: start.addingTimeInterval(7))
    #expect(thirdAttempt)
    backoff.recordFailure(at: start.addingTimeInterval(7))
    let afterLimit = backoff.beginAttempt(at: start.addingTimeInterval(100))
    #expect(!afterLimit)

    backoff.reset()
    #expect(backoff.attemptCount == 0)
    let resetAttempt = backoff.beginAttempt(at: start.addingTimeInterval(100))
    #expect(resetAttempt)
}

@Test func cuaDaemonRecoveryEligibilityPreservesRelayAndSessionFences() {
    func makeEligibility(
        automaticRecoveryAllowed: Bool = true,
        relayActive: Bool = true,
        ownedDaemonExited: Bool = true,
        paused: Bool = false,
        sessionAvailable: Bool = true,
        disconnecting: Bool = false,
        environmentSwitchPending: Bool = false,
        repairInProgress: Bool = false,
        executorCleanupPending: Bool = false,
        setupMayRunUnconfigured: Bool = false,
        qualifiedLockedSession: Bool = false,
        supervisorOwnsDaemon: Bool = false
    ) -> CuaDaemonRecoveryEligibility {
        CuaDaemonRecoveryEligibility(
            automaticRecoveryAllowed: automaticRecoveryAllowed,
            relayActive: relayActive,
            ownedDaemonExited: ownedDaemonExited,
            paused: paused,
            sessionAvailable: sessionAvailable,
            disconnecting: disconnecting,
            environmentSwitchPending: environmentSwitchPending,
            repairInProgress: repairInProgress,
            executorCleanupPending: executorCleanupPending,
            setupMayRunUnconfigured: setupMayRunUnconfigured,
            qualifiedLockedSession: qualifiedLockedSession,
            supervisorOwnsDaemon: supervisorOwnsDaemon
        )
    }

    #expect(makeEligibility().shouldRecover)
    #expect(!makeEligibility(automaticRecoveryAllowed: false).shouldRecover)
    #expect(!makeEligibility(relayActive: false).shouldRecover)
    #expect(!makeEligibility(ownedDaemonExited: false).shouldRecover)
    #expect(!makeEligibility(paused: true).shouldRecover)
    #expect(!makeEligibility(sessionAvailable: false).shouldRecover)
    #expect(!makeEligibility(disconnecting: true).shouldRecover)
    #expect(!makeEligibility(environmentSwitchPending: true).shouldRecover)
    #expect(!makeEligibility(repairInProgress: true).shouldRecover)
    #expect(!makeEligibility(executorCleanupPending: true).shouldRecover)
    #expect(!makeEligibility(setupMayRunUnconfigured: true).shouldRecover)
    #expect(!makeEligibility(sessionAvailable: false).shouldRecover)
    #expect(makeEligibility(sessionAvailable: false, qualifiedLockedSession: true).shouldRecover)
    #expect(!makeEligibility(sessionAvailable: false, qualifiedLockedSession: true,
                             supervisorOwnsDaemon: true).shouldRecover)
    #expect(!makeEligibility(sessionAvailable: false, qualifiedLockedSession: false,
                             supervisorOwnsDaemon: false).shouldRecover)
    #expect(!makeEligibility(paused: true, sessionAvailable: false,
                             qualifiedLockedSession: true).shouldRecover)
    #expect(!makeEligibility(relayActive: false, sessionAvailable: false,
                             qualifiedLockedSession: true).shouldRecover)
    #expect(!makeEligibility(ownedDaemonExited: false, sessionAvailable: false,
                             qualifiedLockedSession: true).shouldRecover)
    #expect(!makeEligibility(sessionAvailable: false, executorCleanupPending: true,
                             qualifiedLockedSession: true).shouldRecover)
}

@Test func cuaDaemonRecoveryDoesNotResetItsBudgetForACrashLoop() {
    var backoff = CuaDaemonRecoveryBackoff()
    let start = Date(timeIntervalSince1970: 1_000)
    let first = backoff.beginAttempt(at: start)
    #expect(first)
    backoff.recordSuccess(at: start)
    let immediate = backoff.beginAttempt(at: start.addingTimeInterval(1))
    #expect(!immediate)
    let second = backoff.beginAttempt(at: start.addingTimeInterval(2))
    #expect(second)
    backoff.recordSuccess(at: start.addingTimeInterval(2))
    let third = backoff.beginAttempt(at: start.addingTimeInterval(7))
    #expect(third)
    backoff.recordSuccess(at: start.addingTimeInterval(7))
    let capped = backoff.beginAttempt(at: start.addingTimeInterval(30))
    #expect(!capped)
    let afterStableRuntime = backoff.beginAttempt(at: start.addingTimeInterval(127))
    #expect(afterStableRuntime)
    #expect(backoff.attemptCount == 1)
}
