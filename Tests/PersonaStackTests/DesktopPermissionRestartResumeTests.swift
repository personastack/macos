import Foundation
import Testing
@testable import PersonaStack

@Test @MainActor func permissionRestartResumeHintIsExpiringConsumedNavigationOnly() throws {
    let suite = "PersonaStackTests.permission-resume.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var clock = Date(timeIntervalSince1970: 10_000)
    let owner = DesktopApplicationRestart(defaults: defaults, now: { clock })
    let app = URL(fileURLWithPath: "/Applications/PersonaStack.app")
    try owner.request(applicationURL: app, installUpdate: { true }, start: { _ in Issue.record("Sparkle owns relaunch") })
    #expect(owner.consumeResumeHint())
    #expect(!owner.consumeResumeHint())
    try owner.request(applicationURL: app, installUpdate: { true })
    clock = clock.addingTimeInterval(30 * 60)
    #expect(!owner.consumeResumeHint())
    #expect(owner.consumeResumeHint(arguments: [DesktopApplicationRestart.foregroundArgument]))
    let original = try #require(URL(string: "https://example.test:8443/user/personas?old=1#old"))
    #expect(DesktopApplicationRestart.initialPageURL(original, resume: true).absoluteString == "https://example.test:8443/user/desktop-control?resume_setup=1")
    #expect(DesktopApplicationRestart.initialPageURL(original, resume: false) == original)
}

@Test @MainActor func permissionRestartCanceledAndFailedRequestsClearResumeHint() throws {
    let suite = "PersonaStackTests.permission-resume.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let owner = DesktopApplicationRestart(defaults: defaults)
    let app = URL(fileURLWithPath: "/Applications/PersonaStack.app")
    try owner.request(applicationURL: app, installUpdate: { true })
    owner.cancelPendingRestart()
    #expect(!owner.consumeResumeHint())
    #expect(throws: CocoaError.self) {
        try owner.request(applicationURL: app, installUpdate: { throw CocoaError(.executableNotLoadable) })
    }
    #expect(!owner.consumeResumeHint())
    #expect(throws: CocoaError.self) {
        try owner.request(applicationURL: app, installUpdate: { false }, start: { _ in throw CocoaError(.executableNotLoadable) })
    }
    #expect(!owner.consumeResumeHint())
    var terminated = false
    try owner.request(applicationURL: app, installUpdate: { false }, start: { _ in }, terminate: { terminated = true })
    #expect(terminated && owner.consumeResumeHint())
}
