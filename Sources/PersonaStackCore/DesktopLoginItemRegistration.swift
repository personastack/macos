import Foundation
import ServiceManagement

@MainActor
public enum DesktopLoginItemRegistration {
    public static let firstLaunchHandledKey = "desktopLoginItemFirstLaunchHandled"
    public static let crashRecoveryMigrationHandledKey = "desktopCrashRecoveryLoginMigrationHandled"
    public static let errorKey = "desktopControlLoginItemError"
    public static let crashRecoveryAgentPlistName = "ai.personastack.desktop.crash-recovery.plist"
    public static let approvalMessage = "Allow PersonaStack in System Settings → General → Login Items & Extensions."
    private static let legacyApprovalMessage = "Allow PersonaStack in System Settings → General → Login Items."
    public static let unconfirmedMessage = "macOS has not confirmed Launch at Login registration. Retry setup or review General → Login Items & Extensions."

    public static func loginStatus(
        agentStatus: () -> SMAppService.Status = { SMAppService.agent(plistName: crashRecoveryAgentPlistName).status }
    ) -> SMAppService.Status {
        agentStatus()
    }

    /// notFound also describes a service macOS has never registered. It does
    /// not establish that the application bundle is missing.
    public static func registerIfNeeded(
        status: () -> SMAppService.Status = { SMAppService.agent(plistName: crashRecoveryAgentPlistName).status },
        register: () throws -> Void = { try SMAppService.agent(plistName: crashRecoveryAgentPlistName).register() }
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

    public static func registerAndMigrateLegacy(
        status: () -> SMAppService.Status = { SMAppService.agent(plistName: crashRecoveryAgentPlistName).status },
        register: () throws -> Void = { try SMAppService.agent(plistName: crashRecoveryAgentPlistName).register() },
        unregisterAgent: () throws -> Void = { try SMAppService.agent(plistName: crashRecoveryAgentPlistName).unregister() },
        legacyStatus: () -> SMAppService.Status = { SMAppService.mainApp.status },
        unregisterLegacy: () throws -> Void = { try SMAppService.mainApp.unregister() },
        registerLegacy: () throws -> Void = { try SMAppService.mainApp.register() }
    ) throws -> SMAppService.Status {
        let legacy = legacyStatus()
        let agentWasEnabled = status() == .enabled
        var current = try registerIfNeeded(status: status, register: register)
        guard current == .enabled, legacy == .enabled else { return current }
        do { try unregisterLegacy() }
        catch {
            if !agentWasEnabled { try? unregisterAgent() }
            throw error
        }
        current = status()
        guard current == .enabled else {
            do { try registerLegacy() } catch { /* Still roll back the new owner below. */ }
            if !agentWasEnabled { try? unregisterAgent() }
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: unconfirmedMessage])
        }
        return current
    }

    public static func clearResolvedApprovalError(
        preferences: UserDefaults = .standard,
        status: SMAppService.Status = loginStatus()
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
        status: () -> SMAppService.Status = { SMAppService.agent(plistName: crashRecoveryAgentPlistName).status },
        register: () throws -> Void = { try SMAppService.agent(plistName: crashRecoveryAgentPlistName).register() },
        legacyStatus: () -> SMAppService.Status = { SMAppService.mainApp.status },
        unregisterLegacy: () throws -> Void = { try SMAppService.mainApp.unregister() },
        unregisterAgent: () throws -> Void = { try SMAppService.agent(plistName: crashRecoveryAgentPlistName).unregister() },
        registerLegacy: () throws -> Void = { try SMAppService.mainApp.register() }
    ) {
        guard bundleURL.pathExtension == "app" else { return }
        let readOnly = volumeIsReadOnly
            ?? ((try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false)
        guard !DesktopUpdatePolicy.requiresApplicationsInstall(bundleURL: bundleURL, volumeIsReadOnly: readOnly) else { return }
        let firstLaunch = !preferences.bool(forKey: firstLaunchHandledKey)
        if !firstLaunch {
            guard !preferences.bool(forKey: crashRecoveryMigrationHandledKey) else { return }
            let legacy = legacyStatus()
            guard legacy == .enabled else {
                preferences.set(true, forKey: crashRecoveryMigrationHandledKey)
                return
            }
            do {
                let current = try registerAndMigrateLegacy(status: status, register: register,
                    unregisterAgent: unregisterAgent, legacyStatus: { legacy }, unregisterLegacy: unregisterLegacy,
                    registerLegacy: registerLegacy)
                preferences.set(current == .enabled, forKey: crashRecoveryMigrationHandledKey)
                preferences.set(current == .enabled ? "" : (current == .requiresApproval ? approvalMessage : unconfirmedMessage), forKey: errorKey)
            } catch {
                preferences.set(error.localizedDescription, forKey: errorKey)
            }
            return
        }

        preferences.set(true, forKey: firstLaunchHandledKey)
        let legacy = legacyStatus()
        do {
            let current = try registerAndMigrateLegacy(status: status, register: register,
                unregisterAgent: unregisterAgent, legacyStatus: { legacy }, unregisterLegacy: unregisterLegacy,
                registerLegacy: registerLegacy)
            preferences.set(current == .enabled, forKey: crashRecoveryMigrationHandledKey)
            preferences.set(current == .enabled ? "" : (current == .requiresApproval ? approvalMessage : unconfirmedMessage), forKey: errorKey)
        } catch {
            preferences.set(error.localizedDescription, forKey: errorKey)
        }
    }
}
