import AppKit
import ServiceManagement
import Testing
import PersonaStackCore
@testable import PersonaStack

@MainActor
private final class MiniaturizedMainWindowState {
    var isMiniaturized = true
}

@Test @MainActor func iMessageExternalHandoffIsFiniteAndWaitsForItsNativeOwner() throws {
    let delegate = PersonaStackTerminationDelegate(shutdown: { true }, terminate: { _ in }, timeout: .seconds(1), registrationService: isolatedLoginRegistrationService())
    let first = String(repeating: "A", count: 43)
    let latest = Data(repeating: 2, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
    let firstURL = try #require(URL(string: IMessageSetupHandoff.deepLinkPrefix + first))
    let latestURL = try #require(URL(string: IMessageSetupHandoff.deepLinkPrefix + latest))
    delegate.application(NSApplication.shared, open: [firstURL])
    delegate.application(NSApplication.shared, open: [latestURL])
    var received: [String] = []
    delegate.openIMessageSetup = { received.append($0.setupReference) }
    #expect(received == [latest])
    delegate.application(NSApplication.shared, open: [firstURL, latestURL])
    delegate.application(NSApplication.shared, open: [URL(string: "https://example.test")!])
    delegate.application(NSApplication.shared, open: [URL(string: IMessageSetupHandoff.deepLinkPrefix + first + "&extra=1")!])
    #expect(received == [latest])
    delegate.application(NSApplication.shared, open: [firstURL])
    #expect(received == [latest, first])
}

@Test @MainActor func iMessageQuitTimeoutNeverBypassesPendingCoordinatorProviderJoin() async {
    var join: CheckedContinuation<Bool, Never>?
    var pending = true
    var exits = 0
    var notices = 0
    var handoffs = 0
    let delegate = PersonaStackTerminationDelegate(shutdown: {
        let result = await withCheckedContinuation { join = $0 }
        pending = false
        return result
    }, terminate: { _ in exits += 1 }, timeout: .milliseconds(10), hasActiveSessions: { pending },
        showCleanupFailure: { notices += 1 }, registrationService: isolatedLoginRegistrationService())
    delegate.openIMessageSetup = { _ in handoffs += 1 }
    #expect(delegate.admitsNativeIMessageOperations)
    #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
    #expect(!delegate.admitsNativeIMessageOperations)
    delegate.application(NSApplication.shared, open: [URL(string: IMessageSetupHandoff.deepLinkPrefix + String(repeating: "A", count: 43))!])
    #expect(handoffs == 0)
    while notices == 0 { await Task.yield() }
    #expect(exits == 0 && pending)
    join?.resume(returning: true)
    while exits == 0 { await Task.yield() }
    #expect(exits == 1 && !pending)
    #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
}

@Test @MainActor func iMessagePermissionRestartHintIsNavigationOnlyBoundedAndEnvironmentScoped() throws {
    let suite = "IMessageRestartTests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    var clock = Date(timeIntervalSince1970: 1_700_000_000)
    let owner = DesktopApplicationRestart(defaults: preferences, now: { clock })
    var waiter: Process?
    var quits = 0
    let draft = Data("existing-private-draft-fixture".utf8)
    preferences.set(draft, forKey: "fixture.draft")
    try owner.request(applicationURL: URL(fileURLWithPath: "/Applications/PersonaStack.app"), processID: 123,
        iMessageConfiguration: .production, installUpdate: { false }, start: { waiter = $0 }, terminate: { quits += 1 })
    #expect(quits == 1)
    #expect(waiter?.arguments?.last == DesktopApplicationRestart.iMessageForegroundArgument)
    #expect(!owner.consumeResumeHint())
    #expect(!owner.consumeIMessageSetupResume(configuration: .lan))
    #expect(owner.consumeIMessageSetupResume(configuration: .production))
    #expect(!owner.consumeIMessageSetupResume(configuration: .production))
    #expect(preferences.data(forKey: "fixture.draft") == draft)
    let page = DesktopApplicationRestart.initialIMessagePageURL(DesktopEnvironmentConfiguration.production.appURL, resume: true)
    #expect(page.absoluteString == "https://my.personastack.ai/user/imessage?resume_setup=1")
    let otherQuery = URL(string: "https://my.personastack.ai/other?arbitrary=1#private")!
    #expect(DesktopApplicationRestart.initialIMessagePageURL(otherQuery, resume: true) == page)
    try owner.request(applicationURL: URL(fileURLWithPath: "/Applications/PersonaStack.app"), processID: 123,
        iMessageConfiguration: .production, installUpdate: { true }, start: { _ in Issue.record("Updater owns restart") }, terminate: {})
    clock.addTimeInterval(1801)
    #expect(!owner.consumeIMessageSetupResume(configuration: .production))
}

@Test @MainActor func appSwitcherActivationRestoresMiniaturizedMainWindow() {
    let state = MiniaturizedMainWindowState()
    var reopenCalls = 0
    let app = NSApplication.shared
    let delegate = PersonaStackTerminationDelegate(shutdown: { true }, terminate: { _ in }, timeout: .seconds(1),
        moveToMenuBar: { _ in }, hasMiniaturizedMainWindow: { state.isMiniaturized }, registrationService: isolatedLoginRegistrationService())
    delegate.installMainWindowReopener { reopenCalls += 1 }

    delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification, object: app))
    #expect(reopenCalls == 1)

    state.isMiniaturized = false
    delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification, object: app))
    #expect(reopenCalls == 1)
}

@Test @MainActor func commandQuitPreservesWorkAndReopenUntilExplicitQuit() async {
    let app = NSApplication.shared
    var windowsVisible = true
    var dockVisible = true
    var controlRunning = true
    var localRunActive = true
    var backgrounds = 0
    var cleanupCalls = 0
    var restartCancellations = 0
    var intents = 0
    var exits = 0
    let delegate = PersonaStackTerminationDelegate(shutdown: {
        cleanupCalls += 1
        controlRunning = false
        localRunActive = false
        return true
    }, terminate: { #expect($0 === app); exits += 1 }, timeout: .seconds(1),
       hasActiveSessions: { localRunActive },
       cancelPermissionRestart: { restartCancellations += 1 },
       recordQuitIntent: { intents += 1 },
       moveToMenuBar: {
           #expect($0 === app)
           backgrounds += 1
           windowsVisible = false
           dockVisible = false
       }, registrationService: isolatedLoginRegistrationService())
    delegate.installMainWindowReopener {
        windowsVisible = true
        dockVisible = true
    }
    for _ in 0..<2 { delegate.closeToMenuBar(app) }
    #expect(backgrounds == 2 && !windowsVisible && !dockVisible)
    #expect(controlRunning && localRunActive)
    #expect(cleanupCalls == 0 && exits == 0 && intents == 0 && restartCancellations == 0)
    #expect(!delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false))
    #expect(windowsVisible && dockVisible && controlRunning && localRunActive)
    delegate.closeToMenuBar(app)
    #expect(delegate.applicationShouldTerminate(app) == .terminateCancel)
    while exits == 0 { await Task.yield() }
    #expect(cleanupCalls == 1 && exits == 1 && intents == 1 && restartCancellations == 0)
    #expect(!controlRunning && !localRunActive)
    #expect(delegate.applicationShouldTerminate(app) == .terminateNow)
    delegate.closeToMenuBar(app)
    #expect(backgrounds == 3)
}

@Test @MainActor func commandQuitDoesNotHidePendingQuitCleanupAndRecoversAfterFailure() async throws {
    var backgrounds = 0
    var failures = 0
    var continuation: CheckedContinuation<Bool, Never>?
    let delegate = PersonaStackTerminationDelegate(
        shutdown: { await withCheckedContinuation { continuation = $0 } },
        terminate: { _ in Issue.record("Exited after failed cleanup") }, timeout: .seconds(1),
        hasActiveSessions: { true }, showCleanupFailure: { failures += 1 },
        moveToMenuBar: { _ in backgrounds += 1 }, registrationService: isolatedLoginRegistrationService())
    #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
    delegate.closeToMenuBar(NSApplication.shared)
    #expect(backgrounds == 0)
    while continuation == nil { await Task.yield() }
    let cleanup = try #require(continuation)
    cleanup.resume(returning: false)
    while failures == 0 { await Task.yield() }
    delegate.closeToMenuBar(NSApplication.shared)
    #expect(backgrounds == 1 && failures == 1)
}

@Test @MainActor func quitRunsCleanupOnceThenAdmitsFreshTermination() async {
    var cleanupCalls = 0
    var requests = 0
    var intents = 0
    var continuation: CheckedContinuation<Bool, Never>?
    let delegate = PersonaStackTerminationDelegate(
        shutdown: { cleanupCalls += 1; return await withCheckedContinuation { continuation = $0 } },
        terminate: { _ in requests += 1 }, timeout: .seconds(1), recordQuitIntent: { intents += 1 }, registrationService: isolatedLoginRegistrationService())
    let app = NSApplication.shared
    #expect(delegate.applicationShouldTerminate(app) == .terminateCancel)
    #expect(delegate.applicationShouldTerminate(app) == .terminateCancel)
    while continuation == nil { await Task.yield() }
    #expect(cleanupCalls == 1 && requests == 0 && intents == 0)
    continuation?.resume(returning: true)
    while requests == 0 { await Task.yield() }
    #expect(requests == 1 && intents == 1)
    #expect(delegate.applicationShouldTerminate(app) == .terminateNow)
    #expect(cleanupCalls == 1)
}

@Test @MainActor func quitFailureKeepsAppResponsiveAndRetriesCleanup() async {
    var cleanupCalls = 0
    var requests = 0
    var failures = 0
    var intents = 0
    let delegate = PersonaStackTerminationDelegate(shutdown: { cleanupCalls += 1; return cleanupCalls > 1 },
        terminate: { _ in requests += 1 }, timeout: .seconds(1), hasActiveSessions: { true },
        showCleanupFailure: { failures += 1 }, recordQuitIntent: { intents += 1 }, registrationService: isolatedLoginRegistrationService())
    #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
    while failures == 0 { await Task.yield() }
    #expect(requests == 0 && intents == 0)
    #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
    while requests == 0 { await Task.yield() }
    #expect(cleanupCalls == 2 && requests == 1 && intents == 1)
}

@Test @MainActor func quitDeadlineExitsOnlyWithoutActiveLocalSessionsAndIgnoresLateCleanup() async {
    for active in [false, true] {
        var requests = 0
        var failures = 0
        var continuation: CheckedContinuation<Bool, Never>?
        let delegate = PersonaStackTerminationDelegate(
            shutdown: { await withCheckedContinuation { continuation = $0 } },
            terminate: { _ in requests += 1 }, timeout: .milliseconds(10), hasActiveSessions: { active },
            showCleanupFailure: { failures += 1 }, registrationService: isolatedLoginRegistrationService())
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        while continuation == nil { await Task.yield() }
        while requests + failures == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(requests == (active ? 0 : 1) && failures == (active ? 1 : 0))
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == (active ? .terminateCancel : .terminateNow))
        continuation?.resume(returning: true)
        for _ in 0..<10 { await Task.yield() }
        #expect(requests == 1)
    }
}

@Test(arguments: [false, true]) @MainActor
func quitAfterFailedPermissionRestartDoesNotInheritItsWaiter(retryRestart: Bool) async throws {
    var running = false
    var starts = 0
    var stops = 0
    var failures = 0
    var exits = 0
    var relaunches = 0
    var cleaned = false
    let restart = DesktopApplicationRestart(isRunning: { _ in running }, stop: { _ in stops += 1; running = false })
    let delegate = PersonaStackTerminationDelegate(shutdown: { cleaned }, terminate: { _ in
        exits += 1
        if running { relaunches += 1; running = false }
    }, timeout: .seconds(1), showCleanupFailure: { failures += 1 },
       cancelPermissionRestart: { restart.cancelPendingRestart() }, registrationService: isolatedLoginRegistrationService())
    func requestRestart() throws {
        try restart.request(applicationURL: URL(fileURLWithPath: "/Applications/PersonaStack.app"),
            processID: 123, installUpdate: { false }, start: { _ in starts += 1; running = true },
            terminate: { #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel) })
    }
    try requestRestart()
    while failures == 0 { await Task.yield() }
    #expect(starts == 1 && stops == 1 && !running && exits == 0)
    cleaned = true
    if retryRestart { try requestRestart() }
    else { #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel) }
    while exits == 0 { await Task.yield() }
    #expect(exits == 1 && relaunches == (retryRestart ? 1 : 0))
    #expect(starts == (retryRestart ? 2 : 1) && stops == 1)
}

@Test @MainActor func permissionRestartHasOneWaiterAndYieldsOwnershipToSparkle() throws {
    var running = false
    var starts = 0
    var stops = 0
    var quits = 0
    let restart = DesktopApplicationRestart(isRunning: { _ in running }, stop: { _ in running = false; stops += 1 })
    for _ in 0..<2 {
        try restart.request(applicationURL: URL(fileURLWithPath: "/Applications/PersonaStack.app"), processID: 123,
            installUpdate: { false }, start: { _ in starts += 1; running = true }, terminate: { quits += 1 })
    }
    #expect(starts == 1 && quits == 2 && stops == 0)
    try restart.request(applicationURL: URL(fileURLWithPath: "/Applications/PersonaStack.app"), processID: 123,
        installUpdate: { true }, start: { _ in Issue.record("Competing updater waiter") },
        terminate: { Issue.record("Competing updater Quit") })
    #expect(stops == 1 && !running)
    restart.cancelPendingRestart()
    #expect(stops == 1)
}

@Test @MainActor func iMessageSavedManagementHandoffWaitsForNativeOwnerAndNeverBecomesSetupOrExecution() throws {
    let delegate = PersonaStackTerminationDelegate(shutdown: { true }, terminate: { _ in }, timeout: .seconds(1), registrationService: isolatedLoginRegistrationService())
    let url = URL(string: "personastack://manage-imessage?config_id=saved")!
    delegate.application(NSApplication.shared, open: [url])
    var ids: [String] = []
    var setups = 0
    delegate.openIMessageSetup = { _ in setups += 1 }
    delegate.openIMessageSaved = { ids.append($0.configID) }
    #expect(ids == ["saved"] && setups == 0)
    delegate.application(NSApplication.shared, open: [URL(string: "personastack://manage-imessage?config_id=saved&action=send")!])
    #expect(ids == ["saved"])
}

/// Each lifecycle regression owns its Service, defaults, OS-status fake and
/// held unregister. No test changes Service.current or calls SMAppService.
@MainActor final class HeldLoginRegistrationFixture {
    @MainActor final class State {
        var status = SMAppService.Status.enabled
        var calls: [String] = []
        var removal: CheckedContinuation<Void, Never>?
        var failRegistration = false
    }
    let state = State()
    let preferences: UserDefaults
    let suite: String
    let service: DesktopLoginItemRegistration.Service
    var startup: Task<SMAppService.Status, any Error>?
    init(outcome: String) throws {
        suite = "HeldLoginRegistration.\(UUID().uuidString)"
        guard let preferences = UserDefaults(suiteName: suite) else { throw CocoaError(.fileReadUnknown) }
        self.preferences = preferences
        state.failRegistration = outcome == "failure"
        preferences.set(outcome == "unchanged" ? "current" : "old", forKey: DesktopLoginItemRegistration.registeredExecutableKey)
        let captured = state
        service = .init(status: { captured.status }, unregister: {
            captured.calls.append("unregister")
            await withCheckedContinuation { captured.removal = $0 }
            captured.status = .notRegistered
        }, legacyStatus: { .notRegistered }, unregisterLegacy: { Issue.record("No legacy registration") }, register: {
            captured.calls.append("register")
            if captured.failRegistration { throw CocoaError(.executableNotLoadable) }
            captured.status = .enabled
        })
    }
    func start() {
        startup = follower()
    }
    func follower(onEnter: @escaping @MainActor () -> Void = {}) -> Task<SMAppService.Status, any Error> {
        Task {
            onEnter()
            return try await DesktopLoginItemRegistration.registerCurrentExecutable(preferences: preferences,
            bundleURL: URL(fileURLWithPath: "/Applications/PersonaStack.app"), volumeIsReadOnly: false,
                signatureValid: { _ in true }, identity: { _ in "current" }, service: service)
        }
    }
    func waitForStartup(held: Bool) async -> Bool {
        if !held { _ = try? await startup?.value; return true }
        return await loginLifecycleObserved { self.state.removal != nil }
    }
    func release() { state.removal?.resume(); state.removal = nil }
    func finish() async {
        release()
        _ = try? await startup?.value
        preferences.removePersistentDomain(forName: suite)
    }
}

@MainActor func loginLifecycleObserved(_ condition: @MainActor () -> Bool) async -> Bool {
    let end = ContinuousClock.now.advanced(by: .seconds(1))
    while !condition(), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(2)) }
    return condition()
}

@Test(arguments: ["success", "failure", "cancelled-follower", "unchanged"]) @MainActor
func iMessageQuitJoinsKnownLoginRegistrationBeforeTimeoutOrRepeatedTermination(outcome: String) async throws {
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
    var exits = 0, cleanups = 0, notices = 0
    let delegate = PersonaStackTerminationDelegate(shutdown: { cleanups += 1; return true },
        terminate: { _ in exits += 1 }, timeout: .milliseconds(20), hasActiveSessions: { false },
        showCleanupFailure: { notices += 1 }, registrationService: fixture.service)
    let app = NSApplication.shared
    #expect(delegate.applicationShouldTerminate(app) == .terminateCancel)
    #expect(delegate.applicationShouldTerminate(app) == .terminateCancel)
    if held {
        let timeoutObserved = await loginLifecycleObserved { notices > 0 || exits > 0 }
        #expect(timeoutObserved)
        #expect(exits == 0)
        // Existing shutdown must fence setup/runtime immediately, even while
        // the independent registration drain still prevents termination.
        #expect(cleanups == 1)
        #expect(fixture.service.hasPendingRegistration)
        #expect(!fixture.service.isAcceptingRegistrations)
        #expect(fixture.state.calls == ["unregister"])
    }
    fixture.release()
    _ = try? await fixture.startup?.value
    let finished = await loginLifecycleObserved { exits == 1 }
    #expect(finished && cleanups == 1)
    #expect(delegate.applicationShouldTerminate(app) == .terminateNow)
    #expect(!fixture.service.hasPendingRegistration)
    #expect(fixture.state.calls == (held ? ["unregister", "register"] : []))
    if let follower {
        var cancelled = false
        do { _ = try await follower.value } catch is CancellationError { cancelled = true } catch {}
        #expect(cancelled)
    }
    if outcome == "failure" { #expect(fixture.preferences.string(forKey: DesktopLoginItemRegistration.registeredExecutableKey) == nil) }
    await fixture.finish()
}

@MainActor func isolatedLoginRegistrationService() -> DesktopLoginItemRegistration.Service {
    .init(status: { .notRegistered }, unregister: { Issue.record("No registration operation expected") },
        legacyStatus: { .notRegistered }, unregisterLegacy: { Issue.record("No legacy registration expected") },
        register: { Issue.record("No registration operation expected") })
}

@Test @MainActor func iMessageFailedOrderlyQuitReleasesOnlyItsSettledTerminalRegistrationClosure() async throws {
    let fixture = try HeldLoginRegistrationFixture(outcome: "success")
    fixture.start()
    let entered = await fixture.waitForStartup(held: true)
    #expect(entered)
    guard entered else { await fixture.finish(); return }
    defer { fixture.release() }
    var cleanupCalls = 0, exits = 0, notices = 0
    let delegate = PersonaStackTerminationDelegate(shutdown: { cleanupCalls += 1; return cleanupCalls > 1 },
        terminate: { _ in exits += 1 }, timeout: .seconds(1), showCleanupFailure: { notices += 1 },
        registrationService: fixture.service)
    #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
    fixture.release()
    _ = try? await fixture.startup?.value
    let failed = await loginLifecycleObserved { notices == 1 }
    #expect(failed && exits == 0)
    #expect(fixture.service.isAcceptingRegistrations && delegate.admitsNativeIMessageOperations)
    let retry = fixture.follower()
    _ = try await retry.value
    #expect(fixture.state.calls == ["unregister", "register"])
    #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
    let finished = await loginLifecycleObserved { exits == 1 }
    #expect(finished && cleanupCalls == 2)
    fixture.service.resumeAdmission()
    #expect(!fixture.service.isAcceptingRegistrations)
    await fixture.finish()
}
