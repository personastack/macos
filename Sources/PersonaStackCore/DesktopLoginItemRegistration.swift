import Foundation
import ServiceManagement

@MainActor
public enum DesktopLoginItemRegistration {
    public static let firstLaunchHandledKey = "desktopLoginItemFirstLaunchHandled"
    public static let errorKey = "desktopControlLoginItemError"
    public static let approvalMessage = "Allow PersonaStack in System Settings → General → Login Items & Extensions."
    private static let legacyApprovalMessage = "Allow PersonaStack in System Settings → General → Login Items."
    public static let unconfirmedMessage = "macOS has not confirmed Launch at Login registration. Retry setup or review General → Login Items & Extensions."

    /// notFound also describes a service macOS has never registered. It does
    /// not establish that the application bundle is missing.
    public static func registerIfNeeded(
        status: () -> SMAppService.Status = { SMAppService.mainApp.status },
        register: () throws -> Void = { try SMAppService.mainApp.register() }
    ) throws -> SMAppService.Status {
        let current = status()
        guard current == .notRegistered || current == .notFound else { return current }
        do { try register() }
        catch {
            let observed = status()
            guard observed == .enabled || observed == .requiresApproval else { throw error }
            return observed
        }
        return status()
    }

    public static func clearResolvedApprovalError(
        preferences: UserDefaults = .standard,
        status: SMAppService.Status = SMAppService.mainApp.status
    ) {
        guard status == .enabled,
              let message = preferences.string(forKey: errorKey),
              [approvalMessage, legacyApprovalMessage, unconfirmedMessage].contains(message) else { return }
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

        guard status() != .enabled else { return }
        do {
            let current = try registerIfNeeded(status: status, register: register)
            preferences.set(current == .enabled ? "" : (current == .requiresApproval ? approvalMessage : unconfirmedMessage), forKey: errorKey)
        } catch {
            preferences.set(error.localizedDescription, forKey: errorKey)
        }
    }
}
