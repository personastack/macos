import Foundation
import PersonaStackCore
import ServiceManagement
import Testing
@testable import PersonaStack

@Test(arguments: ["success", "signature", "updater", "login", "location", "read-only"])
@MainActor func iMessageBackgroundPreparationOrdersExistingOwnersAndFailsClosed(outcome: String) async throws {
    var calls: [String] = []
    let suite = "imessage-background-outcome-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    var status = SMAppService.Status.notRegistered
    let service = DesktopLoginItemRegistration.Service(status: { status }, unregister: { Issue.record("Absent") },
        legacyStatus: { .notRegistered }, unregisterLegacy: { Issue.record("Absent legacy") },
        register: { calls.append("login"); status = outcome == "login" ? .notRegistered : .enabled })
    let bundle = URL(fileURLWithPath: outcome == "location" ? "/Downloads/PersonaStack.app" : "/Applications/PersonaStack.app")
    do {
        try await IMessageSetupLifetime.prepareBackgroundConnection(configuration: .production, bundleURL: bundle,
            volumeIsReadOnly: outcome == "read-only", applicationDirectories: [URL(fileURLWithPath: "/Applications")],
            signatureValid: { value in #expect(value == bundle); calls.append("signature"); return outcome != "signature" },
            prepareUpdater: { calls.append("updater"); if outcome == "updater" { throw AgentBridgeFailure.busy } },
            preferences: preferences, executableIdentity: { _ in "current" }, loginService: service)
        #expect(outcome == "success")
    } catch {
        #expect(outcome != "success")
        if outcome == "signature" { #expect(error as? IMessageSetupLifetimeError == .signatureRequired) }
        if outcome == "login" { #expect(error as? IMessageSetupLifetimeError == .backgroundApprovalRequired) }
        if outcome == "location" || outcome == "read-only" { #expect(error as? IMessageSetupLifetimeError == .applicationsRequired) }
    }
    switch outcome {
    case "location", "read-only": #expect(calls.isEmpty)
    case "signature": #expect(calls == ["signature"])
    case "updater": #expect(calls == ["signature", "updater"])
    default: #expect(calls == ["signature", "updater", "signature", "login"])
    }
}

@Test @MainActor func iMessageApplicationsCheckRejectsLookalikesAndMenuNeverClaimsReceiving() {
    let roots = [URL(fileURLWithPath: "/Applications")]
    #expect(IMessageSetupLifetime.isApplicationsInstall(URL(fileURLWithPath: "/Applications/PersonaStack.app"), roots: roots))
    for path in ["/ApplicationsSibling/PersonaStack.app", "/Applications/../Downloads/PersonaStack.app", "/Applications/PersonaStack.txt"] {
        #expect(!IMessageSetupLifetime.isApplicationsInstall(URL(fileURLWithPath: path), roots: roots))
    }
    #expect(!IMessageSetupLifetime.isApplicationsInstall(URL(string: "https://example.test/PersonaStack.app")!, roots: roots))
    for state in IMessageMenuState.allCases { #expect(!state.statusText.lowercased().contains("receiving")) }
    #expect(IMessageMenuState.paused.offersResume)
    #expect(IMessageMenuState.offline.offersResume)
    #expect(!IMessageMenuState.connected.offersResume)
    #expect(!IMessageMenuState.setupRequired.offersResume)
}

@Test func iMessageMachineDisconnectConsentNamesBothFamiliesAndAllWorkspaces() {
    #expect(DesktopMachineDisconnectConfirmation.title == "Disconnect this Mac from PersonaStack?")
    #expect(DesktopMachineDisconnectConfirmation.detail.contains("Desktop Control and iMessage"))
    #expect(DesktopMachineDisconnectConfirmation.detail.contains("every workspace"))
    #expect(DesktopMachineDisconnectConfirmation.detail.contains("CUA stays installed and running"))
    #expect(DesktopMachineDisconnectConfirmation.action == "Disconnect This Mac")
    #expect(IMessageSetupLifetimeError.applicationsRequired.errorDescription?.contains("PersonaStack installer") == true)
    #expect(IMessageSetupLifetimeError.applicationsRequired.errorDescription?.lowercased().contains("drag") == false)
}

@Test @MainActor func iMessageExplicitBackgroundSetupReplacesEnabledRegistration() async throws {
    var status = SMAppService.Status.enabled
    var calls: [String] = []
    let suite = "imessage-explicit-login-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let service = DesktopLoginItemRegistration.Service(status: { status },
        unregister: { calls.append("unregister-old"); status = .notRegistered },
        legacyStatus: { .notRegistered }, unregisterLegacy: { Issue.record("Legacy owner is absent") },
        register: { calls.append("register-current"); status = .enabled })
    try await IMessageSetupLifetime.prepareBackgroundConnection(configuration: .production,
        bundleURL: URL(fileURLWithPath: "/Applications/PersonaStack.app"), volumeIsReadOnly: false,
        applicationDirectories: [URL(fileURLWithPath: "/Applications")], signatureValid: { _ in true },
        prepareUpdater: { calls.append("updater") }, preferences: preferences,
        executableIdentity: { _ in "updated" }, loginService: service)
    #expect(calls == ["updater", "unregister-old", "register-current"])
    try await IMessageSetupLifetime.prepareBackgroundConnection(configuration: .production,
        bundleURL: URL(fileURLWithPath: "/Applications/PersonaStack.app"), volumeIsReadOnly: false,
        signatureValid: { _ in true }, prepareUpdater: {}, preferences: preferences,
        executableIdentity: { _ in "updated" }, loginService: service)
    #expect(calls == ["updater", "unregister-old", "register-current"])
}

@Test(arguments: [false, true]) @MainActor
func iMessageSetupAndStartupJoinReplacementAndCancellationWaitsForRemoval(cancel: Bool) async throws {
    let suite = "imessage-shared-login-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    var status = SMAppService.Status.enabled
    var pending: CheckedContinuation<Void, Never>?
    var unregisters = 0
    var registrations = 0
    let service = DesktopLoginItemRegistration.Service(status: { status }, unregister: {
        unregisters += 1
        await withCheckedContinuation { pending = $0 }
        status = .notRegistered
    }, legacyStatus: { .notRegistered }, unregisterLegacy: {}, register: { registrations += 1; status = .enabled })
    let startup = Task { await DesktopLoginItemRegistration.reconcileAtLaunch(preferences: preferences,
        bundleURL: URL(fileURLWithPath: "/Applications/PersonaStack.app"), volumeIsReadOnly: false,
        signatureValid: { _ in true }, identity: { _ in "updated" }, service: service) }
    while pending == nil { await Task.yield() }
    var setupStarted = false
    var setupReturned = false
    let setup = Task {
        defer { setupReturned = true }
        try await IMessageSetupLifetime.prepareBackgroundConnection(configuration: .production,
            bundleURL: URL(fileURLWithPath: "/Applications/PersonaStack.app"), volumeIsReadOnly: false,
            signatureValid: { _ in true }, prepareUpdater: { setupStarted = true }, preferences: preferences,
            executableIdentity: { _ in "updated" }, loginService: service)
    }
    while !setupStarted { await Task.yield() }
    if cancel { setup.cancel() }
    await Task.yield()
    #expect(!setupReturned)
    #expect(unregisters == 1 && registrations == 0)
    pending?.resume()
    await startup.value
    if cancel { await #expect(throws: CancellationError.self) { try await setup.value } }
    else { try await setup.value }
    #expect(setupReturned && unregisters == 1 && registrations == 1)
    #expect(status == .enabled)
    #expect(preferences.string(forKey: DesktopLoginItemRegistration.registeredExecutableKey) == "updated")
}

@Test(arguments: [SMAppService.Status.notRegistered, .requiresApproval])
@MainActor func iMessageExplicitSetupRegistersWithOptInAndPreservesFamilyPreferences(initial: SMAppService.Status) async throws {
    let suite = "imessage-login-family-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let familyKeys = [DesktopControlPreferenceKeys.relayEnabled(.production), DesktopControlPreferenceKeys.relayPaused(.production),
        IMessagePreferenceKeys.relayEnabled(.production), IMessagePreferenceKeys.relayPaused(.production)]
    for (index, key) in familyKeys.enumerated() { preferences.set(index % 2 == 0, forKey: key) }
    let before = familyKeys.map { preferences.bool(forKey: $0) }
    var status = initial
    var registrations = 0
    let service = DesktopLoginItemRegistration.Service(status: { status }, unregister: { status = .notRegistered },
        legacyStatus: { .notRegistered }, unregisterLegacy: {}, register: { registrations += 1; status = .enabled })
    try await IMessageSetupLifetime.prepareBackgroundConnection(configuration: .production,
        bundleURL: URL(fileURLWithPath: "/Applications/PersonaStack.app"), volumeIsReadOnly: false,
        signatureValid: { _ in true }, prepareUpdater: {}, preferences: preferences,
        executableIdentity: { _ in "updated" }, loginService: service)
    #expect(registrations == 1)
    #expect(familyKeys.map { preferences.bool(forKey: $0) } == before)
}

@Test @MainActor func iMessageExplicitSetupRejectsStaleEnabledAfterFailureAndRetriesRecordedFailure() async throws {
    let suite = "imessage-login-failure-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    preferences.set("updated", forKey: DesktopLoginItemRegistration.registeredExecutableKey)
    preferences.set("Registration failed", forKey: DesktopLoginItemRegistration.errorKey)
    var status = SMAppService.Status.enabled
    var registrations = 0
    let service = DesktopLoginItemRegistration.Service(status: { status }, unregister: { status = .notRegistered },
        legacyStatus: { .notRegistered }, unregisterLegacy: {}, register: {
            registrations += 1; status = .enabled; throw AgentBridgeFailure.busy
        })
    await #expect(throws: (any Error).self) {
        try await IMessageSetupLifetime.prepareBackgroundConnection(configuration: .production,
            bundleURL: URL(fileURLWithPath: "/Applications/PersonaStack.app"), volumeIsReadOnly: false,
            signatureValid: { _ in true }, prepareUpdater: {}, preferences: preferences,
            executableIdentity: { _ in "updated" }, loginService: service)
    }
    #expect(registrations == 1)
    #expect(preferences.string(forKey: DesktopLoginItemRegistration.registeredExecutableKey) == nil)
    let failedIsReady: Bool = DesktopLoginItemRegistration.isCurrentExecutableRegistered(preferences: preferences,
        identity: { _ in "updated" }, status: status)
    #expect(!failedIsReady)
}

@Test @MainActor func iMessageCurrentPendingRegistrationIsApprovedWithoutAnotherReplacement() async throws {
    let suite = "imessage-login-approval-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    var status = SMAppService.Status.notRegistered
    var registrations = 0
    let service = DesktopLoginItemRegistration.Service(status: { status }, unregister: { Issue.record("Do not reset pending approval") },
        legacyStatus: { .notRegistered }, unregisterLegacy: {}, register: { registrations += 1; status = .requiresApproval })
    func prepare() async throws {
        try await IMessageSetupLifetime.prepareBackgroundConnection(configuration: .production,
            bundleURL: URL(fileURLWithPath: "/Applications/PersonaStack.app"), volumeIsReadOnly: false,
            signatureValid: { _ in true }, prepareUpdater: {}, preferences: preferences,
            executableIdentity: { _ in "updated" }, loginService: service)
    }
    await #expect(throws: IMessageSetupLifetimeError.backgroundApprovalRequired) { try await prepare() }
    #expect(preferences.string(forKey: DesktopLoginItemRegistration.registeredExecutableKey) == "updated")
    await #expect(throws: IMessageSetupLifetimeError.backgroundApprovalRequired) { try await prepare() }
    status = .enabled
    try await prepare()
    #expect(registrations == 1)
}

@Test(arguments: ["location", "signature"])
@MainActor func iMessageRejectedBackgroundPreflightPreservesInstalledRegistration(reason: String) async throws {
    let suite = "imessage-login-preflight-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    preferences.set("installed", forKey: DesktopLoginItemRegistration.registeredExecutableKey)
    preferences.set("preserve diagnostic", forKey: DesktopLoginItemRegistration.errorKey)
    let service = DesktopLoginItemRegistration.Service(status: { Issue.record("No registration observation before preflight"); return .enabled },
        unregister: { Issue.record("Keep installed owner") }, legacyStatus: { .notRegistered },
        unregisterLegacy: { Issue.record("Keep legacy owner") }, register: { Issue.record("Do not register rejected copy") })
    await #expect(throws: (any Error).self) {
        try await IMessageSetupLifetime.prepareBackgroundConnection(configuration: .production,
            bundleURL: URL(fileURLWithPath: reason == "location" ? "/tmp/PersonaStack.app" : "/Applications/PersonaStack.app"),
            volumeIsReadOnly: false, signatureValid: { _ in reason != "signature" },
            prepareUpdater: { Issue.record("No updater preparation before preflight") }, preferences: preferences,
            executableIdentity: { _ in Issue.record("No receipt work before preflight"); return "temporary" }, loginService: service)
    }
    #expect(preferences.string(forKey: DesktopLoginItemRegistration.registeredExecutableKey) == "installed")
    #expect(preferences.string(forKey: DesktopLoginItemRegistration.errorKey) == "preserve diagnostic")
}
