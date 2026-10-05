import AppKit
import Foundation
@testable import PersonaStack
import PersonaStackCore
import Testing

@MainActor
private final class FakeCrashRecoveryProcessRunner: DesktopCrashRecoveryProcessRunning {
    var processIDs: [pid_t] = []
    var runningChildIDs: [pid_t] = []
    var launchedArguments: [[String]] = []
    var nextPID: pid_t = 9001
    var failedLaunchesRemaining = 0
    var onApplicationChange: (@MainActor () -> Void)?

    func observeApplicationChanges(_ onChange: @escaping @MainActor () -> Void) {
        onApplicationChange = onChange
    }

    func ownsRunningProcess(processID: pid_t) -> Bool {
        runningChildIDs.contains(processID)
    }

    func applicationProcessIDs(bundleIdentifier: String) -> [pid_t] {
        #expect(bundleIdentifier == "ai.personastack.desktop")
        return processIDs
    }

    func launchApplication(at bundleURL: URL, arguments: [String],
                           onTermination: @escaping @MainActor (pid_t) -> Void) -> pid_t? {
        #expect(bundleURL.pathExtension == "app")
        launchedArguments.append(arguments)
        if failedLaunchesRemaining > 0 {
            failedLaunchesRemaining -= 1
            return nil
        }
        processIDs.append(nextPID)
        return nextPID
    }
}

@Suite @MainActor
struct DesktopCrashRecoverySupervisorTests {
    private func makePreferences() throws -> (UserDefaults, String) {
        let suite = "DesktopCrashRecoverySupervisorTests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    @Test func directAccessoryRelaunchAfterQuitIsAdoptedAndItsCrashRestartsOnce() throws {
        let (preferences, suite) = try makePreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let runner = FakeCrashRecoveryProcessRunner()
        runner.processIDs = [9001]
        runner.nextPID = 9010
        var scheduled: [(TimeInterval, @MainActor () -> Void)] = []
        let supervisor = DesktopCrashRecoverySupervisor(preferences: preferences, processRunner: runner,
            bundleURL: URL(fileURLWithPath: "/Applications/PersonaStack.app"),
            bundleIdentifier: "ai.personastack.desktop", loginSessionID: { "login-1" },
            shouldRestartForRelay: { true }, schedule: { scheduled.append(($0, $1)) })
        supervisor.start()
        scheduled.removeAll()

        DesktopCrashRecoveryPolicy.suppressUntilNextLogin(preferences: preferences)
        runner.processIDs = []
        runner.onApplicationChange?()
        #expect(scheduled.isEmpty)

        DesktopCrashRecoveryPolicy.resumeAfterExplicitLaunch(preferences: preferences)
        runner.processIDs = [9002]
        runner.onApplicationChange?()
        #expect(scheduled.map(\.0) == [120])
        scheduled.removeAll()

        // A short-lived duplicate never replaces the running owner.
        runner.processIDs = [9002, 9003]
        runner.onApplicationChange?()
        runner.processIDs = [9002]
        runner.onApplicationChange?()
        #expect(scheduled.isEmpty)

        runner.processIDs = []
        runner.onApplicationChange?()
        runner.onApplicationChange?()
        supervisor.receiveApplicationTermination(bundleIdentifier: "ai.personastack.desktop", processID: 9002)
        #expect(scheduled.map(\.0) == [5])
        #expect(runner.launchedArguments.isEmpty)
        scheduled.removeFirst().1()
        #expect(runner.launchedArguments == [[DesktopCrashRecoverySupervisor.recoveryLaunchArgument]])
    }

    @Test(arguments: [false, true])
    func observedExitDoesNotRestartForDisabledRelayOrUpdateHandoff(updateHandoff: Bool) throws {
        let (preferences, suite) = try makePreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let runner = FakeCrashRecoveryProcessRunner()
        runner.processIDs = [9001]
        var scheduled: [(TimeInterval, @MainActor () -> Void)] = []
        let supervisor = DesktopCrashRecoverySupervisor(preferences: preferences, processRunner: runner,
            bundleURL: URL(fileURLWithPath: "/Applications/PersonaStack.app"),
            bundleIdentifier: "ai.personastack.desktop", loginSessionID: { "login-1" },
            shouldRestartForRelay: { updateHandoff }, schedule: { scheduled.append(($0, $1)) })
        supervisor.start()
        scheduled.removeAll()
        preferences.set(updateHandoff, forKey: DesktopUpdater.foregroundUpdateRelaunchKey)
        runner.processIDs = []
        runner.onApplicationChange?()
        #expect(scheduled.isEmpty)
        #expect(runner.launchedArguments.isEmpty)
    }

    @Test func liveOwnedChildIsNotTreatedAsExitedBeforeGUIRegistration() throws {
        let (preferences, suite) = try makePreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let runner = FakeCrashRecoveryProcessRunner()
        var scheduled: [(TimeInterval, @MainActor () -> Void)] = []
        let supervisor = DesktopCrashRecoverySupervisor(preferences: preferences, processRunner: runner,
            bundleURL: URL(fileURLWithPath: "/Applications/PersonaStack.app"),
            bundleIdentifier: "ai.personastack.desktop", loginSessionID: { "login-1" },
            shouldRestartForRelay: { true }, schedule: { scheduled.append(($0, $1)) })
        supervisor.start()
        scheduled.removeAll()
        runner.runningChildIDs = [9001]
        runner.processIDs = []
        runner.onApplicationChange?()
        #expect(scheduled.isEmpty)

        // Its actual child callback remains the exit authority even when the
        // application list never contained the child.
        runner.runningChildIDs = []
        supervisor.receiveApplicationTermination(bundleIdentifier: "ai.personastack.desktop", processID: 9001)
        runner.onApplicationChange?()
        #expect(scheduled.map(\.0) == [5])
        #expect(runner.launchedArguments.count == 1)
    }

    @Test func childExitObservedBeforeItsCallbackSchedulesOnlyOneRetry() throws {
        let (preferences, suite) = try makePreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let runner = FakeCrashRecoveryProcessRunner()
        var scheduled: [(TimeInterval, @MainActor () -> Void)] = []
        let supervisor = DesktopCrashRecoverySupervisor(preferences: preferences, processRunner: runner,
            bundleURL: URL(fileURLWithPath: "/Applications/PersonaStack.app"),
            bundleIdentifier: "ai.personastack.desktop", loginSessionID: { "login-1" },
            shouldRestartForRelay: { true }, schedule: { scheduled.append(($0, $1)) })
        supervisor.start()
        scheduled.removeAll()

        runner.processIDs = []
        runner.onApplicationChange?()
        supervisor.receiveApplicationTermination(bundleIdentifier: "ai.personastack.desktop", processID: 9001)
        runner.onApplicationChange?()

        #expect(scheduled.map(\.0) == [5])
        scheduled.removeFirst().1()
        #expect(runner.launchedArguments.count == 2)
    }

    @Test func aNewLoginClearsQuitAndStartsTheApplicationOnce() throws {
        let (preferences, suite) = try makePreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        DesktopCrashRecoveryPolicy.suppressUntilNextLogin(preferences: preferences)
        let processRunner = FakeCrashRecoveryProcessRunner()
        let supervisor = DesktopCrashRecoverySupervisor(preferences: preferences, processRunner: processRunner,
            bundleURL: URL(fileURLWithPath: "/Applications/PersonaStack.app"),
            bundleIdentifier: "ai.personastack.desktop", loginSessionID: { "login-2" },
            shouldRestartForRelay: { true }, schedule: { delay, _ in #expect(delay == 120) })

        supervisor.start()

        #expect(processRunner.launchedArguments == [[DesktopCrashRecoverySupervisor.recoveryLaunchArgument]])
    }

    @Test func aSupervisorRestartInTheSameLoginPreservesIntentionalQuit() throws {
        let (preferences, suite) = try makePreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        #expect(DesktopCrashRecoveryPolicy.beginLoginSession("login-1", preferences: preferences))
        DesktopCrashRecoveryPolicy.suppressUntilNextLogin(preferences: preferences)
        let processRunner = FakeCrashRecoveryProcessRunner()
        let supervisor = DesktopCrashRecoverySupervisor(preferences: preferences, processRunner: processRunner,
            bundleURL: URL(fileURLWithPath: "/Applications/PersonaStack.app"),
            bundleIdentifier: "ai.personastack.desktop", loginSessionID: { "login-1" },
            shouldRestartForRelay: { true })

        supervisor.start()

        #expect(processRunner.launchedArguments.isEmpty)
    }

    @Test func unexpectedTerminationRestartsOnlyForAnActiveRelay() throws {
        let (preferences, suite) = try makePreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let processRunner = FakeCrashRecoveryProcessRunner()
        var scheduled: (TimeInterval, @MainActor () -> Void)?
        let supervisor = DesktopCrashRecoverySupervisor(preferences: preferences, processRunner: processRunner,
            bundleURL: URL(fileURLWithPath: "/Applications/PersonaStack.app"),
            bundleIdentifier: "ai.personastack.desktop", loginSessionID: { "login-1" },
            shouldRestartForRelay: { true }, schedule: { scheduled = ($0, $1) })
        supervisor.start()
        processRunner.processIDs.removeAll()

        supervisor.receiveApplicationTermination(bundleIdentifier: "ai.personastack.desktop", processID: 9001)
        #expect(processRunner.launchedArguments.count == 1)
        #expect(scheduled != nil)
        #expect(scheduled?.0 == 5)
        scheduled?.1()

        #expect(processRunner.launchedArguments.count == 2)
    }

    @Test func staleOrForeignTerminationCannotLaunchASecondProcess() throws {
        let (preferences, suite) = try makePreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let processRunner = FakeCrashRecoveryProcessRunner()
        let supervisor = DesktopCrashRecoverySupervisor(preferences: preferences, processRunner: processRunner,
            bundleURL: URL(fileURLWithPath: "/Applications/PersonaStack.app"),
            bundleIdentifier: "ai.personastack.desktop", loginSessionID: { "login-1" },
            shouldRestartForRelay: { true }, schedule: { delay, _ in #expect(delay == 120) })
        supervisor.start()

        supervisor.receiveApplicationTermination(bundleIdentifier: "other.bundle", processID: 9001)
        supervisor.receiveApplicationTermination(bundleIdentifier: "ai.personastack.desktop", processID: 777)

        #expect(processRunner.launchedArguments.count == 1)
    }

    @Test func queuedRetryIsInvalidatedWhenAnotherAppLaunchArrives() throws {
        let (preferences, suite) = try makePreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let runner = FakeCrashRecoveryProcessRunner()
        var pending: (@MainActor () -> Void)?
        let supervisor = DesktopCrashRecoverySupervisor(preferences: preferences, processRunner: runner,
            bundleURL: URL(fileURLWithPath: "/Applications/PersonaStack.app"),
            bundleIdentifier: "ai.personastack.desktop", loginSessionID: { "login-1" },
            shouldRestartForRelay: { true }, schedule: { _, action in pending = action })
        supervisor.start()
        runner.processIDs.removeAll()
        supervisor.receiveApplicationTermination(bundleIdentifier: "ai.personastack.desktop", processID: 9001)
        supervisor.receiveApplicationLaunch(bundleIdentifier: "ai.personastack.desktop", processID: 9002)
        pending?()
        #expect(runner.launchedArguments.count == 1)
    }

    @Test func retryAdoptsAnAlreadyRunningAppAndResetsItsCrashBudgetAfterStability() throws {
        let (preferences, suite) = try makePreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let runner = FakeCrashRecoveryProcessRunner()
        runner.processIDs = [9001]
        var scheduled: [(TimeInterval, @MainActor () -> Void)] = []
        let supervisor = DesktopCrashRecoverySupervisor(preferences: preferences, processRunner: runner,
            bundleURL: URL(fileURLWithPath: "/Applications/PersonaStack.app"),
            bundleIdentifier: "ai.personastack.desktop", loginSessionID: { "login-1" },
            shouldRestartForRelay: { true }, schedule: { scheduled.append(($0, $1)) })
        supervisor.start()
        scheduled.removeAll()
        runner.processIDs = []
        supervisor.receiveApplicationTermination(bundleIdentifier: "ai.personastack.desktop", processID: 9001)
        let retry = try #require(scheduled.last)
        #expect(retry.0 == 5)
        scheduled.removeAll()

        // Launch notification has not arrived, but launchd can already see the app.
        runner.processIDs = [9002]
        retry.1()
        #expect(runner.launchedArguments.isEmpty)
        let stable = try #require(scheduled.last)
        #expect(stable.0 == 120)
        stable.1()
        scheduled.removeAll()

        runner.processIDs = []
        supervisor.receiveApplicationTermination(bundleIdentifier: "ai.personastack.desktop", processID: 9002)
        #expect(scheduled.last?.0 == 5)
    }

    @Test func sameLoginUpdateHandoffPreventsSupervisorStartupLaunch() throws {
        let (preferences, suite) = try makePreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set("login-1", forKey: DesktopCrashRecoveryPolicy.loginSessionKey)
        preferences.set(true, forKey: DesktopUpdater.foregroundUpdateRelaunchKey)
        let runner = FakeCrashRecoveryProcessRunner()
        let supervisor = DesktopCrashRecoverySupervisor(preferences: preferences, processRunner: runner,
            bundleURL: URL(fileURLWithPath: "/Applications/PersonaStack.app"),
            bundleIdentifier: "ai.personastack.desktop", loginSessionID: { "login-1" },
            shouldRestartForRelay: { true }, schedule: { _, _ in Issue.record("Unexpected restart schedule") })

        supervisor.start()

        #expect(runner.launchedArguments.isEmpty)
        #expect(preferences.bool(forKey: DesktopUpdater.foregroundUpdateRelaunchKey))
    }

    @Test func newLoginClearsAbandonedUpdateHandoffBeforeLaunch() throws {
        let (preferences, suite) = try makePreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set("login-old", forKey: DesktopCrashRecoveryPolicy.loginSessionKey)
        preferences.set(true, forKey: DesktopUpdater.foregroundUpdateRelaunchKey)
        let runner = FakeCrashRecoveryProcessRunner()
        let supervisor = DesktopCrashRecoverySupervisor(preferences: preferences, processRunner: runner,
            bundleURL: URL(fileURLWithPath: "/Applications/PersonaStack.app"),
            bundleIdentifier: "ai.personastack.desktop", loginSessionID: { "login-new" },
            shouldRestartForRelay: { true }, schedule: { _, _ in })

        supervisor.start()

        #expect(!preferences.bool(forKey: DesktopUpdater.foregroundUpdateRelaunchKey))
        #expect(runner.launchedArguments == [[DesktopCrashRecoverySupervisor.recoveryLaunchArgument]])
    }

    @Test func duplicateShortLivedLaunchDoesNotReplaceTrackedRunningOwner() throws {
        let (preferences, suite) = try makePreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set("login-1", forKey: DesktopCrashRecoveryPolicy.loginSessionKey)
        let runner = FakeCrashRecoveryProcessRunner()
        runner.processIDs = [9001]
        var scheduled: [(TimeInterval, @MainActor () -> Void)] = []
        let supervisor = DesktopCrashRecoverySupervisor(preferences: preferences, processRunner: runner,
            bundleURL: URL(fileURLWithPath: "/Applications/PersonaStack.app"),
            bundleIdentifier: "ai.personastack.desktop", loginSessionID: { "login-1" },
            shouldRestartForRelay: { true }, schedule: { scheduled.append(($0, $1)) })
        supervisor.start()

        runner.processIDs.append(9002)
        supervisor.receiveApplicationLaunch(bundleIdentifier: "ai.personastack.desktop", processID: 9002)
        runner.processIDs.removeAll { $0 == 9001 }
        supervisor.receiveApplicationTermination(bundleIdentifier: "ai.personastack.desktop", processID: 9001)

        #expect(scheduled.contains(where: { $0.0 == 5 }))
    }

    @Test func queuedRetryRechecksUpdateHandoffBeforeLaunching() throws {
        let (preferences, suite) = try makePreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set("login-1", forKey: DesktopCrashRecoveryPolicy.loginSessionKey)
        let runner = FakeCrashRecoveryProcessRunner()
        runner.processIDs = [9001]
        var scheduled: [(TimeInterval, @MainActor () -> Void)] = []
        let supervisor = DesktopCrashRecoverySupervisor(preferences: preferences, processRunner: runner,
            bundleURL: URL(fileURLWithPath: "/Applications/PersonaStack.app"),
            bundleIdentifier: "ai.personastack.desktop", loginSessionID: { "login-1" },
            shouldRestartForRelay: { true }, schedule: { scheduled.append(($0, $1)) })
        supervisor.start()
        runner.processIDs.removeAll()
        supervisor.receiveApplicationTermination(bundleIdentifier: "ai.personastack.desktop", processID: 9001)
        preferences.set(true, forKey: DesktopUpdater.foregroundUpdateRelaunchKey)
        _ = preferences.synchronize()

        scheduled.last?.1()

        #expect(runner.launchedArguments.isEmpty)
    }

    @Test func launchFailuresAndCrashBurstUseBoundedExponentialRetry() throws {
        let (preferences, suite) = try makePreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let runner = FakeCrashRecoveryProcessRunner()
        var scheduled: [(TimeInterval, @MainActor () -> Void)] = []
        let supervisor = DesktopCrashRecoverySupervisor(preferences: preferences, processRunner: runner,
            bundleURL: URL(fileURLWithPath: "/Applications/PersonaStack.app"),
            bundleIdentifier: "ai.personastack.desktop", loginSessionID: { "login-1" },
            shouldRestartForRelay: { true }, schedule: { scheduled.append(($0, $1)) })
        supervisor.start()
        runner.processIDs.removeAll()
        runner.failedLaunchesRemaining = 10
        supervisor.receiveApplicationTermination(bundleIdentifier: "ai.personastack.desktop", processID: 9001)

        while let next = scheduled.first {
            scheduled.removeFirst()
            next.1()
        }

        #expect(scheduled.isEmpty)
        #expect(runner.launchedArguments.count == 6)
    }

    @Test func directUserLaunchClearsSuppressionButNotRelayState() throws {
        let (preferences, suite) = try makePreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(false, forKey: "relay.enabled")
        DesktopCrashRecoveryPolicy.suppressUntilNextLogin(preferences: preferences)

        DesktopCrashRecoveryPolicy.resumeAfterExplicitLaunch(preferences: preferences)

        #expect(DesktopCrashRecoveryPolicy.shouldLaunchAtLogin(preferences: preferences))
        #expect(!DesktopCrashRecoveryPolicy.shouldRestartAfterUnexpectedExit(
            relayEnabled: preferences.bool(forKey: "relay.enabled"), relayPaused: false, preferences: preferences))
    }
}
