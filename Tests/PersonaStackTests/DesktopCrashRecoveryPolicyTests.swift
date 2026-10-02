import Foundation
import PersonaStackCore
import Testing

@Suite
struct DesktopCrashRecoveryPolicyTests {
    private func preferences() throws -> (UserDefaults, String) {
        let suite = "DesktopCrashRecoveryPolicyTests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    @Test func onlyANewLoginSessionClearsIntentionalQuit() throws {
        let (preferences, suite) = try preferences()
        defer { preferences.removePersistentDomain(forName: suite) }

        #expect(DesktopCrashRecoveryPolicy.beginLoginSession("login-a", preferences: preferences))
        DesktopCrashRecoveryPolicy.suppressUntilNextLogin(preferences: preferences)

        #expect(!DesktopCrashRecoveryPolicy.beginLoginSession("login-a", preferences: preferences))
        #expect(!DesktopCrashRecoveryPolicy.shouldLaunchAtLogin(preferences: preferences))
        #expect(DesktopCrashRecoveryPolicy.beginLoginSession("login-b", preferences: preferences))
        #expect(DesktopCrashRecoveryPolicy.shouldLaunchAtLogin(preferences: preferences))
    }

    @Test func invalidLoginIdentifierDoesNotClearQuitSuppression() throws {
        let (preferences, suite) = try preferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        DesktopCrashRecoveryPolicy.suppressUntilNextLogin(preferences: preferences)

        #expect(!DesktopCrashRecoveryPolicy.beginLoginSession("", preferences: preferences))
        #expect(!DesktopCrashRecoveryPolicy.shouldLaunchAtLogin(preferences: preferences))
    }

    @Test(arguments: [
        (true, false, false, true),
        (false, false, false, false),
        (true, true, false, false),
        (true, false, true, false),
    ])
    func crashRestartRequiresActiveRelayAndNoQuit(_ enabled: Bool, _ paused: Bool,
                                                  _ quit: Bool, _ expected: Bool) throws {
        let (preferences, suite) = try preferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        if quit { DesktopCrashRecoveryPolicy.suppressUntilNextLogin(preferences: preferences) }

        #expect(DesktopCrashRecoveryPolicy.shouldRestartAfterUnexpectedExit(
            relayEnabled: enabled, relayPaused: paused, preferences: preferences) == expected)
    }

    @Test func explicitLaunchResumesCrashRecoveryWithoutChangingRelayPreferences() throws {
        let (preferences, suite) = try preferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(false, forKey: "relay-enabled")
        DesktopCrashRecoveryPolicy.suppressUntilNextLogin(preferences: preferences)

        DesktopCrashRecoveryPolicy.resumeAfterExplicitLaunch(preferences: preferences)

        #expect(DesktopCrashRecoveryPolicy.shouldLaunchAtLogin(preferences: preferences))
        #expect(!DesktopCrashRecoveryPolicy.shouldRestartAfterUnexpectedExit(
            relayEnabled: preferences.bool(forKey: "relay-enabled"), relayPaused: false,
            preferences: preferences))
    }

    @Test func updateTerminationPreservesRecoveryAndUserQuitSynchronizesSuppression() throws {
        let (preferences, suite) = try preferences()
        defer { preferences.removePersistentDomain(forName: suite) }

        DesktopCrashRecoveryPolicy.recordTerminationIntent(isUpdateRelaunch: true, preferences: preferences)
        #expect(DesktopCrashRecoveryPolicy.shouldLaunchAtLogin(preferences: preferences))

        DesktopCrashRecoveryPolicy.recordTerminationIntent(isUpdateRelaunch: false, preferences: preferences)
        #expect(!DesktopCrashRecoveryPolicy.shouldLaunchAtLogin(preferences: preferences))
    }
}
