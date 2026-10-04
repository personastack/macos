import Foundation
import Testing
import dnssd
@testable import PersonaStack

@MainActor
private final class LocalNetworkRegistrationFixture: DesktopLocalNetworkRegistering {
    var immediateError: Int32 = Int32(kDNSServiceErr_NoError)
    var starts = 0
    var cancellations = 0
    var callback: (@MainActor (Int32, Bool) -> Void)?
    func start(reply: @escaping @MainActor (Int32, Bool) -> Void) -> Int32 {
        starts += 1
        callback = reply
        return immediateError
    }
    func cancel() { cancellations += 1 }
    func emit(_ error: Int32 = Int32(kDNSServiceErr_NoError), added: Bool = true) { callback?(error, added) }
}

@MainActor
struct DesktopLocalNetworkPermissionTests {
    private func waitForStart(_ fixture: LocalNetworkRegistrationFixture) async {
        for _ in 0..<1_000 {
            if fixture.starts > 0 { return }
            await Task.yield()
        }
        Issue.record("Registration did not start")
    }

    @Test func successfulSubmissionAndRemoveCallbackDoNotProveGrant() async {
        let fixture = LocalNetworkRegistrationFixture()
        let task = Task { await DesktopLocalNetworkPermission.request(registration: fixture) }
        await waitForStart(fixture)
        #expect(fixture.cancellations == 0)
        fixture.emit(added: false)
        #expect(fixture.cancellations == 0)
        fixture.emit()
        let observation = await task.value
        #expect(observation.state == .ready)
        #expect(observation.verified)
        #expect(fixture.cancellations == 1)
        fixture.emit(Int32(kDNSServiceErr_PolicyDenied))
        #expect(fixture.cancellations == 1)
    }

    @Test(arguments: [Int32(kDNSServiceErr_PolicyDenied), Int32(kDNSServiceErr_Unknown)])
    func asynchronousFailureDoesNotFabricateApproval(error: Int32) async {
        let fixture = LocalNetworkRegistrationFixture()
        let task = Task { await DesktopLocalNetworkPermission.request(registration: fixture) }
        await waitForStart(fixture)
        fixture.emit(error)
        let observation = await task.value
        #expect(observation.state == (error == kDNSServiceErr_PolicyDenied ? .denied : .verificationRequired))
        #expect(!observation.verified)
        #expect(fixture.cancellations == 1)
        fixture.emit()
        #expect(fixture.cancellations == 1)
    }

    @Test func immediateErrorAndTimeoutUnregisterWithoutApproval() async {
        let rejected = LocalNetworkRegistrationFixture()
        rejected.immediateError = Int32(kDNSServiceErr_BadParam)
        let failure = await DesktopLocalNetworkPermission.request(registration: rejected)
        #expect(failure.state == .verificationRequired)
        #expect(rejected.cancellations == 1)
        let silent = LocalNetworkRegistrationFixture()
        let timeout = await DesktopLocalNetworkPermission.request(registration: silent, timeout: .zero)
        #expect(timeout.state == .verificationRequired)
        #expect(!timeout.verified)
        #expect(silent.cancellations == 1)
    }

    @Test func cancellationUnregistersAndLateSuccessCannotChangeOutcome() async {
        let fixture = LocalNetworkRegistrationFixture()
        let task = Task { await DesktopLocalNetworkPermission.request(registration: fixture) }
        await waitForStart(fixture)
        task.cancel()
        // A callback can arrive before the main-actor cancellation cleanup runs.
        fixture.emit()
        let result = await task.value
        #expect(result.state == .verificationRequired)
        #expect(!result.verified)
        #expect(fixture.cancellations == 1)
        fixture.emit()
        #expect(fixture.cancellations == 1)
    }
    @Test func noEligibleNetworkInterfaceDoesNotStartRegistration() async {
        let fixture = LocalNetworkRegistrationFixture()
        let result = await DesktopLocalNetworkPermission.request(registration: fixture, eligibleInterface: false)
        #expect(result.state == .verificationRequired)
        #expect(!result.verified)
        #expect(fixture.starts == 0)
        #expect(fixture.cancellations == 0)
    }

}
