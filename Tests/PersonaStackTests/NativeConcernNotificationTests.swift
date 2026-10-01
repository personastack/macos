import AppKit
import Foundation
import Testing
import UserNotifications
import WebKit
import PersonaStackCore
@testable import PersonaStack

struct NativeConcernNotificationTests {
    @MainActor
    @Test
    func createdConcernSchedulesAContentFreeLocalNotification() throws {
        var scheduledRequests: [UNNotificationRequest] = []
        let coordinator = PersonaStackWebView.Coordinator(
            appURL: try #require(URL(string: "https://my.personastack.ai/user/personas")),
            notificationCoordinator: nil,
            configureNotificationCenter: { _ in },
            scheduleNotification: { scheduledRequests.append($0) },
            concernNotificationsEnabled: { true }
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
            notificationCoordinator: nil,
            configureNotificationCenter: { _ in },
            scheduleNotification: { scheduledRequests.append($0) },
            concernNotificationsEnabled: { true }
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
            notificationCoordinator: nil,
            configureNotificationCenter: { _ in },
            scheduleNotification: { scheduledRequests.append($0) },
            concernNotificationsEnabled: { true }
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
            notificationCoordinator: nil,
            configureNotificationCenter: { _ in },
            scheduleNotification: { scheduledRequests.append($0) },
            concernNotificationsEnabled: { true }
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

@Test @MainActor func concernNotificationsDefaultOnAndPersistImmediateOptOutAndReenable() throws {
    let suite = "concern-notifications-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(DesktopConcernNotificationSettings.isEnabled(in: defaults))
    var notifications: [UNNotificationRequest] = []
    let appURL = try #require(URL(string: "https://my.personastack.ai"))
    let coordinator = PersonaStackWebView.Coordinator(appURL: appURL,
        notificationCoordinator: nil, configureNotificationCenter: { _ in },
        scheduleNotification: { notifications.append($0) }, cancelPermissionVerification: {},
        concernNotificationsEnabled: { DesktopConcernNotificationSettings.isEnabled(in: defaults) })
    func created() {
        coordinator.handleConcernMessage(name: "personastackConcern", isMainFrame: true,
            host: appURL.host, body: ["version": "1", "event": "created"], appURL: appURL)
    }
    created()
    #expect(notifications.count == 1)
    defaults.set(false, forKey: DesktopConcernNotificationSettings.enabledKey)
    let reloadedDefaults = try #require(UserDefaults(suiteName: suite))
    #expect(!DesktopConcernNotificationSettings.isEnabled(in: reloadedDefaults))
    created()
    #expect(notifications.count == 1)
    defaults.set(true, forKey: DesktopConcernNotificationSettings.enabledKey)
    #expect(DesktopConcernNotificationSettings.isEnabled(in: reloadedDefaults))
    #expect(notifications.count == 1)
    created()
    #expect(notifications.count == 2)
    #expect(notifications.allSatisfy { $0.content.userInfo.isEmpty })
    // The concern preference does not interfere with update action routing.
    #expect(DesktopNotificationCoordinator.updateAction(requestIdentifier: "personastack-update-ready-1.0.0",
        actionIdentifier: UNNotificationDefaultActionIdentifier) == .restart)
}

@Test @MainActor func menuBarReceiverRequestsNotificationAuthorizationBeforeAnyVisibleWindow() throws {
    var authorizations = 0
    let appURL = try #require(URL(string: "https://my.personastack.ai"))
    let coordinator = PersonaStackWebView.Coordinator(appURL: appURL,
        notificationCoordinator: nil, configureNotificationCenter: { _ in },
        scheduleNotification: { _ in }, cancelPermissionVerification: {})
    let host = MainWebViewHost(appURL: appURL, loadPage: false,
        authorizeNotifications: { authorizations += 1 }, coordinator: coordinator)
    defer { host.retire() }
    #expect(host.webView.window != nil)
    #expect(authorizations == 1)
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    host.attach(to: container)
    host.park(from: container)
    host.attach(to: container)
    #expect(authorizations == 1)
}
