import Foundation
import PersonaStackCore
import Testing
@testable import PersonaStack

@Test(arguments: ["success", "signature", "updater", "login", "location", "read-only"])
@MainActor func iMessageBackgroundPreparationOrdersExistingOwnersAndFailsClosed(outcome: String) async throws {
    var calls: [String] = []
    let bundle = URL(fileURLWithPath: outcome == "location" ? "/Downloads/PersonaStack.app" : "/Applications/PersonaStack.app")
    do {
        try await IMessageSetupLifetime.prepareBackgroundConnection(configuration: .production, bundleURL: bundle,
            volumeIsReadOnly: outcome == "read-only", applicationDirectories: [URL(fileURLWithPath: "/Applications")],
            signatureValid: { value in #expect(value == bundle); calls.append("signature"); return outcome != "signature" },
            prepareUpdater: { calls.append("updater"); if outcome == "updater" { throw AgentBridgeFailure.busy } },
            registerLogin: { calls.append("login"); return outcome != "login" })
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
    default: #expect(calls == ["signature", "updater", "login"])
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
