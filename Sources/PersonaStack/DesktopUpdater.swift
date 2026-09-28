import AppKit
import Combine
import Foundation
import PersonaStackCore
import Sparkle
import SwiftUI

enum ScheduledUpdateStage: Sendable {
    case notDownloaded
    case downloaded
    case installing
}

@MainActor
protocol DesktopUpdateClient: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyDownloadsUpdates: Bool { get set }
    func start() throws
    func checkForUpdates()
}

@MainActor
private final class SparkleUpdateClient: DesktopUpdateClient {
    private let updater: SPUUpdater

    init(hostBundle: Bundle, userDriver: SPUStandardUserDriver, delegate: SPUUpdaterDelegate) {
        updater = SPUUpdater(hostBundle: hostBundle, applicationBundle: hostBundle, userDriver: userDriver, delegate: delegate)
    }

    var canCheckForUpdates: Bool { updater.canCheckForUpdates }
    var automaticallyDownloadsUpdates: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set { updater.automaticallyDownloadsUpdates = newValue }
    }

    func start() throws { try updater.start() }
    func checkForUpdates() { updater.checkForUpdates() }
}

@MainActor
final class DesktopUpdater: NSObject, ObservableObject {
    static let shared = DesktopUpdater()

    @Published private(set) var isAvailable = false
    @Published private(set) var updateAvailable = false
    @Published private(set) var isChecking = false
    @Published private(set) var isAutomaticallyDownloading = false
    @Published private(set) var isWaitingForApproval = false
    @Published private(set) var isInformationalUpdate = false
    @Published private(set) var isReady = false
    @Published private(set) var isAvailableToastVisible = false
    @Published private(set) var isReadyToastVisible = false
    @Published private(set) var completedUpdateVersion: String?
    @Published private(set) var offeredVersion: String?
    @Published private(set) var applicationsInstallInstruction: String?
    @Published private(set) var statusMessage = ""
    private let updaterFactory: (SPUStandardUserDriver, SPUUpdaterDelegate) -> any DesktopUpdateClient
    private let preferences: UserDefaults
    private let presentAvailableReminder: (@MainActor (String) -> Void)?
    private let presentReadyReminder: (@MainActor (String) -> Void)?
    private let clearAvailableNotification: @MainActor (String) -> Void
    private let clearUpdateNotifications: @MainActor (String) -> Void
    private let runningVersion: @MainActor () -> String?
    private let confirmRestart: @MainActor () -> Bool
    private let presentApplicationsInstallInstruction: @MainActor (String) -> Void
    private var updater: (any DesktopUpdateClient)?
    private var userDriver: SPUStandardUserDriver?
    private var didStart = false
    private var activeUpdateCheck: SPUUpdateCheck = .updates
    private var immediateInstallHandler: (() -> Void)?
    private var isImmediateInstallRequested = false

    private override convenience init() {
        self.init(updaterFactory: { SparkleUpdateClient(hostBundle: .main, userDriver: $0, delegate: $1) })
    }

    init(updaterFactory: @escaping (SPUStandardUserDriver, SPUUpdaterDelegate) -> any DesktopUpdateClient,
         preferences: UserDefaults = .standard,
         presentAvailableReminder: (@MainActor (String) -> Void)? = nil,
         presentReadyReminder: (@MainActor (String) -> Void)? = nil,
         clearAvailableNotification: @escaping @MainActor (String) -> Void = {
             DesktopNotificationCoordinator.shared.clearAvailableNotification(version: $0)
         },
         clearUpdateNotifications: @escaping @MainActor (String) -> Void = {
             DesktopNotificationCoordinator.shared.clearUpdateNotifications(version: $0)
         },
         runningVersion: @escaping @MainActor () -> String? = {
             Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
         },
         confirmRestart: @escaping @MainActor () -> Bool = DesktopUpdater.confirmReadyRestart,
         presentApplicationsInstallInstruction: @escaping @MainActor (String) -> Void = DesktopUpdater.showApplicationsInstallInstruction) {
        self.updaterFactory = updaterFactory
        self.preferences = preferences
        self.presentAvailableReminder = presentAvailableReminder
        self.presentReadyReminder = presentReadyReminder
        self.clearAvailableNotification = clearAvailableNotification
        self.clearUpdateNotifications = clearUpdateNotifications
        self.runningVersion = runningVersion
        self.confirmRestart = confirmRestart
        self.presentApplicationsInstallInstruction = presentApplicationsInstallInstruction
        super.init()
    }

    func start() {
        let bundleURL = Bundle.main.bundleURL
        let isReadOnly = (try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false
        start(publicKey: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              feed: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              bundleURL: bundleURL,
              volumeIsReadOnly: isReadOnly)
    }

    func start(publicKey: String?, feed: String?, bundleURL: URL? = nil, volumeIsReadOnly: Bool = false) {
        guard !didStart else { return }
        if let bundleURL, DesktopUpdatePolicy.requiresApplicationsInstall(bundleURL: bundleURL,
                                                                          volumeIsReadOnly: volumeIsReadOnly) {
            applicationsInstallInstruction = Self.applicationsInstallMessage
        }
        showCompletedUpdateIfPresent()
        if applicationsInstallInstruction != nil {
            return
        }
        guard DesktopUpdatePolicy.hasTrustedFeed(publicKey: publicKey, feed: feed) else { return }
        let driver = DesktopUpdateUserDriver(hostBundle: .main, delegate: self, updateReady: { [weak self] in
            guard let self else { return }
            projectReady(version: offeredVersion, notifyWhenInactive: false)
        }, restartRequested: { [weak self] in
            self?.requestForegroundRestart()
        }, statusChanged: { [weak self] status in
            self?.projectDownloadProgress(status)
        }, confirmReady: Self.confirmReadyRestart)
        let updater = updaterFactory(driver, self)
        userDriver = driver
        self.updater = updater
        do {
            try updater.start()
            didStart = true
            isAvailable = true
        } catch {
            self.updater = nil
            userDriver = nil
            statusMessage = "Automatic updates couldn't start. Check the connection and try again."
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { updater?.automaticallyDownloadsUpdates ?? preferences.bool(forKey: "SUAutomaticallyUpdate") }
        set {
            preferences.set(newValue, forKey: "SUAutomaticallyUpdate")
            updater?.automaticallyDownloadsUpdates = newValue
            objectWillChange.send()
        }
    }

    var canCheckForUpdates: Bool {
        !isReady && !isAutomaticallyDownloading &&
            (updateAvailable || ((updater?.canCheckForUpdates ?? false) && !isChecking))
    }

    func checkForUpdates() {
        guard !isReady, !isAutomaticallyDownloading else { return }
        if updateAvailable {
            isAvailableToastVisible = false
            statusMessage = "Opening the update confirmation…"
            updater?.checkForUpdates()
            return
        }
        guard (updater?.canCheckForUpdates ?? false) && !isChecking else { return }
        isChecking = true
        statusMessage = "Checking for updates…"
        updater?.checkForUpdates()
    }

    func downloadLatestUpdate() {
        guard updateAvailable, !isReady else { return }
        checkForUpdates()
    }

    func dismissAvailableToast() {
        isAvailableToastVisible = false
    }

    func dismissReadyToast() {
        isReadyToastVisible = false
    }

    func dismissCompletedToast() {
        completedUpdateVersion = nil
    }

    func projectDownloadProgress(_ status: String) {
        statusMessage = status
    }

    func restartToInstall() {
        guard isReady else { return }
        if let applicationsInstallInstruction {
            statusMessage = applicationsInstallInstruction
            presentApplicationsInstallInstruction(applicationsInstallInstruction)
            return
        }
        guard let immediateInstallHandler else {
            statusMessage = "Opening the update confirmation…"
            updater?.checkForUpdates()
            return
        }
        guard confirmRestart() else {
            isReadyToastVisible = false
            return
        }
        requestForegroundRestart()
        isReadyToastVisible = false
        guard !isImmediateInstallRequested else { return }
        isImmediateInstallRequested = true
        immediateInstallHandler()
    }

    func applicationWillTerminate() {
        if isReady { rememberRestartTarget() }
    }

    func projectReady(version: String?, notifyWhenInactive: Bool) {
        let isNewReadyTransition = DesktopUpdatePolicy.shouldProjectReady(
            isReady: isReady,
            currentVersion: offeredVersion,
            offeredVersion: version
        )
        guard isNewReadyTransition else { return }
        isReady = true
        isWaitingForApproval = false
        isInformationalUpdate = false
        isAvailableToastVisible = false
        statusMessage = "Version \(version ?? "the new release") is ready. Restart to finish updating."
        isReadyToastVisible = !notifyWhenInactive || hasVisibleMainWindow
        guard let version else { return }
        clearAvailableNotification(version)
        let key = "desktopUpdateReadyReminderVersion"
        guard DesktopUpdatePolicy.shouldPresentReminder(
            version: version,
            lastPresentedVersion: preferences.string(forKey: key)
        ) else { return }
        preferences.set(version, forKey: key)
        if notifyWhenInactive && !hasVisibleMainWindow {
            if let presentReadyReminder {
                presentReadyReminder(version)
            } else {
                DesktopNotificationCoordinator.shared.postUpdateReady(version: version)
            }
        }
    }

    private var hasVisibleMainWindow: Bool {
        guard let app = NSApp else { return false }
        return app.isActive && app.windows.contains { $0.title == "PersonaStack" && $0.isVisible }
    }

    static func confirmReadyRestart() -> Bool {
        let alert = NSAlert()
        alert.messageText = "PersonaStack is ready to update"
        alert.informativeText = "Restarting closes PersonaStack windows and stops active Desktop Control tasks. You can restart now or install the update the next time you quit."
        alert.addButton(withTitle: "Restart Now")
        alert.addButton(withTitle: "Later")
        alert.alertStyle = .informational
        return alert.runModal() == .alertFirstButtonReturn
    }

    static let applicationsInstallMessage = "This copy can't install updates from a read-only disk image or App Translocation. Quit PersonaStack, drag PersonaStack.app to Applications, then open it from Applications."

    static func showApplicationsInstallInstruction(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Move PersonaStack to Applications to install updates"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.alertStyle = .informational
        alert.runModal()
    }

    private func rememberRestartTarget() {
        guard let offeredVersion else { return }
        preferences.set(offeredVersion, forKey: "desktopUpdateRestartTargetVersion")
    }

    private func requestForegroundRestart() {
        rememberRestartTarget()
        preferences.set(true, forKey: Self.foregroundUpdateRelaunchKey)
    }

    static let foregroundUpdateRelaunchKey = "desktopUpdateForegroundRelaunch"

    private func showCompletedUpdateIfPresent() {
        let key = "desktopUpdateRestartTargetVersion"
        guard let target = preferences.string(forKey: key) else { return }
        preferences.removeObject(forKey: key)
        clearUpdateNotifications(target)
        guard DesktopUpdatePolicy.didCompleteRestart(
            targetVersion: target,
            runningVersion: runningVersion()
        ) else {
            statusMessage = "Update to version \(target) didn't finish. Try again."
            return
        }
        statusMessage = "Updated to \(target)."
        completedUpdateVersion = target
    }
}

@MainActor
final class DesktopUpdateUserDriver: SPUStandardUserDriver {
    private let updateReady: @MainActor () -> Void
    private let restartRequested: @MainActor () -> Void
    private let statusChanged: @MainActor (String) -> Void
    private let confirmReady: @MainActor () -> Bool
    private var expectedDownloadBytes: UInt64 = 0
    private var downloadedBytes: UInt64 = 0

    init(hostBundle: Bundle,
         delegate: (any SPUStandardUserDriverDelegate)?,
         updateReady: @escaping @MainActor () -> Void,
         restartRequested: @escaping @MainActor () -> Void,
         statusChanged: @escaping @MainActor (String) -> Void,
         confirmReady: @escaping @MainActor () -> Bool) {
        self.updateReady = updateReady
        self.restartRequested = restartRequested
        self.statusChanged = statusChanged
        self.confirmReady = confirmReady
        super.init(hostBundle: hostBundle, delegate: delegate)
    }

    override func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedDownloadBytes = 0
        downloadedBytes = 0
        statusChanged("Downloading update…")
        super.showDownloadInitiated(cancellation: cancellation)
    }

    override func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedDownloadBytes = expectedContentLength
        super.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
    }

    override func showDownloadDidReceiveData(ofLength length: UInt64) {
        downloadedBytes += length
        if expectedDownloadBytes > 0 {
            let percent = min(100, Int((downloadedBytes * 100) / expectedDownloadBytes))
            statusChanged("Downloading update… \(percent)%")
        }
        super.showDownloadDidReceiveData(ofLength: length)
    }

    override func showDownloadDidStartExtractingUpdate() {
        statusChanged("Preparing update…")
        super.showDownloadDidStartExtractingUpdate()
    }

    override func showExtractionReceivedProgress(_ progress: Double) {
        statusChanged("Preparing update… \(Int(progress * 100))%")
        super.showExtractionReceivedProgress(progress)
    }

    override func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                                       retryTerminatingApplication: @escaping () -> Void) {
        recordForegroundRestartIfNeeded(applicationTerminated: applicationTerminated)
        super.showInstallingUpdate(withApplicationTerminated: applicationTerminated,
                                   retryTerminatingApplication: retryTerminatingApplication)
    }

    func recordForegroundRestartIfNeeded(applicationTerminated: Bool) {
        if !applicationTerminated { restartRequested() }
    }

    override func showReadyToInstallAndRelaunch() async -> SPUUserUpdateChoice {
        super.dismissUpdateInstallation()
        updateReady()
        guard confirmReady() else { return .dismiss }
        restartRequested()
        return .install
    }
}

extension DesktopUpdater: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        projectFoundUpdate(
            version: item.displayVersionString,
            isScheduled: activeUpdateCheck == .updatesInBackground,
            isInformational: item.isInformationOnlyUpdate
        )
    }

    func projectFoundUpdate(version: String, isScheduled: Bool, isInformational: Bool = false) {
        isChecking = false
        offeredVersion = version
        isInformationalUpdate = isInformational
        isAutomaticallyDownloading = isScheduled && automaticallyDownloadsUpdates && !isInformational
        isWaitingForApproval = false
        updateAvailable = !isAutomaticallyDownloading
        if isAutomaticallyDownloading {
            statusMessage = "Downloading version \(version) in the background…"
            isAvailableToastVisible = false
            return
        }
        statusMessage = isInformational
            ? "PersonaStack \(version) has update information."
            : "PersonaStack \(version) is available."
        guard isScheduled else { return }
        presentScheduledAvailableReminder(version)
    }

    func projectScheduledUpdateRequiringAction(version: String, stage: ScheduledUpdateStage) {
        guard isAutomaticallyDownloading, !isReady else { return }
        isChecking = false
        isAutomaticallyDownloading = false
        isWaitingForApproval = true
        isInformationalUpdate = false
        updateAvailable = true
        offeredVersion = version
        switch stage {
        case .notDownloaded:
            statusMessage = "PersonaStack \(version) needs your approval to continue the update."
        case .downloaded:
            statusMessage = "PersonaStack \(version) is downloaded and needs your approval to install."
        case .installing:
            statusMessage = "PersonaStack \(version) needs your approval to finish installing."
        }
        presentScheduledAvailableReminder(version)
    }

    private func presentScheduledAvailableReminder(_ version: String) {
        let key = "desktopUpdateAvailableReminderVersion"
        guard DesktopUpdatePolicy.shouldPresentReminder(
            version: version,
            lastPresentedVersion: preferences.string(forKey: key)
        ) else { return }
        preferences.set(version, forKey: key)
        if let presentAvailableReminder {
            presentAvailableReminder(version)
        } else if hasVisibleMainWindow {
            isAvailableToastVisible = true
        } else {
            DesktopNotificationCoordinator.shared.postUpdateAvailable(version: version)
        }
    }

    func updater(_ updater: SPUUpdater,
                 willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        retainAutomaticInstallHandler(version: item.displayVersionString, handler: immediateInstallHandler)
    }

    func updater(_ updater: SPUUpdater,
                 userDidMake choice: SPUUserUpdateChoice,
                 forUpdate updateItem: SUAppcastItem,
                 state: SPUUserUpdateState) {
        guard choice == .skip else { return }
        handleSkippedUpdate(version: updateItem.displayVersionString)
    }

    func retainAutomaticInstallHandler(version: String, handler: @escaping () -> Void) -> Bool {
        offeredVersion = version
        isAutomaticallyDownloading = false
        immediateInstallHandler = handler
        isImmediateInstallRequested = false
        projectReady(version: version, notifyWhenInactive: true)
        return true
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        activeUpdateCheck = updateCheck
        isChecking = true
        if updateCheck == .updatesInBackground {
            statusMessage = "Checking for updates…"
        }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        isChecking = false
        isAutomaticallyDownloading = false
        isWaitingForApproval = false
        isInformationalUpdate = false
        guard !isReady else { return }
        updateAvailable = false
        isReady = false
        offeredVersion = nil
        let sparkleError = error as NSError
        let userInitiated = (sparkleError.userInfo[SPUNoUpdateFoundUserInitiatedKey] as? NSNumber)?.boolValue
            ?? (activeUpdateCheck == .updates)
        let reason = noUpdateReason(sparkleError.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)
        switch DesktopUpdatePolicy.checkResult(errorDomain: sparkleError.domain,
                                               errorCode: sparkleError.code,
                                               noUpdateReason: reason) {
        case .upToDate:
            statusMessage = userInitiated ? "You're up to date." : ""
        case .noCompatibleUpdate:
            statusMessage = "No compatible update is available for this version of macOS."
        case .unavailable:
            statusMessage = "Update availability couldn't be determined. Try again later."
        case .failed:
            statusMessage = "Couldn't check for updates. Check your connection and try again."
        }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        isChecking = false
        activeUpdateCheck = .updates
    }

    func userDidCancelDownload(_ updater: SPUUpdater) {
        handleDownloadCancellation()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let sparkleError = error as NSError
        handleUpdateFailure(domain: sparkleError.domain, code: sparkleError.code)
    }

    func handleUpdateFailure(domain: String, code: Int) {
        isChecking = false
        isAutomaticallyDownloading = false
        isWaitingForApproval = false
        isInformationalUpdate = false
        guard domain != SUSparkleErrorDomain || code != 1001 else { return }
        immediateInstallHandler = nil
        isImmediateInstallRequested = false
        statusMessage = "Update couldn't finish. PersonaStack is still available. Try again."
        if let offeredVersion {
            clearUpdateNotifications(offeredVersion)
            preferences.removeObject(forKey: "desktopUpdateReadyReminderVersion")
            if preferences.string(forKey: "desktopUpdateRestartTargetVersion") == offeredVersion {
                preferences.removeObject(forKey: "desktopUpdateRestartTargetVersion")
                preferences.removeObject(forKey: Self.foregroundUpdateRelaunchKey)
            }
        }
        isReady = false
        isReadyToastVisible = false
        isAvailableToastVisible = false
        updateAvailable = false
        offeredVersion = nil
    }

    func handleDownloadCancellation() {
        isChecking = false
        isAutomaticallyDownloading = false
        isWaitingForApproval = false
        isInformationalUpdate = false
        statusMessage = "Update download canceled."
    }

    func handleSkippedUpdate(version: String) {
        guard offeredVersion == version else { return }
        isChecking = false
        isAutomaticallyDownloading = false
        isWaitingForApproval = false
        isInformationalUpdate = false
        isReady = false
        isReadyToastVisible = false
        isAvailableToastVisible = false
        updateAvailable = false
        immediateInstallHandler = nil
        isImmediateInstallRequested = false
        offeredVersion = nil
        statusMessage = "Version \(version) was skipped."
        clearUpdateNotifications(version)
        for key in ["desktopUpdateAvailableReminderVersion", "desktopUpdateReadyReminderVersion"] {
            if preferences.string(forKey: key) == version { preferences.removeObject(forKey: key) }
        }
        if preferences.string(forKey: "desktopUpdateRestartTargetVersion") == version {
            preferences.removeObject(forKey: "desktopUpdateRestartTargetVersion")
            preferences.removeObject(forKey: Self.foregroundUpdateRelaunchKey)
        }
    }

    private func noUpdateReason(_ value: NSNumber?) -> DesktopUpdatePolicy.NoUpdateReason? {
        guard let value else { return nil }
        switch Int32(value.intValue) {
        case SPUNoUpdateFoundReason.onLatestVersion.rawValue,
             SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue:
            return .currentVersion
        case SPUNoUpdateFoundReason.systemIsTooOld.rawValue,
             SPUNoUpdateFoundReason.systemIsTooNew.rawValue,
             SPUNoUpdateFoundReason.hardwareDoesNotSupportARM64.rawValue:
            return .incompatible
        default:
            return .unknown
        }
    }
}

extension DesktopUpdater: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate, !state.userInitiated else { return }
        let stage: ScheduledUpdateStage
        switch state.stage {
        case .notDownloaded: stage = .notDownloaded
        case .downloaded: stage = .downloaded
        case .installing: stage = .installing
        @unknown default: stage = .notDownloaded
        }
        let version = update.displayVersionString
        Task { @MainActor [weak self] in
            self?.projectScheduledUpdateRequiringAction(version: version, stage: stage)
        }
    }
}

struct DesktopUpdateCommands: Commands {
    @ObservedObject private var updater = DesktopUpdater.shared

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.isAvailable || !updater.canCheckForUpdates)
        }
    }
}

struct DesktopUpdatesMenuSection: View {
    @ObservedObject private var updater = DesktopUpdater.shared

    var body: some View {
        Section("Updates") {
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")")
            if let instruction = updater.applicationsInstallInstruction {
                Text(instruction).font(.caption)
            }
            if !updater.statusMessage.isEmpty { Text(updater.statusMessage).font(.caption) }
            if updater.isReady {
                Button("Restart Now") { updater.restartToInstall() }
                Button("Later") { updater.dismissReadyToast() }
            }
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.isAvailable || !updater.canCheckForUpdates || updater.isChecking)
            Button(updateActionTitle) { updater.downloadLatestUpdate() }
                .disabled(!updater.isAvailable || !updater.updateAvailable || updater.isReady)
            Toggle("Automatically Install Updates", isOn: Binding(
                get: { updater.automaticallyDownloadsUpdates },
                set: { updater.automaticallyDownloadsUpdates = $0 }
            ))
            .disabled(!updater.isAvailable)
            .help(automaticDownloadsHelp)
        }
    }

    private var updateActionTitle: String {
        if updater.isInformationalUpdate { return "View Update Information…" }
        return updater.isWaitingForApproval ? "Continue Update…" : "Download Latest Update…"
    }

    private var automaticDownloadsHelp: String {
        if updater.applicationsInstallInstruction != nil {
            return "Updates are paused in this location. Your saved preference resumes when you open PersonaStack from Applications."
        }
        return "Downloads updates in the background and installs them when PersonaStack quits. It never restarts the app automatically."
    }
}

struct DesktopUpdateToast: View {
    @ObservedObject private var updater = DesktopUpdater.shared

    var body: some View {
        let isReady = updater.isReadyToastVisible
        let isCompleted = updater.completedUpdateVersion != nil
        if isReady || updater.isAvailableToastVisible || isCompleted {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isCompleted ? "PersonaStack updated" : (isReady ? "PersonaStack is ready to update" : "PersonaStack update available"))
                        .font(.headline)
                    Text(isCompleted
                         ? "You're now running version \(updater.completedUpdateVersion ?? "new")."
                         : (isReady
                            ? "Restart to install version \(updater.offeredVersion ?? "new")."
                            : (updater.isInformationalUpdate
                                ? "Version \(updater.offeredVersion ?? "new") has release information."
                                : (updater.isWaitingForApproval
                                    ? "Version \(updater.offeredVersion ?? "new") needs your approval to continue."
                                    : "Version \(updater.offeredVersion ?? "new") is ready to download."))))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if !isCompleted {
                    Button(availableActionTitle) {
                        if isReady { updater.restartToInstall() } else { updater.downloadLatestUpdate() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button(isCompleted ? "Close" : "Later") {
                    if isCompleted { updater.dismissCompletedToast() }
                    else if isReady { updater.dismissReadyToast() }
                    else { updater.dismissAvailableToast() }
                }
                .buttonStyle(.bordered)
            }
            .padding(16)
            .frame(maxWidth: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
            .shadow(radius: 12, y: 4)
            .accessibilityElement(children: .contain)
        }
    }

    private var availableActionTitle: String {
        if updater.isReady { return "Restart Now" }
        if updater.isInformationalUpdate { return "View Details…" }
        return updater.isWaitingForApproval ? "Continue Update…" : "Download Update…"
    }
}
