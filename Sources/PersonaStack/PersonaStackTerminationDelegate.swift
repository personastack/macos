import AppKit
import PersonaStackCore

@MainActor
final class PersonaStackTerminationDelegate: NSObject, NSApplicationDelegate {
    var reopenMainWindow: (@MainActor () -> Void)?
    private var shouldRestoreMainWindow = false
    private let shutdown: @MainActor () async -> Bool
    private let terminate: @MainActor (NSApplication) -> Void
    private let hasActiveSessions: @MainActor () -> Bool
    private let cancelPermissionRestart: @MainActor () -> Void
    private let showCleanupFailure: @MainActor () -> Void
    private let timeout: Duration
    private let recordQuitIntent: @MainActor () -> Void
    private let moveToMenuBar: @MainActor (NSApplication) -> Void
    private let hasMiniaturizedMainWindow: @MainActor () -> Bool
    private let navigateMainWindow: @MainActor (URL) -> Void
    private enum Phase { case idle, cleaning, admitted }
    private var phase = Phase.idle
    private var timeoutTask: Task<Void, Never>?

    override init() {
        shutdown = {
            await DesktopControlRuntime.shared.shutdownForQuit()
            return true
        }
        terminate = { $0.terminate(nil) }
        hasActiveSessions = { false }
        showCleanupFailure = {}
        cancelPermissionRestart = { DesktopApplicationRestart.shared.cancelPendingRestart() }
        timeout = .seconds(10)
        moveToMenuBar = Self.hideWindows
        hasMiniaturizedMainWindow = {
            NSApp.windows.contains { $0.title == "PersonaStack" && $0.isMiniaturized }
        }
        recordQuitIntent = {
            let preferences = UserDefaults.standard
            preferences.synchronize()
            DesktopCrashRecoveryPolicy.recordTerminationIntent(
                isUpdateRelaunch: preferences.bool(forKey: DesktopUpdater.foregroundUpdateRelaunchKey),
                preferences: preferences)
        }
        navigateMainWindow = { MainWebViewHost.shared.coordinator.start($0) }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DesktopLoginItemRegistration.enableOnFirstLaunch()
        DesktopNotificationCoordinator.shared.install()
        DesktopNotificationCoordinator.shared.installConcernNavigation { [weak self] in self?.openMainPage($0) }
        ChatWindowManager.shared.navigateMainWindow = { [weak self] in self?.openMainPage($0) }
        // The authenticated receiver belongs to the app, not Desktop Control
        // enrollment or the visible main window.
        _ = MainWebViewHost.shared
        DesktopUpdater.shared.start()
        Task { @MainActor in
            do { try await AgentBridgeUpdateHandoff.shared.restoreAtLaunch() }
            catch {
                UserDefaults.standard.set("Background agents could not resume after the update. Review Login Items and retry setup.",
                                          forKey: AgentBridgeService.errorKey)
            }
        }
        guard UserDefaults.standard.bool(forKey: DesktopUpdater.foregroundUpdateRelaunchKey)
                || DesktopApplicationRestart.resumesPermissionSetup else { return }
        UserDefaults.standard.removeObject(forKey: DesktopUpdater.foregroundUpdateRelaunchKey)
        _ = UserDefaults.standard.synchronize()
        shouldRestoreMainWindow = true
        NSApp.setActivationPolicy(.regular)
        Task { @MainActor [weak self] in
            await Task.yield()
            NSApp.activate(ignoringOtherApps: true)
            self?.restoreMainWindowIfNeeded()
        }
    }

    func installMainWindowReopener(_ action: @escaping @MainActor () -> Void) {
        reopenMainWindow = action
        restoreMainWindowIfNeeded()
    }

    func openMainPage(_ destination: URL) {
        navigateMainWindow(destination)
        shouldRestoreMainWindow = true
        restoreMainWindowIfNeeded()
    }

    private func restoreMainWindowIfNeeded() {
        guard shouldRestoreMainWindow, let reopenMainWindow else { return }
        shouldRestoreMainWindow = false
        reopenMainWindow()
    }

    init(shutdown: @escaping @MainActor () async -> Bool,
         terminate: @escaping @MainActor (NSApplication) -> Void,
         timeout: Duration,
         hasActiveSessions: @escaping @MainActor () -> Bool = { false },
         showCleanupFailure: @escaping @MainActor () -> Void = {},
         cancelPermissionRestart: @escaping @MainActor () -> Void = {},
         recordQuitIntent: @escaping @MainActor () -> Void = {},
         moveToMenuBar: @escaping @MainActor (NSApplication) -> Void = PersonaStackTerminationDelegate.hideWindows,
         navigateMainWindow: @escaping @MainActor (URL) -> Void = { MainWebViewHost.shared.coordinator.start($0) },
         hasMiniaturizedMainWindow: @escaping @MainActor () -> Bool = {
             NSApp.windows.contains { $0.title == "PersonaStack" && $0.isMiniaturized }
         }) {
        self.shutdown = shutdown
        self.terminate = terminate
        self.timeout = timeout
        self.hasActiveSessions = hasActiveSessions
        self.showCleanupFailure = showCleanupFailure
        self.cancelPermissionRestart = cancelPermissionRestart
        self.recordQuitIntent = recordQuitIntent
        self.moveToMenuBar = moveToMenuBar
        self.hasMiniaturizedMainWindow = hasMiniaturizedMainWindow
        self.navigateMainWindow = navigateMainWindow
        super.init()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard hasMiniaturizedMainWindow(), let reopenMainWindow else { return }
        reopenMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let reopenMainWindow else { return true }
        reopenMainWindow()
        return false
    }

    /// Cmd-Q changes presentation only. Explicit Quit, system termination,
    /// permission restarts and updates retain the normal cleanup path.
    func closeToMenuBar(_ sender: NSApplication) {
        guard phase == .idle else { return }
        moveToMenuBar(sender)
    }

    private static func hideWindows(_ application: NSApplication) {
        application.hide(nil)
        application.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if phase == .admitted { return .terminateNow }
        guard phase == .idle else { return .terminateCancel }
        guard DesktopUpdater.shared.allowsTermination() else { return .terminateCancel }
        DesktopUpdater.shared.applicationWillTerminate()
        phase = .cleaning
        Task { @MainActor in
            let cleaned = await shutdown()
            guard phase == .cleaning else { return }
            if cleaned { finish(sender) }
            else {
                timeoutTask?.cancel()
                timeoutTask = nil
                phase = .idle
                cancelPermissionRestart()
                showCleanupFailure()
            }
        }
        timeoutTask = Task { @MainActor in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard phase == .cleaning else { return }
            if hasActiveSessions() { showCleanupFailure() }
            else { finish(sender) }
        }
        // AppKit's terminateLater loop starves main-actor Tasks. Cancel this
        // request so cleanup runs normally, then admit one fresh termination.
        return .terminateCancel
    }

    private func finish(_ sender: NSApplication) {
        guard phase == .cleaning else { return }
        phase = .admitted
        timeoutTask?.cancel()
        timeoutTask = nil
        recordQuitIntent()
        terminate(sender)
    }
}
