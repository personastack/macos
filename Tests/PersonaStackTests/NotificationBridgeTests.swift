import Foundation
import Testing
import PersonaStackCore

@Test func newConcernNotificationRequiresTheExactCreatedEvent() {
    #expect(NotificationBridge.isNewConcernEvent(["version": "1", "event": "created"]))
    #expect(!NotificationBridge.isNewConcernEvent(["version": "1", "event": "resolved"]))
    #expect(!NotificationBridge.isNewConcernEvent(["version": "2", "event": "created"]))
    #expect(!NotificationBridge.isNewConcernEvent(["version": 1, "event": "created"]))
    #expect(!NotificationBridge.isNewConcernEvent(["version": "1", "event": "created", "message": "sensitive content"] as [String: Any]))
    #expect(!NotificationBridge.isNewConcernEvent("created"))
}
