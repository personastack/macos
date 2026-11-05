import Foundation
import PersonaStackCore
import ServiceManagement

enum IMessageSetupLifetimeError: Error, Equatable, LocalizedError {
    case applicationsRequired, signatureRequired, backgroundApprovalRequired
    var errorDescription: String? {
        switch self {
        case .applicationsRequired: "Install PersonaStack in Applications with the PersonaStack installer. Then reopen the app."
        case .signatureRequired: "PersonaStack's app signature could not be verified. Reinstall with the PersonaStack installer."
        case .backgroundApprovalRequired: "Allow PersonaStack in System Settings → General → Login Items & Extensions."
        }
    }
}

@MainActor enum IMessageSetupLifetime {
    static var backgroundReady: Bool {
        DesktopLoginItemRegistration.installationStatus() == .ready
            && DesktopLoginItemRegistration.isCurrentExecutableRegistered()
    }

    /// Explicit setup only. This prepares the existing app login registration
    /// and never changes either family's enabled or paused preference.
    static func prepareBackgroundConnection(configuration: DesktopEnvironmentConfiguration,
        bundleURL: URL = Bundle.main.bundleURL, volumeIsReadOnly: Bool? = nil,
        applicationDirectories: [URL] = DesktopLoginItemRegistration.applicationDirectories,
        signatureValid: @MainActor (URL) -> Bool = { DesktopLoginItemRegistration.hasValidBundleSignature(bundleURL: $0) },
        prepareUpdater: @MainActor () throws -> Void = { try DesktopUpdater.shared.prepareToEnableBackgroundAgents() },
        preferences: UserDefaults = .standard,
        executableIdentity: @MainActor (URL) -> String? = { DesktopLoginItemRegistration.executableIdentity(bundleURL: $0) },
        loginService: DesktopLoginItemRegistration.Service = .current
    ) async throws {
        try Task.checkCancellation()
        guard loginService.isAcceptingRegistrations else { throw CancellationError() }
        let canonical = try DesktopEnvironmentConfiguration(appURL: configuration.appOrigin,
            gatewayURL: configuration.gatewayURL.absoluteString, mcpURL: configuration.mcpURL.absoluteString)
        guard canonical == configuration else { throw DesktopEnvironmentConfigurationError.invalidStoredConfiguration }
        switch DesktopLoginItemRegistration.installationStatus(bundleURL: bundleURL,
            volumeIsReadOnly: volumeIsReadOnly, applicationDirectories: applicationDirectories, signatureValid: signatureValid) {
        case .ready: break
        case .applicationsRequired: throw IMessageSetupLifetimeError.applicationsRequired
        case .signatureRequired: throw IMessageSetupLifetimeError.signatureRequired
        }
        try Task.checkCancellation()
        try prepareUpdater()
        try Task.checkCancellation()
        guard try await DesktopLoginItemRegistration.registerCurrentExecutable(preferences: preferences,
            bundleURL: bundleURL, volumeIsReadOnly: volumeIsReadOnly, applicationDirectories: applicationDirectories,
            signatureValid: signatureValid, identity: executableIdentity, service: loginService) == .enabled else {
            throw IMessageSetupLifetimeError.backgroundApprovalRequired
        }
    }

    static func isApplicationsInstall(_ bundleURL: URL, roots: [URL]) -> Bool {
        DesktopLoginItemRegistration.isApplicationsInstall(bundleURL, roots: roots)
    }

    /// A canceled replacement can later accept a fresh explicit setup. Keep the
    /// actor bound to a live Desktop Control socket while withdrawing all grants.
    static func prepareForReplacement() async {
        await IMessageSetupManager.shared.shutdown()
        await DesktopControlRuntime.shared.suspendIMessageForReplacement()
    }
}
