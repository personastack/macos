import Foundation
import ServiceManagement
import Security
import CryptoKit

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

    /// Identifies the registered executable, path and agent definition. This is
    /// a reconciliation receipt, never evidence of approval or authorization.
    public static let registeredExecutableKey = "desktopLoginItemRegisteredExecutable"

    @MainActor public final class Service {
        let status: @MainActor () -> SMAppService.Status
        let unregister: @MainActor () async throws -> Void
        let legacyStatus: @MainActor () -> SMAppService.Status
        let unregisterLegacy: @MainActor () async throws -> Void
        let register: @MainActor () throws -> Void
        let prepareFirstLaunch: @MainActor (UserDefaults, URL, Bool) -> Bool
        var pending: Task<SMAppService.Status, any Error>?

        public var hasPendingRegistration: Bool { pending != nil }
        private var temporaryAdmissionClosed = false
        private var terminalAdmissionClosed = false
        public var isAcceptingRegistrations: Bool { !temporaryAdmissionClosed && !terminalAdmissionClosed }

        /// Orderly exit/replacement closes admission before joining the known
        /// app-wide operation. Caller cancellation cannot abandon that repair.
        public func stopAdmission(terminal: Bool = false) {
            if terminal { terminalAdmissionClosed = true }
            else { temporaryAdmissionClosed = true }
        }

        public func stopAdmissionAndDrain() async {
            if !terminalAdmissionClosed { stopAdmission() }
            if let pending { _ = await pending.result }
        }

        /// A canceled replacement may reopen its temporary closure. A later
        /// terminal Quit remains closed even if that older replacement cancels.
        public func resumeAdmission() { temporaryAdmissionClosed = false }

        /// The current orderly-Quit owner may cancel its terminal closure only
        /// after joining registration. An updater cancellation never calls this.
        public func cancelTerminalAdmission() {
            guard pending == nil else { return }
            terminalAdmissionClosed = false
        }

        public init(status: @escaping @MainActor () -> SMAppService.Status,
                    unregister: @escaping @MainActor () async throws -> Void,
                    legacyStatus: @escaping @MainActor () -> SMAppService.Status,
                    unregisterLegacy: @escaping @MainActor () async throws -> Void,
                    register: @escaping @MainActor () throws -> Void,
                    prepareFirstLaunch: @escaping @MainActor (UserDefaults, URL, Bool) -> Bool = { _, _, _ in false }) {
            self.status = status
            self.unregister = unregister
            self.legacyStatus = legacyStatus
            self.unregisterLegacy = unregisterLegacy
            self.register = register
            self.prepareFirstLaunch = prepareFirstLaunch
        }

        public static let current = Service(
            status: { loginStatus() },
            unregister: { try await SMAppService.agent(plistName: crashRecoveryAgentPlistName).unregister() },
            legacyStatus: { SMAppService.mainApp.status },
            unregisterLegacy: { try await SMAppService.mainApp.unregister() },
            register: { try SMAppService.agent(plistName: crashRecoveryAgentPlistName).register() },
            prepareFirstLaunch: { preferences, bundle, readOnly in
                var registered = false
                enableOnFirstLaunch(preferences: preferences, bundleURL: bundle, volumeIsReadOnly: readOnly,
                    register: {
                        do { try SMAppService.agent(plistName: crashRecoveryAgentPlistName).register() }
                        catch { preferences.removeObject(forKey: registeredExecutableKey); throw error }
                        registered = true
                    })
                return registered
            })
    }

    public enum InstallationStatus: Equatable { case ready, applicationsRequired, signatureRequired }

    public static var applicationDirectories: [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
    }

    /// Read-only preflight shared by startup, explicit registration and setup.
    public static func installationStatus(
        bundleURL: URL = Bundle.main.bundleURL, volumeIsReadOnly: Bool? = nil,
        applicationDirectories: [URL] = DesktopLoginItemRegistration.applicationDirectories,
        signatureValid: @MainActor (URL) -> Bool = { hasValidBundleSignature(bundleURL: $0) }
    ) -> InstallationStatus {
        let readOnly = volumeIsReadOnly
            ?? ((try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? true)
        guard isApplicationsInstall(bundleURL, roots: applicationDirectories),
              !DesktopUpdatePolicy.requiresApplicationsInstall(bundleURL: bundleURL, volumeIsReadOnly: readOnly) else {
            return .applicationsRequired
        }
        return signatureValid(bundleURL) ? .ready : .signatureRequired
    }

    public static func isApplicationsInstall(_ bundleURL: URL, roots: [URL]) -> Bool {
        guard bundleURL.isFileURL, bundleURL.pathExtension == "app" else { return false }
        let bundle = bundleURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return roots.contains { root in
            guard root.isFileURL else { return false }
            let components = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            return bundle.count > components.count && bundle.starts(with: components)
        }
    }

    public static func executableIdentity(bundleURL: URL) -> String? {
        guard let executable = Bundle(url: bundleURL)?.executableURL else { return nil }
        var hash = SHA256()
        hash.update(data: Data(bundleURL.resolvingSymlinksInPath().standardizedFileURL.path.utf8))
        for file in [executable, bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/\(crashRecoveryAgentPlistName)")] {
            hash.update(data: Data([0]))
            do {
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty { hash.update(data: chunk) }
            } catch { return nil }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func isCurrentExecutableRegistered(
        preferences: UserDefaults = .standard, bundleURL: URL = Bundle.main.bundleURL,
        identity: @MainActor (URL) -> String? = { executableIdentity(bundleURL: $0) },
        status: SMAppService.Status = loginStatus()
    ) -> Bool {
        guard status == .enabled, let current = identity(bundleURL) else { return false }
        return preferences.string(forKey: registeredExecutableKey) == current
    }

    /// Shared startup owner. A later disabled entry is user intent. Only an
    /// enabled entry can be refreshed without an explicit Setup action.
    public static func reconcileAtLaunch(
        preferences: UserDefaults = .standard, bundleURL: URL = Bundle.main.bundleURL,
        volumeIsReadOnly: Bool? = nil,
        applicationDirectories: [URL] = DesktopLoginItemRegistration.applicationDirectories,
        signatureValid: @MainActor (URL) -> Bool = { hasValidBundleSignature(bundleURL: $0) },
        identity: @MainActor (URL) -> String? = { executableIdentity(bundleURL: $0) },
        service: Service = .current
    ) async {
        guard service.isAcceptingRegistrations,
              installationStatus(bundleURL: bundleURL, volumeIsReadOnly: volumeIsReadOnly,
                  applicationDirectories: applicationDirectories, signatureValid: signatureValid) == .ready else { return }
        // Existing first-install and legacy migration policy remains the owner.
        // Only a real, nonthrowing register permits stamping its new entry.
        if service.pending == nil, service.prepareFirstLaunch(preferences, bundleURL, false),
           [SMAppService.Status.enabled, .requiresApproval].contains(service.status()),
           let current = identity(bundleURL) {
            preferences.set(current, forKey: registeredExecutableKey)
        }
        guard service.pending != nil || service.status() == .enabled else { return }
        do {
            _ = try await registerCurrentExecutable(preferences: preferences, bundleURL: bundleURL,
                volumeIsReadOnly: volumeIsReadOnly, applicationDirectories: applicationDirectories, signatureValid: signatureValid,
                identity: identity, service: service)
        } catch { /* The shared operation records the registration failure. */ }
    }

    /// Explicit Setup can register a disabled entry. Startup calls this only
    /// for Enabled. Both paths join one awaited service replacement.
    public static func registerCurrentExecutable(
        preferences: UserDefaults = .standard, bundleURL: URL = Bundle.main.bundleURL,
        volumeIsReadOnly: Bool? = nil,
        applicationDirectories: [URL] = DesktopLoginItemRegistration.applicationDirectories,
        signatureValid: @MainActor (URL) -> Bool = { hasValidBundleSignature(bundleURL: $0) },
        identity: @MainActor (URL) -> String? = { executableIdentity(bundleURL: $0) },
        service: Service = .current
    ) async throws -> SMAppService.Status {
        try Task.checkCancellation()
        guard service.isAcceptingRegistrations else { throw CancellationError() }
        switch installationStatus(bundleURL: bundleURL, volumeIsReadOnly: volumeIsReadOnly,
            applicationDirectories: applicationDirectories, signatureValid: signatureValid) {
        case .ready: break
        case .applicationsRequired:
            throw CocoaError(.fileReadNoPermission, userInfo: [NSLocalizedDescriptionKey:
                "Install PersonaStack in Applications with the PersonaStack installer. Then reopen the app."])
        case .signatureRequired:
            throw CocoaError(.fileReadNoPermission, userInfo: [NSLocalizedDescriptionKey: invalidSignatureMessage])
        }
        if let pending = service.pending { return try await joinRegistration(pending) }
        guard let current = identity(bundleURL) else {
            preferences.removeObject(forKey: registeredExecutableKey)
            preferences.set(unconfirmedMessage, forKey: errorKey)
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: unconfirmedMessage])
        }
        let observed = service.status()
        clearResolvedApprovalError(preferences: preferences, status: observed)
        let message = preferences.string(forKey: errorKey) ?? ""
        if preferences.string(forKey: registeredExecutableKey) == current,
           (observed == .enabled && message.isEmpty
            || observed == .requiresApproval && (message.isEmpty || message == approvalMessage)) { return observed }
        preferences.removeObject(forKey: registeredExecutableKey)
        let pending = Task { @MainActor in
            defer { service.pending = nil }
            do {
                let result = try await resetAndRegister(status: service.status, unregister: service.unregister,
                    legacyStatus: service.legacyStatus, unregisterLegacy: service.unregisterLegacy, register: service.register)
                try Task.checkCancellation()
                if result == .enabled || result == .requiresApproval {
                    preferences.set(current, forKey: registeredExecutableKey)
                }
                preferences.set(result == .enabled ? "" : (result == .requiresApproval ? approvalMessage : unconfirmedMessage), forKey: errorKey)
                return result
            } catch {
                preferences.removeObject(forKey: registeredExecutableKey)
                preferences.set(error.localizedDescription, forKey: errorKey)
                throw error
            }
        }
        service.pending = pending
        return try await joinRegistration(pending)
    }

    private static func joinRegistration(_ task: Task<SMAppService.Status, any Error>) async throws -> SMAppService.Status {
        // Once started, this app-wide OS repair owns its completion. A canceled
        // UI waiter still joins it but cannot remove another family's recovery.
        let result = try await task.value
        try Task.checkCancellation()
        return result
    }

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
        preferences.removeObject(forKey: registeredExecutableKey)
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
