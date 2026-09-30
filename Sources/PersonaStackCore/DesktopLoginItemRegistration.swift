import Foundation
import ServiceManagement

@MainActor
public enum DesktopLoginItemRegistration {
    public static let firstLaunchHandledKey = "desktopLoginItemFirstLaunchHandled"
    public static let errorKey = "desktopControlLoginItemError"
    private static let approvalMessage = "Allow PersonaStack in System Settings → General → Login Items."

    public static func clearResolvedApprovalError(
        preferences: UserDefaults = .standard,
        status: SMAppService.Status = SMAppService.mainApp.status
    ) {
        guard status == .enabled, preferences.string(forKey: errorKey) == approvalMessage else { return }
        preferences.set("", forKey: errorKey)
    }

    public static func enableOnFirstLaunch(
        preferences: UserDefaults = .standard,
        bundleURL: URL = Bundle.main.bundleURL,
        volumeIsReadOnly: Bool? = nil,
        status: () -> SMAppService.Status = { SMAppService.mainApp.status },
        register: () throws -> Void = { try SMAppService.mainApp.register() }
    ) {
        guard bundleURL.pathExtension == "app" else { return }
        let readOnly = volumeIsReadOnly
            ?? ((try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false)
        guard !DesktopUpdatePolicy.requiresApplicationsInstall(bundleURL: bundleURL, volumeIsReadOnly: readOnly),
              !preferences.bool(forKey: firstLaunchHandledKey) else { return }
        preferences.set(true, forKey: firstLaunchHandledKey)

        let currentStatus = status()
        guard currentStatus != .enabled else { return }
        if currentStatus == .requiresApproval {
            preferences.set(approvalMessage, forKey: errorKey)
            return
        }
        do {
            try register()
            preferences.set(status() == .requiresApproval ? approvalMessage : "", forKey: errorKey)
        } catch {
            preferences.set(error.localizedDescription, forKey: errorKey)
        }
    }
}
