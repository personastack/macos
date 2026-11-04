import AppKit
import Testing
@testable import PersonaStack

@Test(arguments: [false, true]) @MainActor
func iMessageProbeTerminationJoinsCleanupBeforeOneFreshQuit(closingLastWindow: Bool) async throws {
    let app = NSApplication.shared
    var cleanupCalls = 0
    var freshTerminations = 0
    var providerJoined = false
    var continuation: CheckedContinuation<Void, Never>?
    let delegate = IMessageProbeTerminationDelegate(shutdown: {
        cleanupCalls += 1
        await withCheckedContinuation { continuation = $0 }
        providerJoined = true
    }, terminate: {
        #expect($0 === app)
        #expect(providerJoined)
        freshTerminations += 1
    })
    if closingLastWindow { #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(app)) }
    #expect(delegate.applicationShouldTerminate(app) == .terminateCancel)
    #expect(delegate.applicationShouldTerminate(app) == .terminateCancel)
    while continuation == nil { await Task.yield() }
    #expect(cleanupCalls == 1 && freshTerminations == 0 && !providerJoined)
    for _ in 0..<3 { #expect(delegate.applicationShouldTerminate(app) == .terminateCancel) }
    #expect(cleanupCalls == 1 && freshTerminations == 0)
    let cleanup = try #require(continuation)
    cleanup.resume()
    while freshTerminations == 0 { await Task.yield() }
    #expect(providerJoined && cleanupCalls == 1 && freshTerminations == 1)
    #expect(delegate.applicationShouldTerminate(app) == .terminateNow)
    #expect(delegate.applicationShouldTerminate(app) == .terminateNow)
    #expect(cleanupCalls == 1 && freshTerminations == 1)
}

@Test @MainActor
func iMessageProbeTerminationRetainsInstalledCleanupWhenTheWindowCloses() async throws {
    let app = NSApplication.shared
    var cleanupCalls = 0
    var freshTerminations = 0
    var continuation: CheckedContinuation<Void, Never>?
    let delegate = IMessageProbeTerminationDelegate(shutdown: {
        Issue.record("The probe's installed cleanup was skipped")
    }, terminate: { _ in freshTerminations += 1 })
    delegate.installShutdown {
        cleanupCalls += 1
        await withCheckedContinuation { continuation = $0 }
    }
    #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(app))
    #expect(delegate.applicationShouldTerminate(app) == .terminateCancel)
    while continuation == nil { await Task.yield() }
    delegate.installShutdown { Issue.record("A repeated window callback replaced in-progress cleanup") }
    #expect(delegate.applicationShouldTerminate(app) == .terminateCancel)
    #expect(cleanupCalls == 1 && freshTerminations == 0)
    let cleanup = try #require(continuation)
    cleanup.resume()
    while freshTerminations == 0 { await Task.yield() }
    #expect(cleanupCalls == 1 && freshTerminations == 1)
    #expect(delegate.applicationShouldTerminate(app) == .terminateNow)
}
