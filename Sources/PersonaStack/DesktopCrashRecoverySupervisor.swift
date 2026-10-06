import AppKit
import Darwin
import Foundation
import PersonaStackCore
import Security
import OSLog

@MainActor
protocol DesktopCrashRecoveryProcessRunning: AnyObject {
    func applicationProcessIDs(bundleIdentifier: String) -> [pid_t]
    func ownsRunningProcess(processID: pid_t) -> Bool
    func observeApplicationChanges(_ onChange: @escaping @MainActor () -> Void)
    func launchApplication(at bundleURL: URL, arguments: [String],
                           onTermination: @escaping @MainActor (pid_t) -> Void) -> pid_t?
}

@MainActor
private final class SystemDesktopCrashRecoveryProcessRunner: DesktopCrashRecoveryProcessRunning {
    private var children: [pid_t: Process] = [:]
    private var applicationObservation: NSKeyValueObservation?

    func applicationProcessIDs(bundleIdentifier: String) -> [pid_t] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .map(\.processIdentifier)
    }

    func ownsRunningProcess(processID: pid_t) -> Bool {
        children[processID]?.isRunning == true
    }

    func observeApplicationChanges(_ onChange: @escaping @MainActor () -> Void) {
        // Workspace launch/termination notifications can omit accessory apps.
        // The observable application list includes their direct user relaunches.
        applicationObservation = NSWorkspace.shared.observe(\.runningApplications) { _, _ in
            Task { @MainActor in onChange() }
        }
    }

    func launchApplication(at bundleURL: URL, arguments: [String],
                           onTermination: @escaping @MainActor (pid_t) -> Void) -> pid_t? {
        guard let executable = Bundle(url: bundleURL)?.executableURL else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.terminationHandler = { [weak self, weak process] _ in
            guard let process else { return }
            let pid = process.processIdentifier
            Task { @MainActor in
                self?.children[pid] = nil
                onTermination(pid)
            }
        }
        do {
            try process.run()
            children[process.processIdentifier] = process
            return process.processIdentifier
        } catch {
            return nil
        }
    }
}

/// A process monitor only. The ordinary PersonaStack process owns every relay,
/// credential, Cua child, lease, and command.
@MainActor
final class DesktopCrashRecoverySupervisor {
    static let supervisorArgument = "--personastack-crash-supervisor"
    static let recoveryLaunchArgument = "--personastack-crash-relaunch"
    private static var runningSupervisor: DesktopCrashRecoverySupervisor?

    private let preferences: UserDefaults
    private let processRunner: any DesktopCrashRecoveryProcessRunning
    private let bundleURL: URL
    private let bundleIdentifier: String
    private let loginSessionID: @MainActor () -> String?
    private let shouldRestartForRelay: @MainActor () -> Bool
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private var applicationPID: pid_t?
    private var generation: UInt64 = 0
    private var crashAttempts = 0
    private let maximumCrashAttempts = 5
    private let stableRuntime: TimeInterval = 120

    init(preferences: UserDefaults = .standard,
         processRunner: any DesktopCrashRecoveryProcessRunning = SystemDesktopCrashRecoveryProcessRunner(),
         bundleURL: URL = Bundle.main.bundleURL,
         bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "ai.personastack.desktop",
         loginSessionID: @escaping @MainActor () -> String? = { DesktopCrashRecoverySupervisor.currentLoginSessionID() },
         shouldRestartForRelay: @escaping @MainActor () -> Bool = { DesktopCrashRecoverySupervisor.currentRelayAllowsRecovery() },
         schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, action in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                 MainActor.assumeIsolated { action() }
             }
         }) {
        self.preferences = preferences
        self.processRunner = processRunner
        self.bundleURL = bundleURL
        self.bundleIdentifier = bundleIdentifier
        self.loginSessionID = loginSessionID
        self.shouldRestartForRelay = shouldRestartForRelay
        self.schedule = schedule
    }

    static func isSupervisorInvocation(arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.contains(supervisorArgument)
    }

    static func dispatchSupervisorIfRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        guard isSupervisorInvocation(arguments: arguments) else { return false }
        let supervisor = DesktopCrashRecoverySupervisor()
        runningSupervisor = supervisor
        supervisor.run()
    }

    func start() {
        generation &+= 1
        if let sessionID = loginSessionID() {
            if DesktopCrashRecoveryPolicy.beginLoginSession(sessionID, preferences: preferences) {
                preferences.removeObject(forKey: DesktopUpdater.foregroundUpdateRelaunchKey)
                _ = preferences.synchronize()
            }
        }
        processRunner.observeApplicationChanges { [weak self] in
            self?.reconcileApplicationProcesses()
        }

        if let runningPID = activeApplicationPID() {
            applicationPID = runningPID
            scheduleStableReset(for: runningPID, generation: generation)
        } else if !updateHandoffPending, DesktopCrashRecoveryPolicy.shouldLaunchAtLogin(preferences: preferences) {
            launchApplication()
        }
    }

    func run() -> Never {
        // NSApplication registers this same-bundle helper with LaunchServices,
        // even with prohibited activation. After the GUI exits, open then targets
        // the helper and fails with -600. Keep the supervisor on a headless loop.
        start()
        RunLoop.main.run()
        exit(0)
    }



    func receiveApplicationTermination(bundleIdentifier: String?, processID: pid_t) {
        guard bundleIdentifier == self.bundleIdentifier, processID == applicationPID else { return }
        generation &+= 1
        applicationPID = nil
        guard !updateHandoffPending, DesktopCrashRecoveryPolicy.shouldRestartAfterUnexpectedExit(
            relayEnabled: shouldRestartForRelay(), relayPaused: false, preferences: preferences) else { return }
        scheduleRetry(for: generation)
    }

    func receiveApplicationLaunch(bundleIdentifier: String?, processID: pid_t) {
        guard bundleIdentifier == self.bundleIdentifier, processID != getpid() else { return }
        if let trackedPID = applicationPID, trackedPID != processID,
           processRunner.applicationProcessIDs(bundleIdentifier: self.bundleIdentifier).contains(trackedPID) {
            return
        }
        if applicationPID != processID { generation &+= 1 }
        applicationPID = processID
        scheduleStableReset(for: processID, generation: generation)
    }

    private func scheduleRetry(for expectedGeneration: UInt64) {
        guard crashAttempts < maximumCrashAttempts else { return }
        let delay = min(5.0 * pow(2.0, Double(crashAttempts)), 60.0)
        crashAttempts += 1
        schedule(delay) { [weak self] in
            guard let self else { return }
            guard self.generation == expectedGeneration,
                  self.applicationPID == nil,
                  !self.updateHandoffPending,
                  DesktopCrashRecoveryPolicy.shouldRestartAfterUnexpectedExit(
                    relayEnabled: self.shouldRestartForRelay(), relayPaused: false, preferences: self.preferences) else { return }
            if let runningPID = self.activeApplicationPID() {
                self.receiveApplicationLaunch(bundleIdentifier: self.bundleIdentifier, processID: runningPID)
                return
            }
            self.launchApplication()
        }
    }

    private func scheduleStableReset(for pid: pid_t, generation expectedGeneration: UInt64) {
        schedule(stableRuntime) { [weak self] in
            guard let self, self.applicationPID == pid, self.generation == expectedGeneration else { return }
            self.crashAttempts = 0
        }
    }

    private func reconcileApplicationProcesses() {
        let pids = processRunner.applicationProcessIDs(bundleIdentifier: bundleIdentifier)
            .filter { $0 != getpid() }
        if let applicationPID, pids.contains(applicationPID) { return }
        // A child may still be starting before it appears in LaunchServices, or
        // be finishing after unregistering. Its Process callback owns that exit.
        if let applicationPID, processRunner.ownsRunningProcess(processID: applicationPID) { return }
        if let pid = pids.first {
            receiveApplicationLaunch(bundleIdentifier: bundleIdentifier, processID: pid)
        } else if let applicationPID {
            receiveApplicationTermination(bundleIdentifier: bundleIdentifier, processID: applicationPID)
        }
    }

    private func activeApplicationPID() -> pid_t? {
        processRunner.applicationProcessIDs(bundleIdentifier: bundleIdentifier)
            .first { $0 != getpid() }
    }

    private var updateHandoffPending: Bool {
        _ = preferences.synchronize()
        return preferences.bool(forKey: DesktopUpdater.foregroundUpdateRelaunchKey)
    }

    private func launchApplication() {
        guard applicationPID == nil else { return }
        guard let pid = processRunner.launchApplication(at: bundleURL, arguments: [Self.recoveryLaunchArgument],
            onTermination: { [weak self] pid in
                self?.receiveApplicationTermination(bundleIdentifier: self?.bundleIdentifier, processID: pid)
            }) else {
            scheduleRetry(for: generation)
            return
        }
        applicationPID = pid
        generation &+= 1
        scheduleStableReset(for: pid, generation: generation)
    }

    private static func currentLoginSessionID() -> String? {
        var identifier: SecuritySessionId = 0
        guard SessionGetInfo(callerSecuritySession, &identifier, nil) == errSecSuccess else { return nil }
        return String(identifier)
    }

    private static func currentRelayAllowsRecovery() -> Bool {
        let preferences = UserDefaults.standard
        _ = preferences.synchronize()
        guard let configuration = try? LaunchConfiguration.selectedEnvironment() else { return false }
        return preferences.bool(forKey: DesktopControlPreferenceKeys.relayEnabled(configuration))
            && !preferences.bool(forKey: DesktopControlPreferenceKeys.relayPaused(configuration))
    }
}
