import Foundation
import UserNotifications

@MainActor
final class DesktopNotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let shared = DesktopNotificationCoordinator()

    enum UpdateAction: Equatable {
        case download
        case restart
    }

    private let center = UNUserNotificationCenter.current()
    private let availableCategory = "PERSONASTACK_DESKTOP_UPDATE_AVAILABLE"
    private let readyCategory = "PERSONASTACK_DESKTOP_UPDATE_READY"

    private override init() {
        super.init()
    }

    func install() {
        center.delegate = self
        let download = UNNotificationAction(identifier: "PERSONASTACK_DOWNLOAD_UPDATE", title: "Download Update…", options: [.foreground])
        let restart = UNNotificationAction(identifier: "PERSONASTACK_RESTART_UPDATE", title: "Restart Now", options: [.foreground])
        let later = UNNotificationAction(identifier: "PERSONASTACK_LATER", title: "Later")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: availableCategory, actions: [download, later], intentIdentifiers: []),
            UNNotificationCategory(identifier: readyCategory, actions: [restart, later], intentIdentifiers: [])
        ])
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func postUpdateAvailable(version: String) {
        let content = UNMutableNotificationContent()
        content.title = "PersonaStack update available"
        content.body = "Version \(version) is ready to download."
        content.categoryIdentifier = availableCategory
        let request = UNNotificationRequest(
            identifier: "personastack-update-available-\(version)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    func postUpdateReady(version: String) {
        let content = UNMutableNotificationContent()
        content.title = "PersonaStack update ready"
        content.body = "Restarting closes PersonaStack windows and stops Desktop Control tasks. Choose Restart Now to install version \(version)."
        content.categoryIdentifier = readyCategory
        let request = UNNotificationRequest(
            identifier: "personastack-update-ready-\(version)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    func clearUpdateNotifications(version: String) {
        clearAvailableNotification(version: version)
        clearReadyNotification(version: version)
    }

    func clearAvailableNotification(version: String) {
        clearNotification(identifier: "personastack-update-available-\(version)")
    }

    func clearReadyNotification(version: String) {
        clearNotification(identifier: "personastack-update-ready-\(version)")
    }

    private func clearNotification(identifier: String) {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let requestIdentifier = response.notification.request.identifier
        let actionIdentifier = response.actionIdentifier
        await MainActor.run {
            switch Self.updateAction(requestIdentifier: requestIdentifier, actionIdentifier: actionIdentifier) {
            case .download: DesktopUpdater.shared.downloadLatestUpdate()
            case .restart: DesktopUpdater.shared.restartToInstall()
            case nil: break
            }
        }
    }

    static func updateAction(requestIdentifier: String, actionIdentifier: String) -> UpdateAction? {
        let isDefault = actionIdentifier == UNNotificationDefaultActionIdentifier
        if requestIdentifier.hasPrefix("personastack-update-ready-") {
            return isDefault || actionIdentifier == "PERSONASTACK_RESTART_UPDATE" ? .restart : nil
        }
        if requestIdentifier.hasPrefix("personastack-update-available-") {
            return isDefault || actionIdentifier == "PERSONASTACK_DOWNLOAD_UPDATE" ? .download : nil
        }
        return nil
    }
}
