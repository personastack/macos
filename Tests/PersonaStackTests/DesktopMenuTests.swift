import Foundation
import PersonaStackCore
import ServiceManagement
import Testing
@testable import PersonaStack

@Suite struct DesktopMenuTests {
    @Test(arguments: [false, true])
    func credentialFailureKeepsRetryReachableWithoutChangingRelayState(relayEnabled: Bool) throws {
        let action = try #require(DesktopMenuRelayAction(
            relayEnabled: relayEnabled, relayPaused: false, hasError: true,
            hasTrustedConfiguration: true, environmentSwitchPending: false))
        #expect(action.title == "Retry PersonaStack Connection")
        #expect(action.isEnabled)
    }

    @Test(arguments: [false, true])
    func activeRelayKeepsItsPauseAndResumeActions(paused: Bool) throws {
        let action = try #require(DesktopMenuRelayAction(
            relayEnabled: true, relayPaused: paused, hasError: false,
            hasTrustedConfiguration: true, environmentSwitchPending: false))
        #expect(action.title == (paused ? "Resume PersonaStack Control" : "Pause PersonaStack Control"))
        #expect(action.isEnabled)
    }

    @Test(arguments: [false, true])
    func startingDesktopControlStillRequiresTrustedServerConfiguration(trusted: Bool) throws {
        let action = try #require(DesktopMenuRelayAction(
            relayEnabled: false, relayPaused: false, hasError: false,
            hasTrustedConfiguration: trusted, environmentSwitchPending: false))
        #expect(action.title == "Connect PersonaStack")
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
        #expect(action.title == (hasError ? "Retry PersonaStack Connection" : "Pause PersonaStack Control"))
        #expect(!action.isEnabled)
    }

    @Test func untrustedConfigurationCannotAuthorizeAStoredCredentialFromRetry() throws {
        let action = try #require(DesktopMenuRelayAction(
            relayEnabled: false, relayPaused: true, hasError: true,
            hasTrustedConfiguration: false, environmentSwitchPending: false))
        #expect(action.title == "Retry PersonaStack Connection")
        #expect(!action.isEnabled)
    }

    @Test func liveActivityOffersStopWithoutSavedRelayPreference() throws {
        let action = try #require(DesktopMenuRelayAction(
            relayEnabled: false, relayPaused: false, hasError: false,
            hasTrustedConfiguration: false, environmentSwitchPending: false,
            activelyControlling: true))
        #expect(action.title == "Stop PersonaStack Control")
        #expect(action.isEnabled)
    }

    @Test func cleanupPendingDisablesControlStopAction() throws {
        let action = try #require(DesktopMenuRelayAction(
            relayEnabled: true, relayPaused: true, hasError: false,
            hasTrustedConfiguration: true, environmentSwitchPending: false,
            activelyControlling: true, cleanupPending: true))
        #expect(action.title == "Stopping PersonaStack Control…")
        #expect(!action.isEnabled)
    }
}

@Test(arguments: ["enabled", "approval", "terminal", "signature"]) @MainActor
func launchAtLoginMenuUsesSharedCurrentExecutableOwnerAndPreservesSettingsFeedback(outcome: String) async throws {
    let name = "LaunchAtLoginMenu.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: name))
    defer { preferences.removePersistentDomain(forName: name) }
    preferences.set("old", forKey: DesktopLoginItemRegistration.registeredExecutableKey)
    var status = SMAppService.Status.notRegistered
    var registrations = 0, settings = 0
    let service = DesktopLoginItemRegistration.Service(status: { status },
        unregister: { Issue.record("Already absent") }, legacyStatus: { .notRegistered },
        unregisterLegacy: { Issue.record("No legacy entry") }, register: {
            registrations += 1
            status = outcome == "approval" ? .requiresApproval : .enabled
        })
    if outcome == "terminal" { service.stopAdmission(terminal: true) }
    let error = await DesktopControlMenu.requestLaunchAtLogin(register: {
        try await DesktopLoginItemRegistration.registerCurrentExecutable(preferences: preferences,
            bundleURL: URL(fileURLWithPath: "/Applications/PersonaStack.app"), volumeIsReadOnly: false,
            signatureValid: { _ in outcome != "signature" }, identity: { _ in "current" }, service: service)
    }, openSettings: { settings += 1 })
    if outcome == "terminal" || outcome == "signature" {
        #expect(registrations == 0 && settings == 0)
        #expect(preferences.string(forKey: DesktopLoginItemRegistration.registeredExecutableKey) == "old")
        #expect(outcome == "terminal" ? error.isEmpty : error == DesktopLoginItemRegistration.invalidSignatureMessage)
    } else {
        #expect(registrations == 1)
        #expect(settings == (outcome == "approval" ? 1 : 0))
        #expect(error == (outcome == "approval" ? DesktopLoginItemRegistration.approvalMessage : ""))
        #expect(preferences.string(forKey: DesktopLoginItemRegistration.registeredExecutableKey) == "current")
    }
}
