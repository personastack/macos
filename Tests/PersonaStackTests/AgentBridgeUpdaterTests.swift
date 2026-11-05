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
    @Test @MainActor func activeLocalRuntimeDefersReplacementWithActionableFeedback() async {
        let updater = DesktopUpdater(updaterFactory: { _, _ in AgentBridgeUpdaterClient() },
            preferences: UserDefaults(suiteName: "AgentBridgeUpdaterTests." + UUID().uuidString)!,
            presentReadyReminder: { _ in }, clearAvailableNotification: { _ in }, clearUpdateNotifications: { _ in },
            agentBridgeNeedsHandoff: { true },
            prepareAgentBridgeUpdate: { throw AgentBridgeFailure.localRuntimeActive }, cancelAgentBridgeUpdate: {}, registrationService: isolatedLoginRegistrationService())
        updater.projectReady(version: "0.9.0", notifyWhenInactive: false)
        #expect(!(await updater.prepareBackgroundAgentsForUpdate()))
        #expect(updater.waitsForBackgroundAgents)
        #expect(!updater.allowsTermination())
        #expect(updater.statusMessage == "Stop agents on this Mac from the PersonaStack menu, then retry Restart Now. Your local files are retained.")
    }

    @Test(arguments: [AgentBridgeFailure.busy, .serviceUnavailable]) @MainActor
    func failedHandoffGuidanceSurvivesTheQuitGuard(_ failure: AgentBridgeFailure) async {
        let updater = DesktopUpdater(updaterFactory: { _, _ in AgentBridgeUpdaterClient() },
            preferences: UserDefaults(suiteName: "AgentBridgeUpdaterTests." + UUID().uuidString)!,
            presentReadyReminder: { _ in }, clearAvailableNotification: { _ in }, clearUpdateNotifications: { _ in },
            agentBridgeNeedsHandoff: { true }, prepareAgentBridgeUpdate: { throw failure }, cancelAgentBridgeUpdate: {}, registrationService: isolatedLoginRegistrationService())
        updater.projectReady(version: "0.9.0", notifyWhenInactive: false)
        #expect(!(await updater.prepareBackgroundAgentsForUpdate()))
        let guidance = updater.statusMessage
        #expect(!guidance.isEmpty)
        #expect(!updater.allowsTermination())
        #expect(updater.statusMessage == guidance)
    }

    @Test @MainActor func canceledPreparedReplacementBlocksQuitBeforeHelperResumes() async throws {
        var release: CheckedContinuation<Void, Never>?
        let updater = DesktopUpdater(updaterFactory: { _, _ in AgentBridgeUpdaterClient() },
            preferences: UserDefaults(suiteName: "AgentBridgeUpdaterTests." + UUID().uuidString)!,
            presentReadyReminder: { _ in }, clearAvailableNotification: { _ in }, clearUpdateNotifications: { _ in },
            agentBridgeNeedsHandoff: { true }, prepareAgentBridgeUpdate: {}, cancelAgentBridgeUpdate: {
                await withCheckedContinuation { release = $0 }
            }, registrationService: isolatedLoginRegistrationService())
        updater.projectReady(version: "0.9.0", notifyWhenInactive: false)
        #expect(await updater.prepareBackgroundAgentsForUpdate())
        #expect(updater.allowsTermination())
        updater.cancelBackgroundUpdate()
        #expect(!updater.allowsTermination())
        for _ in 0..<100 where release == nil { await Task.yield() }
        let pending = try #require(release)
        #expect(!updater.allowsTermination())
        pending.resume()
        for _ in 0..<20 { await Task.yield() }
        #expect(!updater.allowsTermination())
    }

    @Test @MainActor func startupRestoresAutomaticDownloadsWhenBackgroundHelperWasDisabledOutsideApp() {
        let preferences = UserDefaults(suiteName: "AgentBridgeUpdaterTests." + UUID().uuidString)!
        preferences.set(true, forKey: "agentBridge.savedAutomaticDownloads")
        let client = AgentBridgeUpdaterClient()
        client.automaticallyDownloadsUpdates = false
        let updater = DesktopUpdater(updaterFactory: { _, _ in client }, preferences: preferences,
            agentBridgeNeedsHandoff: { false }, prepareAgentBridgeUpdate: {}, cancelAgentBridgeUpdate: {}, registrationService: isolatedLoginRegistrationService())
        updater.start(publicKey: Data(repeating: 1, count: 32).base64EncodedString(), feed: DesktopUpdatePolicy.feedURL)
        #expect(client.automaticallyDownloadsUpdates)
        #expect(updater.automaticallyDownloadsUpdates)
        #expect(preferences.object(forKey: "agentBridge.savedAutomaticDownloads") == nil)
    }

    @Test(arguments: ["resume", "skip", "failure"]) @MainActor
    func cancelledRestartCannotInstallAfterDelayedBackgroundPreparation(_ outcome: String) async throws {
        let preferences = UserDefaults(suiteName: "AgentBridgeUpdaterTests." + UUID().uuidString)!
        var release: CheckedContinuation<Void, Error>?
        var calls: [String] = []
        var installs = 0
        let updater = DesktopUpdater(updaterFactory: { _, _ in AgentBridgeUpdaterClient() },
            preferences: preferences, presentAvailableReminder: { _ in }, presentReadyReminder: { _ in },
            clearAvailableNotification: { _ in }, clearUpdateNotifications: { _ in }, confirmRestart: { true },
            agentBridgeNeedsHandoff: { true }, prepareAgentBridgeUpdate: {
                calls.append("prepare")
                try await withCheckedThrowingContinuation { release = $0 }
                calls.append("prepared")
            }, cancelAgentBridgeUpdate: { calls.append("resume") }, registrationService: isolatedLoginRegistrationService())
        _ = updater.retainAutomaticInstallHandler(version: "0.9.0") { installs += 1 }
        updater.restartToInstall()
        for _ in 0..<100 where release == nil { await Task.yield() }
        let pending = try #require(release)
        switch outcome {
        case "skip": updater.handleSkippedUpdate(version: "0.9.0")
        case "failure": updater.handleUpdateFailure(domain: "fixture", code: 1)
        default: updater.cancelBackgroundUpdate(showStatus: true)
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(calls == ["prepare"])
        pending.resume()
        for _ in 0..<100 where !calls.contains("resume") { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
        #expect(calls == ["prepare", "prepared", "resume"])
        #expect(installs == 0)
        #expect(!preferences.bool(forKey: DesktopUpdater.foregroundUpdateRelaunchKey))
        #expect(!updater.waitsForBackgroundAgents)
        if outcome == "resume" { #expect(updater.statusMessage == "Restart canceled. Background agents resumed. The update is still ready.") }
    }

    @Test @MainActor func automaticInstallPreferenceIsPreservedWhileActualDownloadsPause() throws {
        let preferences = UserDefaults(suiteName: "AgentBridgeUpdaterTests." + UUID().uuidString)!
        preferences.set(true, forKey: "SUAutomaticallyUpdate")
        let client = AgentBridgeUpdaterClient(), state = AgentBridgeUpdaterState()
        let updater = DesktopUpdater(updaterFactory: { _, _ in client }, preferences: preferences,
                                     presentAvailableReminder: { _ in }, presentReadyReminder: { _ in },
                                     clearAvailableNotification: { _ in }, clearUpdateNotifications: { _ in },
                                     agentBridgeNeedsHandoff: { state.needsHandoff }, prepareAgentBridgeUpdate: {}, cancelAgentBridgeUpdate: {}, registrationService: isolatedLoginRegistrationService())
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
                                     presentAvailableReminder: { _ in }, presentReadyReminder: { _ in },
                                     clearAvailableNotification: { _ in }, clearUpdateNotifications: { _ in },
                                     agentBridgeNeedsHandoff: { state.needsHandoff },
                                     prepareAgentBridgeUpdate: { state.calls.append("quiesce") },
                                     cancelAgentBridgeUpdate: { state.calls.append("resume") }, registrationService: isolatedLoginRegistrationService())
        updater.projectReady(version: "0.3.0", notifyWhenInactive: false)
        #expect(throws: AgentBridgeFailure.busy) { try updater.prepareToEnableBackgroundAgents() }
        #expect(!updater.allowsTermination())
        #expect(state.calls.isEmpty)
    }

    @Test @MainActor func ordinaryQuitAndExplicitInstallHaveDistinctHelperEffects() async {
        let state = AgentBridgeUpdaterState()
        let updater = DesktopUpdater(updaterFactory: { _, _ in AgentBridgeUpdaterClient() },
                                     preferences: UserDefaults(suiteName: "AgentBridgeUpdaterTests." + UUID().uuidString)!,
                                     presentAvailableReminder: { _ in }, presentReadyReminder: { _ in },
                                     clearAvailableNotification: { _ in }, clearUpdateNotifications: { _ in },
                                     agentBridgeNeedsHandoff: { state.needsHandoff },
                                     prepareAgentBridgeUpdate: { state.calls.append("quiesce-idle-retire") },
                                     cancelAgentBridgeUpdate: { state.calls.append("restore-resume") }, registrationService: isolatedLoginRegistrationService())
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
