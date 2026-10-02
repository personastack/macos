import Foundation

/// Stores only process-lifecycle intent. It never owns Desktop Control work.
public enum DesktopCrashRecoveryPolicy {
    public static let loginSessionKey = "desktopCrashRecoveryLoginSession"
    public static let quitSuppressedKey = "desktopCrashRecoveryQuitSuppressed"

    /// A new audit session is a new login. Relaunches of the supervisor keep
    /// the same audit session and therefore preserve an intentional Quit.
    @discardableResult
    public static func beginLoginSession(_ identifier: String,
                                         preferences: UserDefaults = .standard) -> Bool {
        _ = preferences.synchronize()
        guard !identifier.isEmpty else { return false }
        guard preferences.string(forKey: loginSessionKey) != identifier else { return false }
        preferences.set(identifier, forKey: loginSessionKey)
        preferences.set(false, forKey: quitSuppressedKey)
        _ = preferences.synchronize()
        return true
    }

    public static func suppressUntilNextLogin(preferences: UserDefaults = .standard) {
        preferences.set(true, forKey: quitSuppressedKey)
        _ = preferences.synchronize()
    }

    /// Update handoff exits must leave login recovery enabled. A user Quit
    /// remains suppressed across supervisor relaunches until the next login.
    public static func recordTerminationIntent(isUpdateRelaunch: Bool,
                                               preferences: UserDefaults = .standard) {
        guard !isUpdateRelaunch else { return }
        suppressUntilNextLogin(preferences: preferences)
    }

    /// A direct user launch or updater relaunch is fresh intent to run.
    public static func resumeAfterExplicitLaunch(preferences: UserDefaults = .standard) {
        preferences.set(false, forKey: quitSuppressedKey)
        _ = preferences.synchronize()
    }

    public static func shouldLaunchAtLogin(preferences: UserDefaults = .standard) -> Bool {
        _ = preferences.synchronize()
        return !preferences.bool(forKey: quitSuppressedKey)
    }

    public static func shouldRestartAfterUnexpectedExit(relayEnabled: Bool,
                                                        relayPaused: Bool,
                                                        preferences: UserDefaults = .standard) -> Bool {
        _ = preferences.synchronize()
        return relayEnabled && !relayPaused && !preferences.bool(forKey: quitSuppressedKey)
    }
}
