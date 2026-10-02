import Foundation
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
        let updater = DesktopUpdater(updaterFactory: { _, _ in client }, preferences: preferences)
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
        )
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
        )
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
        )
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
        )
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
            )
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
        )
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
        )
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
        )
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
        )
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
        let updater = DesktopUpdater(updaterFactory: { _, _ in client }, preferences: preferences)
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
        )
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
        )
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
        )
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
        )
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
        )

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
        )

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

@Test @MainActor func permissionRestartUsesReadyUpdateHandlerAndFailsClosedWithoutOne() throws {
    let preferences = isolatedUpdatePreferences()
    let updater = DesktopUpdater(updaterFactory: { _, _ in FakeDesktopUpdateClient(preferences: preferences) },
                                 preferences: preferences, presentReadyReminder: { _ in }, clearAvailableNotification: { _ in })
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
