import Foundation
import Testing
import UserNotifications
@testable import PersonaStack

struct DesktopNotificationCoordinatorTests {
    @Test @MainActor func notificationActionsRouteToTheMatchingUpdateFlow() {
        #expect(DesktopNotificationCoordinator.updateAction(
            requestIdentifier: "personastack-update-available-0.1.49",
            actionIdentifier: UNNotificationDefaultActionIdentifier
        ) == .download)
        #expect(DesktopNotificationCoordinator.updateAction(
            requestIdentifier: "personastack-update-available-0.1.49",
            actionIdentifier: "PERSONASTACK_DOWNLOAD_UPDATE"
        ) == .download)
        #expect(DesktopNotificationCoordinator.updateAction(
            requestIdentifier: "personastack-update-ready-0.1.49",
            actionIdentifier: UNNotificationDefaultActionIdentifier
        ) == .restart)
        #expect(DesktopNotificationCoordinator.updateAction(
            requestIdentifier: "personastack-update-ready-0.1.49",
            actionIdentifier: "PERSONASTACK_RESTART_UPDATE"
        ) == .restart)
    }

    @Test @MainActor func laterAndUnknownNotificationsDoNotRunUpdateActions() {
        #expect(DesktopNotificationCoordinator.updateAction(
            requestIdentifier: "personastack-update-ready-0.1.49",
            actionIdentifier: "PERSONASTACK_LATER"
        ) == nil)
        #expect(DesktopNotificationCoordinator.updateAction(
            requestIdentifier: "personastack-concern-123",
            actionIdentifier: UNNotificationDefaultActionIdentifier
        ) == nil)
    }
}
