import Foundation
import ServiceManagement
import Security

@MainActor
public enum DesktopLoginItemRegistration {
    public static let firstLaunchHandledKey = "desktopLoginItemFirstLaunchHandled"
    public static let crashRecoveryMigrationHandledKey = "desktopCrashRecoveryLoginMigrationHandled"
    public static let errorKey = "desktopControlLoginItemError"
    public static let crashRecoveryAgentPlistName = "ai.personastack.desktop.crash-recovery.plist"
    public static let approvalMessage = "Allow PersonaStack in System Settings → General → Login Items & Extensions."
    private static let legacyApprovalMessage = "Allow PersonaStack in System Settings → General → Login Items."
    public static let unconfirmedMessage = "macOS has not confirmed Launch at Login registration. Retry setup or review General → Login Items & Extensions."
    public static let invalidSignatureMessage = "The current PersonaStack app has no valid bundle signature. macOS cannot register its login service. An enabled entry in Settings may belong to an older installation."

    public enum SetupPhase: Equatable, Sendable { case removeAgent, removeLegacy, registerCurrent }
    public struct SetupFailure: Error {
        public let phase: SetupPhase
        public let underlying: any Error
    }

    public static func hasValidBundleSignature(bundleURL: URL = Bundle.main.bundleURL) -> Bool {
        var code: SecStaticCode?
        guard bundleURL.pathExtension == "app",
              SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &code) == errSecSuccess,
              let code else { return false }
        return SecStaticCodeCheckValidity(code,
            SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), nil) == errSecSuccess
    }

    /// Called in the installing user's session after quitting the app. Removing
    /// the SM registration also retires its crash supervisor before file removal.
    public static func unregisterForUninstall(
        preferences: UserDefaults = .standard,
        status: () -> SMAppService.Status = { loginStatus() },
        unregister: () throws -> Void = { try SMAppService.agent(plistName: crashRecoveryAgentPlistName).unregister() },
        legacyStatus: () -> SMAppService.Status = { SMAppService.mainApp.status },
        unregisterLegacy: () throws -> Void = { try SMAppService.mainApp.unregister() }
    ) throws {
        try unregisterIfNeeded(status: status, unregister: unregister)
        try unregisterIfNeeded(status: legacyStatus, unregister: unregisterLegacy)
        preferences.set(false, forKey: firstLaunchHandledKey)
        preferences.set(false, forKey: crashRecoveryMigrationHandledKey)
    }

    private static func unregisterIfNeeded(status: () -> SMAppService.Status, unregister: () throws -> Void) throws {
        let current = status()
        if current == .enabled || current == .requiresApproval { try unregister() }
        let observed = status()
        guard observed == .notRegistered || observed == .notFound else { throw CocoaError(.fileWriteUnknown) }
    }

    public static func loginStatus(
        agentStatus: () -> SMAppService.Status = { SMAppService.agent(plistName: crashRecoveryAgentPlistName).status }
    ) -> SMAppService.Status {
        agentStatus()
    }

    /// Explicit Setup retires both registrations. Await service termination
    /// before registering the current bundle. Passive reads never call this.
    public static func resetAndRegister(
        status: () -> SMAppService.Status,
        unregister: () async throws -> Void,
        legacyStatus: () -> SMAppService.Status,
        unregisterLegacy: () async throws -> Void,
        register: () throws -> Void
    ) async throws -> SMAppService.Status {
        try Task.checkCancellation()
        var failure: SetupFailure?
        do { try await unregisterForSetup(status: status, unregister: unregister) }
        catch {
            try Task.checkCancellation()
            failure = .init(phase: .removeAgent, underlying: error)
        }
        try Task.checkCancellation()
        do { try await unregisterForSetup(status: legacyStatus, unregister: unregisterLegacy) }
        catch {
            try Task.checkCancellation()
            if failure == nil { failure = .init(phase: .removeLegacy, underlying: error) }
        }
        try Task.checkCancellation()
        if let failure { throw failure }
        // Explicit repair must actually register this bundle. A stale Enabled
        // readback cannot turn a rejected registration into success.
        do { try register() }
        catch { throw SetupFailure(phase: .registerCurrent, underlying: error) }
        return status()
    }

    private static func unregisterForSetup(
        status: () -> SMAppService.Status, unregister: () async throws -> Void
    ) async throws {
        let current = status()
        if current == .enabled || current == .requiresApproval {
            do { try await unregister() }
            catch {
                let failure = error as NSError
                guard #available(macOS 15, *), failure.domain == SMAppServiceErrorDomain,
                      failure.code == kSMErrorJobNotFound else { throw error }
            }
        }
        let observed = status()
        guard observed == .notRegistered || observed == .notFound else {
            throw CocoaError(.fileWriteUnknown)
        }
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
