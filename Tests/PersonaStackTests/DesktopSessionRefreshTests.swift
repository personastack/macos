import AppKit
import Foundation
import Testing
@testable import PersonaStack

@Test @MainActor func desktopSessionRefreshRetainsCookiesAndRetriesAfterNetworkFailure() async throws {
    let appURL = try #require(URL(string: "https://my.personastack.ai/user/personas"))
    var calls = 0
    let refresh = DesktopSessionRefresh(appURL: appURL, currentURL: { appURL }, evaluate: { script in
        calls += 1
        #expect(script.contains("location.origin !== \"https://my.personastack.ai\""))
        #expect(script.contains("'/user/mobile/bootstrap'"))
        #expect(script.contains("credentials: 'same-origin'") && script.contains("redirect: 'error'"))
        #expect(!script.contains("document.cookie") && !script.contains("localStorage") && !script.contains("logout"))
        throw URLError(.notConnectedToInternet)
    })
    defer { refresh.stop() }
    refresh.refresh()
    while calls == 0 { await Task.yield() }
    await Task.yield()
    refresh.refresh()
    while calls < 2 { await Task.yield() }
    #expect(calls == 2)
}

@Test @MainActor func desktopSessionRefreshFencesOverlappingRequestsAndRetiredHost() async throws {
    let appURL = try #require(URL(string: "https://my.personastack.ai/user/personas"))
    var calls = 0
    var pending: CheckedContinuation<Void, Never>?
    let refresh = DesktopSessionRefresh(appURL: appURL, currentURL: { appURL }, evaluate: { _ in
        calls += 1
        await withCheckedContinuation { pending = $0 }
    })
    refresh.refresh()
    while pending == nil { await Task.yield() }
    refresh.refresh()
    await Task.yield()
    #expect(calls == 1)
    refresh.stop()
    refresh.refresh()
    pending?.resume()
    await Task.yield()
    #expect(calls == 1)
}

@Test(arguments: ["https://accounts.google.com/user/profile", "https://my.personastack.ai.evil.test/user/personas", "http://my.personastack.ai/user/personas", "https://my.personastack.ai/login", "https://my.personastack.ai/logout", "https://my.personastack.ai/user-other"])
@MainActor func desktopSessionRefreshRejectsForeignAndSignedOutDocuments(destination: String) async throws {
    let appURL = try #require(URL(string: "https://my.personastack.ai/user/personas"))
    var calls = 0
    let refresh = DesktopSessionRefresh(appURL: appURL, currentURL: { URL(string: destination) }, evaluate: { _ in calls += 1 })
    defer { refresh.stop() }
    refresh.refresh()
    await Task.yield()
    #expect(calls == 0)
}

@Test @MainActor func desktopSessionRefreshRunsOnWakeAndActivationAndStopsObservers() async throws {
    let appURL = try #require(URL(string: "http://my.personastack.lan/user/personas"))
    let application = NotificationCenter()
    let workspace = NotificationCenter()
    var calls = 0
    let refresh = DesktopSessionRefresh(appURL: appURL, currentURL: { appURL },
        applicationNotifications: application, workspaceNotifications: workspace, evaluate: { _ in calls += 1 })
    refresh.start()
    workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
    while calls < 1 { await Task.yield() }
    await Task.yield()
    application.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    while calls < 2 { await Task.yield() }
    refresh.stop()
    workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
    application.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    await Task.yield()
    #expect(calls == 2)
}
