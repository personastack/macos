import AppKit
import Foundation
import Testing
import UserNotifications
import WebKit
@testable import PersonaStack

struct NativeConcernNotificationTests {
    @MainActor
    @Test
    func createdConcernSchedulesAContentFreeLocalNotification() throws {
        var scheduledRequests: [UNNotificationRequest] = []
        let coordinator = PersonaStackWebView.Coordinator(
            appURL: try #require(URL(string: "https://my.personastack.ai/user/personas")),
            configureNotificationCenter: { _ in },
            scheduleNotification: { scheduledRequests.append($0) }
        )

        coordinator.handleConcernMessage(
            name: "personastackConcern",
            isMainFrame: true,
            host: "my.personastack.ai",
            body: ["version": "1", "event": "created"],
            appURL: URL(string: "https://my.personastack.ai")
        )

        let request = try #require(scheduledRequests.first)
        #expect(scheduledRequests.count == 1)
        #expect(!request.identifier.isEmpty)
        #expect(request.content.title == "PersonaStack")
        #expect(request.content.body == "A new concern needs attention.")
        #expect(request.content.sound != nil)
        #expect(request.trigger == nil)
    }

    @MainActor
    @Test
    func invalidBridgeEventsDoNotScheduleLocalNotifications() throws {
        var scheduledRequests: [UNNotificationRequest] = []
        let coordinator = PersonaStackWebView.Coordinator(
            appURL: try #require(URL(string: "https://my.personastack.ai/user/personas")),
            configureNotificationCenter: { _ in },
            scheduleNotification: { scheduledRequests.append($0) }
        )
        let acceptedPayload: [String: Any] = ["version": "1", "event": "created"]
        let validOrigin = URL(string: "https://my.personastack.ai")!
        let invalidMessages: [(name: String, isMainFrame: Bool, host: String?, body: Any, appURL: URL?)] = [
            ("otherHandler", true, "my.personastack.ai", acceptedPayload, validOrigin),
            ("personastackConcern", false, "my.personastack.ai", acceptedPayload, validOrigin),
            ("personastackConcern", true, "attacker.invalid", acceptedPayload, URL(string: "https://attacker.invalid")),
            ("personastackConcern", true, "my.personastack.ai", acceptedPayload, URL(string: "http://my.personastack.ai")),
            ("personastackConcern", true, "my.personastack.ai", acceptedPayload, URL(string: "https://my.personastack.ai:444")),
            ("personastackConcern", true, "my.personastack.ai", ["version": "1", "event": "resolved"], validOrigin),
        ]

        for message in invalidMessages {
            coordinator.handleConcernMessage(
                name: message.name,
                isMainFrame: message.isMainFrame,
                host: message.host,
                body: message.body,
                appURL: message.appURL
            )
        }

        #expect(scheduledRequests.isEmpty)
    }

    @MainActor
    @Test
    func mainConcernReceiverSurvivesWindowCloseAndReopen() throws {
        var scheduledRequests: [UNNotificationRequest] = []
        let appURL = try #require(URL(string: "https://my.personastack.ai/user/personas"))
        let coordinator = PersonaStackWebView.Coordinator(
            appURL: appURL,
            configureNotificationCenter: { _ in },
            scheduleNotification: { scheduledRequests.append($0) }
        )
        let host = MainWebViewHost(appURL: appURL, loadPage: false,
                                   requestNotifications: false, coordinator: coordinator)
        let firstWindowContent = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        host.attach(to: firstWindowContent)
        let originalWebView = host.webView
        #expect(originalWebView.superview === firstWindowContent)

        host.park(from: firstWindowContent)
        #expect(originalWebView.superview !== firstWindowContent)
        #expect(originalWebView.window != nil)
        #expect(host.coordinator === coordinator)
        coordinator.handleConcernMessage(name: "personastackConcern", isMainFrame: true,
                                         host: "my.personastack.ai",
                                         body: ["version": "1", "event": "created"],
                                         appURL: URL(string: "https://my.personastack.ai"))
        #expect(scheduledRequests.count == 1)

        let reopenedWindowContent = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        host.attach(to: reopenedWindowContent)
        #expect(host.webView === originalWebView)
        #expect(originalWebView.superview === reopenedWindowContent)
        coordinator.handleConcernMessage(name: "personastackConcern", isMainFrame: true,
                                         host: "my.personastack.ai",
                                         body: ["version": "1", "event": "created"],
                                         appURL: URL(string: "https://my.personastack.ai"))
        #expect(scheduledRequests.count == 2)
    }

    @MainActor
    @Test
    func retiredCoordinatorCannotScheduleNotifications() throws {
        var scheduledRequests: [UNNotificationRequest] = []
        let coordinator = PersonaStackWebView.Coordinator(
            appURL: try #require(URL(string: "https://my.personastack.ai/user/personas")),
            configureNotificationCenter: { _ in },
            scheduleNotification: { scheduledRequests.append($0) }
        )
        coordinator.retire()

        coordinator.handleConcernMessage(
            name: "personastackConcern",
            isMainFrame: true,
            host: "my.personastack.ai",
            body: ["version": "1", "event": "created"],
            appURL: URL(string: "https://my.personastack.ai")
        )

        #expect(scheduledRequests.isEmpty)
    }
}
