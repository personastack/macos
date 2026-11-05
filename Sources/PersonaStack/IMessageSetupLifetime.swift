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
        let bundle = Bundle.main.bundleURL
        let roots = [URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
        let readOnly = (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? true
        return isApplicationsInstall(bundle, roots: roots)
            && !DesktopUpdatePolicy.requiresApplicationsInstall(bundleURL: bundle, volumeIsReadOnly: readOnly)
            && DesktopLoginItemRegistration.hasValidBundleSignature(bundleURL: bundle)
            && DesktopLoginItemRegistration.loginStatus() == .enabled
    }

    /// Explicit setup only. This prepares the existing app login registration
    /// and never changes either family's enabled or paused preference.
    static func prepareBackgroundConnection(configuration: DesktopEnvironmentConfiguration,
        bundleURL: URL = Bundle.main.bundleURL, volumeIsReadOnly: Bool? = nil,
        applicationDirectories: [URL] = [URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)],
        signatureValid: @MainActor (URL) -> Bool = { DesktopLoginItemRegistration.hasValidBundleSignature(bundleURL: $0) },
        prepareUpdater: @MainActor () throws -> Void = { try DesktopUpdater.shared.prepareToEnableBackgroundAgents() },
        registerLogin: @MainActor () throws -> Bool = { try DesktopLoginItemRegistration.registerAndMigrateLegacy() == .enabled }
    ) async throws {
        try Task.checkCancellation()
        let canonical = try DesktopEnvironmentConfiguration(appURL: configuration.appOrigin,
            gatewayURL: configuration.gatewayURL.absoluteString, mcpURL: configuration.mcpURL.absoluteString)
        guard canonical == configuration else { throw DesktopEnvironmentConfigurationError.invalidStoredConfiguration }
        let readOnly = volumeIsReadOnly ?? ((try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? true)
        guard isApplicationsInstall(bundleURL, roots: applicationDirectories),
              !DesktopUpdatePolicy.requiresApplicationsInstall(bundleURL: bundleURL, volumeIsReadOnly: readOnly) else {
            throw IMessageSetupLifetimeError.applicationsRequired
        }
        guard signatureValid(bundleURL) else { throw IMessageSetupLifetimeError.signatureRequired }
        try Task.checkCancellation()
        try prepareUpdater()
        guard try registerLogin() else { throw IMessageSetupLifetimeError.backgroundApprovalRequired }
    }

    static func isApplicationsInstall(_ bundleURL: URL, roots: [URL]) -> Bool {
        guard bundleURL.isFileURL, bundleURL.pathExtension == "app" else { return false }
        let bundle = bundleURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return roots.contains { root in
            guard root.isFileURL else { return false }
            let components = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            return bundle.count > components.count && bundle.starts(with: components)
        }
    }

    /// A canceled replacement can later accept a fresh explicit setup. Keep the
    /// actor bound to a live Desktop Control socket while withdrawing all grants.
    static func prepareForReplacement() async {
        await IMessageSetupManager.shared.shutdown()
        await DesktopControlRuntime.shared.suspendIMessageForReplacement()
    }
}
