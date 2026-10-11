import Foundation
import Testing
import PersonaStackCore

@Test func concernPresentationAcceptsOnlyBoundedFieldsAndKeepsNavigationPrivate() throws {
    let body = ["version": "3", "event": "created", "concern_id": "c1", "workspace_id": "ws_b",
                "persona_id": "p1", "persona_name": "Planner", "preview": "The build needs attention…", "avatar_png": ""]
    let presentation = try #require(NotificationBridge.presentation(body))
    #expect(presentation.title == "Planner raised a concern")
    #expect(presentation.preview == "The build needs attention…")
    #expect(NotificationBridge.isNewConcernEvent(body))
    let appURL = try #require(URL(string: "https://my.personastack.ai"))
    #expect(NotificationBridge.notificationInfo(body, appURL: appURL) == ["app_origin": "https://my.personastack.ai", "concern_id": "c1", "workspace_id": "ws_b"])
    for (key, value) in [("persona_name", ""), ("persona_name", "a\nname"), ("persona_name", String(repeating: "a", count: 257)),
                         ("preview", String(repeating: "🙂", count: 181)), ("avatar_png", "invalid!"),
                         ("avatar_png", String(repeating: "a", count: 131_073)), ("persona_id", "bad/id"), ("user_id", "private")] {
        var invalid = body
        invalid[key] = value
        #expect(!NotificationBridge.isNewConcernEvent(invalid))
    }
}

@Test func newConcernNotificationRequiresTheExactCreatedEvent() {
    #expect(NotificationBridge.isNewConcernEvent(["version": "1", "event": "created"]))
    #expect(!NotificationBridge.isNewConcernEvent(["version": "1", "event": "resolved"]))
    #expect(!NotificationBridge.isNewConcernEvent(["version": "2", "event": "created"]))
    #expect(!NotificationBridge.isNewConcernEvent(["version": 1, "event": "created"]))
    #expect(!NotificationBridge.isNewConcernEvent(["version": "1", "event": "created", "message": "sensitive content"] as [String: Any]))
    #expect(!NotificationBridge.isNewConcernEvent("created"))
}

@Test func concernNavigationKeepsOnlyIdentifiersAndBuildsTheHostedDestination() throws {
    let appURL = try #require(URL(string: "https://my.personastack.ai/user/personas?old=1#old"))
    let payload = ["version": "2", "event": "created", "concern_id": "concern &?/é", "workspace_id": "ws_b"]
    let info = try #require(NotificationBridge.notificationInfo(payload, appURL: appURL))
    #expect(info == ["app_origin": "https://my.personastack.ai", "concern_id": "concern &?/é", "workspace_id": "ws_b"])
    let destination = try #require(NotificationBridge.concernDestination(info, appURL: appURL))
    let parts = try #require(URLComponents(url: destination, resolvingAgainstBaseURL: false))
    #expect(parts.path == "/user/concerns")
    #expect(parts.fragment == nil)
    #expect(parts.queryItems == [URLQueryItem(name: "workspace_id", value: "ws_b"), URLQueryItem(name: "concern_id", value: "concern &?/é")])
    let legacy = try #require(NotificationBridge.notificationInfo(["version": "1", "event": "created"], appURL: appURL))
    #expect(NotificationBridge.concernDestination(legacy, appURL: appURL)?.absoluteString == "https://my.personastack.ai/user/concerns")
}

@Test func concernNavigationRejectsExtraDataInvalidIDsAndChangedServers() throws {
    let appURL = try #require(URL(string: "https://my.personastack.ai"))
    let payload = ["version": "2", "event": "created", "concern_id": "concern-1", "workspace_id": "ws_a"]
    for extra in ["message", "user_id", "url", "credential"] {
        var invalid = payload
        invalid[extra] = "private"
        #expect(!NotificationBridge.isNewConcernEvent(invalid))
    }
    for id in ["", " a", "a\n", String(repeating: "é", count: 257)] {
        var invalid = payload
        invalid["concern_id"] = id
        #expect(!NotificationBridge.isNewConcernEvent(invalid))
    }
    for workspace in ["", "ws/a", String(repeating: "a", count: 129)] {
        var invalid = payload
        invalid["workspace_id"] = workspace
        #expect(!NotificationBridge.isNewConcernEvent(invalid))
    }
    let info = try #require(NotificationBridge.notificationInfo(payload, appURL: appURL))
    for url in ["http://my.personastack.ai", "https://my.personastack.ai:444", "https://my.personastack.lan"] {
        #expect(NotificationBridge.concernDestination(info, appURL: try #require(URL(string: url))) == nil)
    }
    var invalid = info
    invalid["url"] = "https://attacker.invalid"
    #expect(NotificationBridge.concernDestination(invalid, appURL: appURL) == nil)
    invalid = info
    invalid["workspace_id"] = "ws/a"
    #expect(NotificationBridge.concernDestination(invalid, appURL: appURL) == nil)
}
