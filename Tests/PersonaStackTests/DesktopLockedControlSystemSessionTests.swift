import Foundation
import Testing
@testable import PersonaStack

@Suite @MainActor
struct DesktopLockedControlSystemSessionTests {
    @Test func displayWakeCannotSubstituteForAnObservedUnlock() async {
        var clock = ContinuousClock.now
        var reads = 0
        let result = await DesktopLockedControlSystemSession.waitFor(.unlocked, timeout: .seconds(1), read: {
            reads += 1
            return .locked
        }, now: { clock }, sleep: { clock += $0 })
        #expect(!result)
        #expect(reads == 10)
    }

    @Test func pollingAcceptsOnlyTheRequestedStateOfTheActiveConsole() async {
        var clock = ContinuousClock.now
        var reads = 0
        let unlocked = await DesktopLockedControlSystemSession.waitFor(.unlocked, read: {
            reads += 1
            return reads > 1 ? .unlocked : .unknown
        }, now: { clock }, sleep: { clock += $0 })
        #expect(unlocked)
        let inactive = await DesktopLockedControlSystemSession.waitFor(.locked, read: { .inactive },
                                                                       sleep: { _ in Issue.record("Inactive console must not keep polling") })
        #expect(!inactive)
    }

    @Test func canceledPollingCannotAuthorizeOrClaimRelock() async {
        let result = await DesktopLockedControlSystemSession.waitFor(.locked, read: { .unlocked },
                                                                       sleep: { _ in throw CancellationError() })
        #expect(!result)
    }
}
