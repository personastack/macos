import Foundation
import AppKit
import PersonaStackCore
import Testing
@testable import PersonaStack

@MainActor
private final class FakeDesktopUpdateClient: DesktopUpdateClient {
    private let preferences: UserDefaults
    private let automaticDownloadsKey = "SUAutomaticallyUpdate"
    var canCheckForUpdates = true
    private(set) var didStart = false
    private(set) var checkCount = 0

    init(preferences: UserDefaults) {
        self.preferences = preferences
    }

    var automaticallyChecksForUpdates: Bool {
        get { preferences.object(forKey: "SUEnableAutomaticChecks") as? Bool ?? true }
        set { preferences.set(newValue, forKey: "SUEnableAutomaticChecks") }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { preferences.bool(forKey: automaticDownloadsKey) }
        set { preferences.set(newValue, forKey: automaticDownloadsKey) }
    }

    func start() throws { didStart = true }
    func checkForUpdates() { checkCount += 1 }
}

@MainActor
private final class RestartConfirmationState {
    var allowed = false
}

@Suite struct DesktopUpdaterTests {
    @Test @MainActor func validatesFeedAndPersistsSparklePreferenceThroughClient() {
        let preferences = isolatedUpdatePreferences()
        let client = FakeDesktopUpdateClient(preferences: preferences)
        let updater = DesktopUpdater(updaterFactory: { _, _ in client }, preferences: preferences, registrationService: isolatedLoginRegistrationService())
        let publicKey = Data(repeating: 3, count: 32).base64EncodedString()

        updater.start(publicKey: publicKey, feed: DesktopUpdatePolicy.feedURL)
        #expect(client.didStart)
        #expect(updater.isAvailable)
        #expect(!updater.automaticallyDownloadsUpdates)

        updater.automaticallyChecksForUpdates = false
        #expect(!client.automaticallyChecksForUpdates)
        #expect(!preferences.bool(forKey: "SUEnableAutomaticChecks"))
        updater.automaticallyChecksForUpdates = true
        #expect(client.automaticallyChecksForUpdates)
        #expect(preferences.bool(forKey: "SUEnableAutomaticChecks"))

        updater.automaticallyDownloadsUpdates = true
        #expect(preferences.bool(forKey: "SUAutomaticallyUpdate"))
        updater.automaticallyDownloadsUpdates = false
        #expect(!preferences.bool(forKey: "SUAutomaticallyUpdate"))
    }

    @Test @MainActor func readOnlyBundleShowsApplicationsInstallInstruction() {
        let preferences = isolatedUpdatePreferences()
        preferences.set(true, forKey: "SUAutomaticallyUpdate")
        let client = FakeDesktopUpdateClient(preferences: preferences)
        let updater = DesktopUpdater(
            updaterFactory: { _, _ in client },
            preferences: preferences,
            clearAvailableNotification: { _ in },
            clearUpdateNotifications: { _ in }
        , registrationService: isolatedLoginRegistrationService())
        let publicKey = Data(repeating: 3, count: 32).base64EncodedString()

        updater.start(
            publicKey: publicKey,
            feed: DesktopUpdatePolicy.feedURL,
            bundleURL: URL(fileURLWithPath: "/Volumes/PersonaStack/PersonaStack.app"),
            volumeIsReadOnly: true
        )

        #expect(!client.didStart)
        #expect(updater.applicationsInstallInstruction == DesktopUpdater.applicationsInstallMessage)
        #expect(!updater.isAvailable)
        #expect(!updater.canCheckForUpdates)
        #expect(!updater.isReady)
        #expect(updater.automaticallyDownloadsUpdates)
        updater.checkForUpdates()
        updater.downloadLatestUpdate()
        updater.applicationWillTerminate()

        #expect(client.checkCount == 0)
        #expect(preferences.bool(forKey: "SUAutomaticallyUpdate"))
        #expect(preferences.string(forKey: "desktopUpdateRestartTargetVersion") == nil)
    }

    @Test @MainActor func readOnlyBundleBlocksRestartAndExplainsHowToInstall() {
        let preferences = isolatedUpdatePreferences()
        let client = FakeDesktopUpdateClient(preferences: preferences)
        var restartConfirmations = 0
        var installCount = 0
        var presentedMessages: [String] = []
        let updater = DesktopUpdater(
            updaterFactory: { _, _ in client },
            preferences: preferences,
            presentReadyReminder: { _ in },
            clearAvailableNotification: { _ in },
            clearUpdateNotifications: { _ in },
            confirmRestart: { restartConfirmations += 1; return true },
            presentApplicationsInstallInstruction: { presentedMessages.append($0) }
        , registrationService: isolatedLoginRegistrationService())
        let publicKey = Data(repeating: 3, count: 32).base64EncodedString()
        updater.start(
            publicKey: publicKey,
            feed: DesktopUpdatePolicy.feedURL,
            bundleURL: URL(fileURLWithPath: "/Volumes/PersonaStack/PersonaStack.app"),
            volumeIsReadOnly: true
        )
        _ = updater.retainAutomaticInstallHandler(version: "0.2.0", handler: { installCount += 1 })

        updater.restartToInstall()

        #expect(restartConfirmations == 0)
        #expect(installCount == 0)
        #expect(presentedMessages == [DesktopUpdater.applicationsInstallMessage])
        #expect(updater.statusMessage == DesktopUpdater.applicationsInstallMessage)
    }

    @Test @MainActor func scheduledAndManualChecksShareTheCurrentUpdateSession() {
        let preferences = isolatedUpdatePreferences()
        let client = FakeDesktopUpdateClient(preferences: preferences)
        var reminders: [String] = []
        let updater = DesktopUpdater(
            updaterFactory: { _, _ in client },
            preferences: preferences,
            presentAvailableReminder: { reminders.append($0) }
        , registrationService: isolatedLoginRegistrationService())
        let publicKey = Data(repeating: 4, count: 32).base64EncodedString()
        updater.start(publicKey: publicKey, feed: DesktopUpdatePolicy.feedURL)

        updater.checkForUpdates()
        #expect(client.checkCount == 1)
        #expect(updater.isChecking)
        updater.checkForUpdates()
        #expect(client.checkCount == 1)

        updater.projectFoundUpdate(version: "0.2.0", isScheduled: false)
        #expect(!updater.isChecking)
        #expect(reminders.isEmpty)
        updater.downloadLatestUpdate()
        #expect(client.checkCount == 2)

        updater.projectFoundUpdate(version: "0.2.0", isScheduled: true)
        updater.projectFoundUpdate(version: "0.2.0", isScheduled: true)
        #expect(reminders == ["0.2.0"])
        #expect(updater.updateAvailable)
    }

    @Test @MainActor func automaticScheduledUpdateShowsBackgroundDownloadAndBlocksDuplicateChecks() {
        let preferences = isolatedUpdatePreferences()
        let client = FakeDesktopUpdateClient(preferences: preferences)
        client.automaticallyDownloadsUpdates = true
        var reminders: [String] = []
        let updater = DesktopUpdater(
            updaterFactory: { _, _ in client },
            preferences: preferences,
            presentAvailableReminder: { reminders.append($0) }
        , registrationService: isolatedLoginRegistrationService())
        let publicKey = Data(repeating: 4, count: 32).base64EncodedString()
        updater.start(publicKey: publicKey, feed: DesktopUpdatePolicy.feedURL)

        updater.projectFoundUpdate(version: "0.2.1", isScheduled: true)
        updater.checkForUpdates()

        #expect(updater.isAutomaticallyDownloading)
        #expect(!updater.updateAvailable)
        #expect(!updater.canCheckForUpdates)
        #expect(reminders.isEmpty)
        #expect(client.checkCount == 0)
        #expect(updater.statusMessage.contains("Downloading version 0.2.1"))
    }

    @Test @MainActor func scheduledAuthorizationFallbackOffersContinuationForEachSparkleStage() {
        let cases: [(String, ScheduledUpdateStage, String)] = [
            ("0.2.3", .notDownloaded, "needs your approval to continue"),
            ("0.2.4", .downloaded, "is downloaded and needs your approval to install"),
            ("0.2.5", .installing, "needs your approval to finish installing")
        ]
        for (version, stage, expectedMessage) in cases {
            let preferences = isolatedUpdatePreferences()
            let client = FakeDesktopUpdateClient(preferences: preferences)
            client.automaticallyDownloadsUpdates = true
            var reminders: [String] = []
            let updater = DesktopUpdater(
                updaterFactory: { _, _ in client },
                preferences: preferences,
                presentAvailableReminder: { reminders.append($0) }
            , registrationService: isolatedLoginRegistrationService())
            let publicKey = Data(repeating: 4, count: 32).base64EncodedString()
            updater.start(publicKey: publicKey, feed: DesktopUpdatePolicy.feedURL)
            updater.projectFoundUpdate(version: version, isScheduled: true)
            #expect(updater.isAutomaticallyDownloading)

            updater.projectScheduledUpdateRequiringAction(version: version, stage: stage)

            #expect(!updater.isAutomaticallyDownloading)
            #expect(updater.isWaitingForApproval)
            #expect(updater.updateAvailable)
            #expect(updater.canCheckForUpdates)
            #expect(updater.statusMessage.contains(expectedMessage))
            #expect(reminders == [version])

            updater.downloadLatestUpdate()
            #expect(client.checkCount == 1)
        }
    }

    @Test @MainActor func scheduledInformationOnlyUpdateRemainsActionableInsteadOfAutoDownloading() {
        let preferences = isolatedUpdatePreferences()
        let client = FakeDesktopUpdateClient(preferences: preferences)
        client.automaticallyDownloadsUpdates = true
        var reminders: [String] = []
        let updater = DesktopUpdater(
            updaterFactory: { _, _ in client },
            preferences: preferences,
            presentAvailableReminder: { reminders.append($0) }
        , registrationService: isolatedLoginRegistrationService())
        let publicKey = Data(repeating: 4, count: 32).base64EncodedString()
        updater.start(publicKey: publicKey, feed: DesktopUpdatePolicy.feedURL)

        updater.projectFoundUpdate(version: "0.2.6", isScheduled: true, isInformational: true)

        #expect(!updater.isAutomaticallyDownloading)
        #expect(updater.isInformationalUpdate)
        #expect(updater.updateAvailable)
        #expect(updater.statusMessage.contains("has update information"))
        #expect(reminders == ["0.2.6"])
    }

    @Test @MainActor func skippingPreparedUpdateClearsReadyStateAndMatchingRestartMetadata() {
        let preferences = isolatedUpdatePreferences()
        var installCount = 0
        var clearedVersions: [String] = []
        let updater = DesktopUpdater(
            updaterFactory: { _, _ in FakeDesktopUpdateClient(preferences: preferences) },
            preferences: preferences,
            presentReadyReminder: { _ in },
            clearAvailableNotification: { _ in },
            clearUpdateNotifications: { clearedVersions.append($0) },
            confirmRestart: { true }
        , registrationService: isolatedLoginRegistrationService())
        let publicKey = Data(repeating: 4, count: 32).base64EncodedString()
        updater.start(publicKey: publicKey, feed: DesktopUpdatePolicy.feedURL)
        #expect(updater.retainAutomaticInstallHandler(version: "0.2.7", handler: { installCount += 1 }))
        preferences.set("0.2.7", forKey: "desktopUpdateRestartTargetVersion")
        preferences.set(true, forKey: DesktopUpdater.foregroundUpdateRelaunchKey)

        updater.handleSkippedUpdate(version: "0.2.7")
        updater.restartToInstall()
        updater.applicationWillTerminate()

        #expect(!updater.isReady)
        #expect(!updater.updateAvailable)
        #expect(updater.offeredVersion == nil)
        #expect(updater.statusMessage == "Version 0.2.7 was skipped.")
        #expect(preferences.string(forKey: "desktopUpdateRestartTargetVersion") == nil)
        #expect(!preferences.bool(forKey: DesktopUpdater.foregroundUpdateRelaunchKey))
        #expect(preferences.string(forKey: "desktopUpdateReadyReminderVersion") == nil)
        #expect(installCount == 0)
        #expect(clearedVersions == ["0.2.7"])
    }

    @Test @MainActor func skippingAvailableUpdateClearsTheOfferAndItsReminder() {
        let preferences = isolatedUpdatePreferences()
        let updater = DesktopUpdater(
            updaterFactory: { _, _ in FakeDesktopUpdateClient(preferences: preferences) },
            preferences: preferences,
            clearUpdateNotifications: { _ in }
        , registrationService: isolatedLoginRegistrationService())
        let publicKey = Data(repeating: 4, count: 32).base64EncodedString()
        updater.start(publicKey: publicKey, feed: DesktopUpdatePolicy.feedURL)
        updater.projectFoundUpdate(version: "0.2.8", isScheduled: false)
        preferences.set("0.2.8", forKey: "desktopUpdateAvailableReminderVersion")

        updater.handleSkippedUpdate(version: "0.2.8")

        #expect(!updater.updateAvailable)
        #expect(updater.offeredVersion == nil)
        #expect(preferences.string(forKey: "desktopUpdateAvailableReminderVersion") == nil)
        #expect(updater.canCheckForUpdates)
    }

    @Test @MainActor func canceledDownloadClearsProgressAndKeepsTheOfferRetryable() {
        let preferences = isolatedUpdatePreferences()
        let updater = DesktopUpdater(
            updaterFactory: { _, _ in FakeDesktopUpdateClient(preferences: preferences) },
            preferences: preferences
        , registrationService: isolatedLoginRegistrationService())
        updater.projectFoundUpdate(version: "0.2.2", isScheduled: false)
        updater.projectDownloadProgress("Downloading update… 43%")

        updater.handleDownloadCancellation()

        #expect(updater.statusMessage == "Update download canceled.")
        #expect(!updater.isChecking)
        #expect(!updater.isAutomaticallyDownloading)
        #expect(updater.updateAvailable)
        #expect(updater.canCheckForUpdates)
    }

    @Test @MainActor func rejectsAnUntrustedFeedBeforeStartingTheClient() {
        let preferences = isolatedUpdatePreferences()
        let client = FakeDesktopUpdateClient(preferences: preferences)
        let updater = DesktopUpdater(updaterFactory: { _, _ in client }, preferences: preferences, registrationService: isolatedLoginRegistrationService())
        let publicKey = Data(repeating: 5, count: 32).base64EncodedString()

        updater.start(publicKey: publicKey, feed: "http://updates.example.test/appcast.xml")
        #expect(!client.didStart)
        #expect(!updater.isAvailable)
    }

    @Test @MainActor func readyPromptLaterDismissesWithoutRequestingRestart() async {
        var restartCount = 0
        var readyCount = 0
        let driver = DesktopUpdateUserDriver(
            hostBundle: .main,
            delegate: nil,
            updateReady: { readyCount += 1 },
            restartRequested: { restartCount += 1 },
            statusChanged: { _ in },
            confirmReady: { false }
        )

        let choice = await driver.showReadyToInstallAndRelaunch()
        #expect(choice == .dismiss)
        #expect(readyCount == 1)
        #expect(restartCount == 0)
    }

    @Test @MainActor func readyPromptRestartInstallsAndRecordsForegroundIntent() async {
        var restartCount = 0
        let driver = DesktopUpdateUserDriver(
            hostBundle: .main,
            delegate: nil,
            updateReady: {},
            restartRequested: { restartCount += 1 },
            statusChanged: { _ in },
            confirmReady: { true }
        )

        let choice = await driver.showReadyToInstallAndRelaunch()
        #expect(choice == .install)
        #expect(restartCount == 1)
    }

    @Test @MainActor func installingWhileAppRunsRecordsForegroundRestartButQuitInstallDoesNot() {
        var restartCount = 0
        let driver = DesktopUpdateUserDriver(
            hostBundle: .main,
            delegate: nil,
            updateReady: {},
            restartRequested: { restartCount += 1 },
            statusChanged: { _ in },
            confirmReady: { false }
        )

        driver.recordForegroundRestartIfNeeded(applicationTerminated: false)
        driver.recordForegroundRestartIfNeeded(applicationTerminated: true)

        #expect(restartCount == 1)
    }

    @Test @MainActor func automaticReadyLaterDefersAndRestartNowConsumesOneHandler() {
        let preferences = isolatedUpdatePreferences()
        let client = FakeDesktopUpdateClient(preferences: preferences)
        let confirmation = RestartConfirmationState()
        var installCount = 0
        var readyReminders: [String] = []
        let updater = DesktopUpdater(
            updaterFactory: { _, _ in client },
            preferences: preferences,
            presentReadyReminder: { readyReminders.append($0) },
            clearAvailableNotification: { _ in },
            confirmRestart: { confirmation.allowed }
        , registrationService: isolatedLoginRegistrationService())
        let publicKey = Data(repeating: 6, count: 32).base64EncodedString()
        updater.start(publicKey: publicKey, feed: DesktopUpdatePolicy.feedURL)

        #expect(updater.retainAutomaticInstallHandler(version: "0.3.0", handler: { installCount += 1 }))
        #expect(updater.isReady)
        #expect(readyReminders == ["0.3.0"])
        updater.restartToInstall()
        #expect(installCount == 0)
        #expect(!preferences.bool(forKey: DesktopUpdater.foregroundUpdateRelaunchKey))

        confirmation.allowed = true
        updater.restartToInstall()
        updater.restartToInstall()
        #expect(installCount == 1)
        #expect(preferences.string(forKey: "desktopUpdateRestartTargetVersion") == "0.3.0")
        #expect(preferences.bool(forKey: DesktopUpdater.foregroundUpdateRelaunchKey))
    }

    @Test @MainActor func ordinaryTerminationPersistsThePreparedUpdateVersion() {
        let preferences = isolatedUpdatePreferences()
        let updater = DesktopUpdater(
            updaterFactory: { _, _ in FakeDesktopUpdateClient(preferences: preferences) },
            preferences: preferences,
            presentReadyReminder: { _ in },
            clearAvailableNotification: { _ in }
        , registrationService: isolatedLoginRegistrationService())
        let publicKey = Data(repeating: 9, count: 32).base64EncodedString()
        updater.start(publicKey: publicKey, feed: DesktopUpdatePolicy.feedURL)
        #expect(updater.retainAutomaticInstallHandler(version: "0.3.1", handler: {}))

        updater.applicationWillTerminate()

        #expect(preferences.string(forKey: "desktopUpdateRestartTargetVersion") == "0.3.1")
    }

    @Test @MainActor func terminalUpdateFailureClearsReadyStateAndNotifications() {
        let preferences = isolatedUpdatePreferences()
        let client = FakeDesktopUpdateClient(preferences: preferences)
        var clearedVersions: [String] = []
        let updater = DesktopUpdater(
            updaterFactory: { _, _ in client },
            preferences: preferences,
            presentReadyReminder: { _ in },
            clearAvailableNotification: { _ in },
            clearUpdateNotifications: { clearedVersions.append($0) },
            confirmRestart: { true }
        , registrationService: isolatedLoginRegistrationService())
        let publicKey = Data(repeating: 7, count: 32).base64EncodedString()
        updater.start(publicKey: publicKey, feed: DesktopUpdatePolicy.feedURL)
        #expect(updater.retainAutomaticInstallHandler(version: "0.4.0", handler: {}))
        #expect(updater.isReady)
        preferences.set("0.4.0", forKey: "desktopUpdateRestartTargetVersion")
        preferences.set(true, forKey: DesktopUpdater.foregroundUpdateRelaunchKey)

        updater.handleUpdateFailure(domain: "NetworkError", code: -1009)

        #expect(!updater.isChecking)
        #expect(!updater.isReady)
        #expect(!updater.isReadyToastVisible)
        #expect(!updater.updateAvailable)
        #expect(updater.offeredVersion == nil)
        #expect(updater.statusMessage.contains("still available"))
        #expect(clearedVersions == ["0.4.0"])
        #expect(preferences.string(forKey: "desktopUpdateReadyReminderVersion") == nil)
        #expect(preferences.string(forKey: "desktopUpdateRestartTargetVersion") == nil)
        #expect(!preferences.bool(forKey: DesktopUpdater.foregroundUpdateRelaunchKey))
    }

    @Test @MainActor func benignNoUpdateAbortDoesNotClearCurrentUpdateState() {
        let preferences = isolatedUpdatePreferences()
        let client = FakeDesktopUpdateClient(preferences: preferences)
        var installCount = 0
        let updater = DesktopUpdater(
            updaterFactory: { _, _ in client },
            preferences: preferences,
            presentReadyReminder: { _ in },
            clearAvailableNotification: { _ in },
            confirmRestart: { true }
        , registrationService: isolatedLoginRegistrationService())
        let publicKey = Data(repeating: 8, count: 32).base64EncodedString()
        updater.start(publicKey: publicKey, feed: DesktopUpdatePolicy.feedURL)
        #expect(updater.retainAutomaticInstallHandler(version: "0.5.0", handler: { installCount += 1 }))

        updater.handleUpdateFailure(domain: "SUSparkleErrorDomain", code: 1001)
        updater.restartToInstall()

        #expect(updater.isReady)
        #expect(updater.offeredVersion == "0.5.0")
        #expect(updater.statusMessage.contains("ready"))
        #expect(installCount == 1)
    }

    @Test @MainActor func staleRestartIntentIsClearedWithoutReportingSuccess() {
        let preferences = isolatedUpdatePreferences()
        preferences.set("0.6.0", forKey: "desktopUpdateRestartTargetVersion")
        var clearedVersions: [String] = []
        let updater = DesktopUpdater(
            updaterFactory: { _, _ in FakeDesktopUpdateClient(preferences: preferences) },
            preferences: preferences,
            clearUpdateNotifications: { clearedVersions.append($0) },
            runningVersion: { "0.5.0" }
        , registrationService: isolatedLoginRegistrationService())

        updater.start(publicKey: nil, feed: nil)

        #expect(preferences.string(forKey: "desktopUpdateRestartTargetVersion") == nil)
        #expect(clearedVersions == ["0.6.0"])
        #expect(updater.completedUpdateVersion == nil)
        #expect(updater.statusMessage == "Update to version 0.6.0 didn't finish. Try again.")
    }

    @Test @MainActor func matchingRestartIntentReportsTheRunningVersion() {
        let preferences = isolatedUpdatePreferences()
        preferences.set("0.6.0", forKey: "desktopUpdateRestartTargetVersion")
        let updater = DesktopUpdater(
            updaterFactory: { _, _ in FakeDesktopUpdateClient(preferences: preferences) },
            preferences: preferences,
            clearUpdateNotifications: { _ in },
            runningVersion: { "0.6.0" }
        , registrationService: isolatedLoginRegistrationService())

        updater.start(publicKey: nil, feed: nil)

        #expect(preferences.string(forKey: "desktopUpdateRestartTargetVersion") == nil)
        #expect(updater.completedUpdateVersion == "0.6.0")
        #expect(updater.statusMessage == "Updated to 0.6.0.")
    }
}

@MainActor
private func isolatedUpdatePreferences() -> UserDefaults {
    UserDefaults(suiteName: "DesktopUpdaterTests-\(UUID().uuidString)")!
}

@Test(arguments: ["success", "cancel", "permission-restart-failure"]) @MainActor
func iMessageUpdaterJoinsSetupAndProviderBeforeReplacementAndFencesCanceledAttempt(outcome: String) async throws {
    let preferences = isolatedUpdatePreferences()
    var continuation: CheckedContinuation<Void, Never>?
    var events: [String] = []
    var installations = 0
    let updater = DesktopUpdater(updaterFactory: { _, _ in FakeDesktopUpdateClient(preferences: preferences) },
        preferences: preferences, presentReadyReminder: { _ in }, clearAvailableNotification: { _ in },
        clearUpdateNotifications: { _ in }, confirmRestart: { true },
        agentBridgeNeedsHandoff: { false }, prepareAgentBridgeUpdate: {
            events.append("existing-agents")
            if outcome == "permission-restart-failure" { throw AgentBridgeFailure.busy }
        },
        cancelAgentBridgeUpdate: {}, imessageNeedsHandoff: { true }, prepareIMessageUpdate: {
            events.append("imessage-start")
            await withCheckedContinuation { continuation = $0 }
            events.append("imessage-joined")
        }, registrationService: isolatedLoginRegistrationService())
    #expect(updater.retainAutomaticInstallHandler(version: "0.9.0", handler: { installations += 1; events.append("replace") }))
    if outcome == "permission-restart-failure" {
        #expect(try updater.restartForPermissionRepairIfNeeded())
        #expect(try updater.restartForPermissionRepairIfNeeded())
    } else {
        updater.restartToInstall()
        updater.restartToInstall()
    }
    while continuation == nil { await Task.yield() }
    #expect(!updater.admitsNativeIMessageOperations)
    #expect(installations == 0 && events == ["imessage-start"])
    if outcome == "cancel" { updater.cancelBackgroundUpdate() }
    continuation?.resume()
    if outcome == "cancel" {
        await updater.resumeBackgroundAgentsAfterCanceledUpdate()
        #expect(installations == 0)
        #expect(events == ["imessage-start", "imessage-joined"])
        #expect(!preferences.bool(forKey: DesktopUpdater.foregroundUpdateRelaunchKey))
        #expect(updater.admitsNativeIMessageOperations)
    } else if outcome == "permission-restart-failure" {
        while !updater.waitsForBackgroundAgents { await Task.yield() }
        #expect(installations == 0)
        #expect(events == ["imessage-start", "imessage-joined", "existing-agents"])
        #expect(!preferences.bool(forKey: DesktopUpdater.foregroundUpdateRelaunchKey))
    } else {
        while installations == 0 { await Task.yield() }
        #expect(installations == 1)
        #expect(events == ["imessage-start", "imessage-joined", "existing-agents", "replace"])
        #expect(preferences.bool(forKey: DesktopUpdater.foregroundUpdateRelaunchKey))
    }
}

@Test @MainActor func permissionRestartUsesReadyUpdateHandlerAndFailsClosedWithoutOne() throws {
    let preferences = isolatedUpdatePreferences()
    let updater = DesktopUpdater(updaterFactory: { _, _ in FakeDesktopUpdateClient(preferences: preferences) },
                                 preferences: preferences, presentReadyReminder: { _ in }, clearAvailableNotification: { _ in }, registrationService: isolatedLoginRegistrationService())
    #expect(try !updater.restartForPermissionRepairIfNeeded())
    updater.projectReady(version: "0.5.0", notifyWhenInactive: true)
    #expect(throws: CocoaError.self) { try updater.restartForPermissionRepairIfNeeded() }
    var installs = 0
    #expect(updater.retainAutomaticInstallHandler(version: "0.5.0", handler: { installs += 1 }))
    #expect(try updater.restartForPermissionRepairIfNeeded())
    #expect(try updater.restartForPermissionRepairIfNeeded())
    #expect(installs == 1)
    #expect(preferences.bool(forKey: DesktopUpdater.foregroundUpdateRelaunchKey))
}

@Test(arguments: ["failure", "skip", "benign"]) @MainActor func permissionRestartUpdaterTerminalOutcomeClearsOnlyPendingResume(_ outcome: String) throws {
    let suite = "DesktopUpdaterTests-resume-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let owner = DesktopApplicationRestart(defaults: preferences)
    var cancellations = 0
    let updater = DesktopUpdater(updaterFactory: { _, _ in FakeDesktopUpdateClient(preferences: preferences) },
        preferences: preferences, presentReadyReminder: { _ in }, clearAvailableNotification: { _ in },
        clearUpdateNotifications: { _ in }, cancelPermissionRestart: { cancellations += 1; owner.cancelPendingRestart() }, registrationService: isolatedLoginRegistrationService())
    #expect(updater.retainAutomaticInstallHandler(version: "0.6.0", handler: {}))
    try owner.request(applicationURL: URL(fileURLWithPath: "/Applications/PersonaStack.app"),
        installUpdate: { try updater.restartForPermissionRepairIfNeeded() }, start: { _ in Issue.record("Sparkle owns relaunch") })
    switch outcome {
    case "failure": updater.handleUpdateFailure(domain: "NetworkError", code: -1009)
    case "skip": updater.handleSkippedUpdate(version: "0.6.0")
    default: updater.handleUpdateFailure(domain: "SUSparkleErrorDomain", code: 1001)
    }
    #expect(cancellations == (outcome == "benign" ? 0 : 1))
    #expect(owner.consumeResumeHint() == (outcome == "benign"))
}

@Test(arguments: [false, true], ["success", "failure", "cancelled-follower", "unchanged"]) @MainActor
func iMessageUpdateAndPermissionRestartJoinKnownLoginRegistrationBeforeReplacement(permissionRestart: Bool, outcome: String) async throws {
    let fixture = try HeldLoginRegistrationFixture(outcome: outcome)
    fixture.start()
    let held = outcome != "unchanged"
    let entered = await fixture.waitForStartup(held: held)
    #expect(entered)
    guard entered else { await fixture.finish(); return }
    defer { fixture.release() }
    var followerEntered = false
    let follower = outcome == "cancelled-follower" ? fixture.follower { followerEntered = true } : nil
    if follower != nil {
        let enteredJoin = await loginLifecycleObserved { followerEntered }
        #expect(enteredJoin)
    }
    follower?.cancel()
    let preferences = isolatedUpdatePreferences()
    var installations = 0
    let updater = DesktopUpdater(updaterFactory: { _, _ in FakeDesktopUpdateClient(preferences: preferences) },
        preferences: preferences, presentReadyReminder: { _ in }, clearAvailableNotification: { _ in },
        clearUpdateNotifications: { _ in }, confirmRestart: { true }, agentBridgeNeedsHandoff: { false },
        prepareAgentBridgeUpdate: {}, cancelAgentBridgeUpdate: {}, imessageNeedsHandoff: { false },
        prepareIMessageUpdate: { Issue.record("Registration is independent of configured Messages") }, registrationService: fixture.service)
    #expect(updater.retainAutomaticInstallHandler(version: "0.99.0", handler: { installations += 1 }))
    if permissionRestart { _ = try updater.restartForPermissionRepairIfNeeded() }
    else { updater.restartToInstall() }
    if held {
        let reachedAdmission = await loginLifecycleObserved { !fixture.service.isAcceptingRegistrations || installations > 0 }
        #expect(reachedAdmission)
        #expect(installations == 0)
        #expect(fixture.service.hasPendingRegistration)
        #expect(!fixture.service.isAcceptingRegistrations)
        #expect(fixture.state.calls == ["unregister"])
    }
    fixture.release()
    _ = try? await fixture.startup?.value
    let installed = await loginLifecycleObserved { installations == 1 }
    #expect(installed)
    #expect(!fixture.service.hasPendingRegistration)
    #expect(fixture.state.calls == (held ? ["unregister", "register"] : []))
    if let follower {
        var cancelled = false
        do { _ = try await follower.value } catch is CancellationError { cancelled = true } catch {}
        #expect(cancelled)
    }
    await fixture.finish()
}

@Test @MainActor func iMessageCanceledUpdateCannotReopenAConcurrentTerminalLoginDrain() async throws {
    let fixture = try HeldLoginRegistrationFixture(outcome: "success")
    fixture.start()
    let entered = await fixture.waitForStartup(held: true)
    #expect(entered)
    guard entered else { await fixture.finish(); return }
    defer { fixture.release() }
    let preferences = isolatedUpdatePreferences()
    var replacements = 0, exits = 0
    let updater = DesktopUpdater(updaterFactory: { _, _ in FakeDesktopUpdateClient(preferences: preferences) },
        preferences: preferences, presentReadyReminder: { _ in }, clearAvailableNotification: { _ in },
        clearUpdateNotifications: { _ in }, confirmRestart: { true }, agentBridgeNeedsHandoff: { false },
        prepareAgentBridgeUpdate: {}, cancelAgentBridgeUpdate: {}, imessageNeedsHandoff: { false },
        prepareIMessageUpdate: {}, registrationService: fixture.service)
    #expect(updater.retainAutomaticInstallHandler(version: "0.99.0", handler: { replacements += 1 }))
    updater.restartToInstall()
    let closed = await loginLifecycleObserved { !fixture.service.isAcceptingRegistrations }
    #expect(closed && replacements == 0)
    let delegate = PersonaStackTerminationDelegate(shutdown: { true }, terminate: { _ in exits += 1 },
        timeout: .seconds(1), registrationService: fixture.service)
    #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
    updater.cancelBackgroundUpdate()
    let canceled = Task { await updater.resumeBackgroundAgentsAfterCanceledUpdate() }
    fixture.release()
    _ = try? await fixture.startup?.value
    await canceled.value
    let quitFinished = await loginLifecycleObserved { exits == 1 }
    #expect(quitFinished && replacements == 0)
    #expect(!fixture.service.isAcceptingRegistrations)
    #expect(!updater.admitsNativeIMessageOperations && !delegate.admitsNativeIMessageOperations)
    let denied = fixture.follower()
    var rejected = false
    do { _ = try await denied.value } catch { rejected = true }
    #expect(rejected)
    #expect(fixture.state.calls == ["unregister", "register"])
    await fixture.finish()
}

@Test @MainActor func iMessageFailedQuitDoesNotReleaseAnEarlierUpdateRegistrationClosure() async throws {
    let fixture = try HeldLoginRegistrationFixture(outcome: "success")
    fixture.start()
    let entered = await fixture.waitForStartup(held: true)
    #expect(entered)
    guard entered else { await fixture.finish(); return }
    defer { fixture.release() }
    let preferences = isolatedUpdatePreferences()
    var helperDrain: CheckedContinuation<Void, Never>?
    var replacements = 0, failures = 0
    let updater = DesktopUpdater(updaterFactory: { _, _ in FakeDesktopUpdateClient(preferences: preferences) },
        preferences: preferences, presentReadyReminder: { _ in }, clearAvailableNotification: { _ in },
        clearUpdateNotifications: { _ in }, confirmRestart: { true }, agentBridgeNeedsHandoff: { false },
        prepareAgentBridgeUpdate: { await withCheckedContinuation { helperDrain = $0 } },
        cancelAgentBridgeUpdate: {}, imessageNeedsHandoff: { false }, prepareIMessageUpdate: {}, registrationService: fixture.service)
    #expect(updater.retainAutomaticInstallHandler(version: "0.99.0", handler: { replacements += 1 }))
    updater.restartToInstall()
    let delegate = PersonaStackTerminationDelegate(shutdown: { false }, terminate: { _ in Issue.record("Cleanup failed") },
        timeout: .seconds(1), showCleanupFailure: { failures += 1 }, registrationService: fixture.service)
    #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
    fixture.release()
    _ = try? await fixture.startup?.value
    let helperEntered = await loginLifecycleObserved { helperDrain != nil }
    let quitFailed = await loginLifecycleObserved { failures == 1 }
    #expect(helperEntered && quitFailed)
    #expect(!fixture.service.isAcceptingRegistrations)
    #expect(!delegate.admitsNativeIMessageOperations)
    updater.cancelBackgroundUpdate()
    let canceled = Task { await updater.resumeBackgroundAgentsAfterCanceledUpdate() }
    helperDrain?.resume(); helperDrain = nil
    await canceled.value
    #expect(replacements == 0)
    #expect(fixture.service.isAcceptingRegistrations && delegate.admitsNativeIMessageOperations)
    await fixture.finish()
}

@Test(arguments: [false, true]) @MainActor
func iMessageUpdateFencesRuntimeBeforeJoiningHeldLoginRegistration(cancel: Bool) async throws {
    let fixture = try HeldLoginRegistrationFixture(outcome: "success")
    fixture.start()
    let entered = await fixture.waitForStartup(held: true)
    #expect(entered)
    guard entered else { await fixture.finish(); return }
    defer { fixture.release() }
    let preferences = isolatedUpdatePreferences()
    var events: [String] = [], replacements = 0
    let updater = DesktopUpdater(updaterFactory: { _, _ in FakeDesktopUpdateClient(preferences: preferences) },
        preferences: preferences, presentReadyReminder: { _ in }, clearAvailableNotification: { _ in },
        clearUpdateNotifications: { _ in }, confirmRestart: { true }, agentBridgeNeedsHandoff: { false },
        prepareAgentBridgeUpdate: { events.append("bridge") }, cancelAgentBridgeUpdate: { events.append("resume") },
        imessageNeedsHandoff: { true }, prepareIMessageUpdate: { events.append("imessage") }, registrationService: fixture.service)
    #expect(updater.retainAutomaticInstallHandler(version: "0.99.0", handler: { replacements += 1 }))
    updater.restartToInstall()
    let fenced = await loginLifecycleObserved { !events.isEmpty }
    #expect(fenced && events == ["imessage"])
    #expect(fixture.service.hasPendingRegistration && !fixture.service.isAcceptingRegistrations)
    #expect(fixture.state.calls == ["unregister"] && replacements == 0)
    if cancel { updater.cancelBackgroundUpdate() }
    let canceled = cancel ? Task { await updater.resumeBackgroundAgentsAfterCanceledUpdate() } : nil
    fixture.release()
    _ = try? await fixture.startup?.value
    if let canceled {
        await canceled.value
        #expect(replacements == 0 && events == ["imessage", "resume"])
        #expect(fixture.service.isAcceptingRegistrations)
    } else {
        let installed = await loginLifecycleObserved { replacements == 1 }
        #expect(installed && events == ["imessage", "bridge"])
    }
    await fixture.finish()
}
