import AppKit
import Testing
@testable import PersonaStack

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
       })
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
        moveToMenuBar: { _ in backgrounds += 1 })
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
        terminate: { _ in requests += 1 }, timeout: .seconds(1), recordQuitIntent: { intents += 1 })
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
        showCleanupFailure: { failures += 1 }, recordQuitIntent: { intents += 1 })
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
            showCleanupFailure: { failures += 1 })
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
       cancelPermissionRestart: { restart.cancelPendingRestart() })
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
