import Testing
@testable import PersonaStack

@Suite struct DesktopMenuTests {
    @Test(arguments: [false, true])
    func credentialFailureKeepsRetryReachableWithoutChangingRelayState(relayEnabled: Bool) throws {
        let action = try #require(DesktopMenuRelayAction(
            relayEnabled: relayEnabled, relayPaused: false, hasError: true,
            hasTrustedConfiguration: true, environmentSwitchPending: false))
        #expect(action.title == "Retry Remote Control")
        #expect(action.isEnabled)
    }

    @Test(arguments: [false, true])
    func activeRelayKeepsItsPauseAndResumeActions(paused: Bool) throws {
        let action = try #require(DesktopMenuRelayAction(
            relayEnabled: true, relayPaused: paused, hasError: false,
            hasTrustedConfiguration: true, environmentSwitchPending: false))
        #expect(action.title == (paused ? "Resume Remote Control" : "Pause Remote Control"))
        #expect(action.isEnabled)
    }

    @Test(arguments: [false, true])
    func startingDesktopControlStillRequiresTrustedServerConfiguration(trusted: Bool) throws {
        let action = try #require(DesktopMenuRelayAction(
            relayEnabled: false, relayPaused: false, hasError: false,
            hasTrustedConfiguration: trusted, environmentSwitchPending: false))
        #expect(action.title == "Start Desktop Control")
        #expect(action.isEnabled == trusted)
    }

    @Test(arguments: [false, true])
    func serverSwitchKeepsTheSameActionFence(hasError: Bool) throws {
        #expect(DesktopMenuRelayAction(
            relayEnabled: false, relayPaused: false, hasError: hasError,
            hasTrustedConfiguration: true, environmentSwitchPending: true) == nil)
        let action = try #require(DesktopMenuRelayAction(
            relayEnabled: true, relayPaused: false, hasError: hasError,
            hasTrustedConfiguration: true, environmentSwitchPending: true))
        #expect(action.title == (hasError ? "Retry Remote Control" : "Pause Remote Control"))
        #expect(!action.isEnabled)
    }

    @Test func untrustedConfigurationCannotAuthorizeAStoredCredentialFromRetry() throws {
        let action = try #require(DesktopMenuRelayAction(
            relayEnabled: false, relayPaused: true, hasError: true,
            hasTrustedConfiguration: false, environmentSwitchPending: false))
        #expect(action.title == "Retry Remote Control")
        #expect(!action.isEnabled)
    }
}
