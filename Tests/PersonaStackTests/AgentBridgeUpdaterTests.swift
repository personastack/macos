import Foundation
import PersonaStackCore
import Sparkle
import Testing
@testable import PersonaStack

@MainActor
private final class AgentBridgeUpdaterClient: DesktopUpdateClient {
    var canCheckForUpdates = true
    var automaticallyChecksForUpdates = true
    var automaticallyDownloadsUpdates = true
    func start() throws {}
    func checkForUpdates() {}
}

@MainActor
private final class AgentBridgeUpdaterState {
    var needsHandoff = true
    var calls: [String] = []
}

@Suite struct AgentBridgeUpdaterTests {
    @Test @MainActor func automaticInstallPreferenceIsPreservedWhileActualDownloadsPause() throws {
        let preferences = UserDefaults(suiteName: "AgentBridgeUpdaterTests." + UUID().uuidString)!
        preferences.set(true, forKey: "SUAutomaticallyUpdate")
        let client = AgentBridgeUpdaterClient(), state = AgentBridgeUpdaterState()
        let updater = DesktopUpdater(updaterFactory: { _, _ in client }, preferences: preferences,
                                     agentBridgeNeedsHandoff: { state.needsHandoff }, prepareAgentBridgeUpdate: {}, cancelAgentBridgeUpdate: {})
        updater.start(publicKey: Data(repeating: 1, count: 32).base64EncodedString(), feed: DesktopUpdatePolicy.feedURL)
        #expect(updater.automaticallyDownloadsUpdates)
        #expect(!client.automaticallyDownloadsUpdates)
        state.needsHandoff = false
        updater.restoreAutomaticDownloadsAfterAgentsStopped()
        #expect(client.automaticallyDownloadsUpdates)
        #expect(preferences.bool(forKey: "SUAutomaticallyUpdate"))
    }

    @Test @MainActor func stagedUpdatePreventsEnableAndUnexpectedQuitDoesNotTouchHelper() {
        let state = AgentBridgeUpdaterState()
        let updater = DesktopUpdater(updaterFactory: { _, _ in AgentBridgeUpdaterClient() },
                                     preferences: UserDefaults(suiteName: "AgentBridgeUpdaterTests." + UUID().uuidString)!,
                                     agentBridgeNeedsHandoff: { state.needsHandoff },
                                     prepareAgentBridgeUpdate: { state.calls.append("quiesce") },
                                     cancelAgentBridgeUpdate: { state.calls.append("resume") })
        updater.projectReady(version: "0.3.0", notifyWhenInactive: false)
        #expect(throws: AgentBridgeFailure.busy) { try updater.prepareToEnableBackgroundAgents() }
        #expect(!updater.allowsTermination())
        #expect(state.calls.isEmpty)
    }

    @Test @MainActor func ordinaryQuitAndExplicitInstallHaveDistinctHelperEffects() async {
        let state = AgentBridgeUpdaterState()
        let updater = DesktopUpdater(updaterFactory: { _, _ in AgentBridgeUpdaterClient() },
                                     preferences: UserDefaults(suiteName: "AgentBridgeUpdaterTests." + UUID().uuidString)!,
                                     agentBridgeNeedsHandoff: { state.needsHandoff },
                                     prepareAgentBridgeUpdate: { state.calls.append("quiesce-idle-retire") },
                                     cancelAgentBridgeUpdate: { state.calls.append("restore-resume") })
        #expect(updater.allowsTermination())
        #expect(state.calls.isEmpty)
        updater.projectReady(version: "0.3.0", notifyWhenInactive: false)
        #expect(await updater.prepareBackgroundAgentsForUpdate())
        #expect(updater.allowsTermination())
        await updater.resumeBackgroundAgentsAfterCanceledUpdate()
        #expect(state.calls == ["quiesce-idle-retire", "restore-resume"])
        #expect(!updater.allowsTermination())
    }

    @Test @MainActor func cancelReadyInstallationUsesSupportedSkipChoiceForBackgroundAgents() async {
        let state = AgentBridgeUpdaterState()
        let driver = DesktopUpdateUserDriver(hostBundle: .main, delegate: nil, updateReady: {}, restartRequested: {},
            statusChanged: { _ in }, confirmReady: { false }, prepareReplacement: { state.calls.append("prepare"); return true },
            cancelReplacement: { state.calls.append("resume") }, mustCancelDeferredInstallation: { true })
        let choice = await driver.showReadyToInstallAndRelaunch()
        #expect(choice == .skip)
        #expect(state.calls == ["resume"])
        // SPUUserDriver.h: Dismiss may still install after termination. Skip at
        // the ready stage cancels this installation without skipping the version.
    }
}
