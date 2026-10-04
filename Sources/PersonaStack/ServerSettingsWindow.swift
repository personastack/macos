import AppKit
import Combine
import PersonaStackCore
import SwiftUI
import WebKit

@MainActor
protocol DesktopEnvironmentSettingsLifecycle: AnyObject {
    func beginSwitch()
    func prepareForSwitch() async throws
    func waitForLocalSessions() async
    func replaceHost(with appPageURL: URL)
    func completeSwitch()
    func abortSwitch()
}

@MainActor
final class LiveDesktopEnvironmentSettingsLifecycle: DesktopEnvironmentSettingsLifecycle {
    private var previousView: WKWebView?
    private var previousAppURL: URL?

    func beginSwitch() {
        let view = MainWebViewHost.shared.webView
        previousView = view
        previousAppURL = MainWebViewHost.shared.coordinator.appURL
        ChatWindowManager.shared.invalidateSession()
        StackWindowManager.shared.invalidateSession()
        ChatWindowManager.shared.unregister(view)
        StackWindowManager.shared.unregister(view)
        LocalSessionManager.shared.invalidate(view)
        DesktopSkillsManager.shared.unregister(view)
        DesktopControlSetupManager.shared.unregister(view)
    }

    func prepareForSwitch() async throws {
        try await DesktopControlRuntime.shared.prepareForEnvironmentSwitch()
    }

    func waitForLocalSessions() async {
        guard let previousView else { return }
        await LocalSessionManager.shared.invalidateAndWait(previousView)
    }

    func replaceHost(with appPageURL: URL) {
        _ = MainWebViewHost.replaceSharedHost(with: appPageURL)
        previousView = nil
        previousAppURL = nil
    }

    func completeSwitch() {
        DesktopControlRuntime.shared.completeEnvironmentSwitch()
    }

    func abortSwitch() {
        if let previousView, let previousAppURL {
            ChatWindowManager.shared.register(previousView, appURL: previousAppURL)
            StackWindowManager.shared.register(previousView, appURL: previousAppURL)
            LocalSessionManager.shared.register(previousView, appURL: previousAppURL)
            DesktopSkillsManager.shared.register(previousView, appURL: previousAppURL)
            DesktopControlSetupManager.shared.register(previousView, appURL: previousAppURL)
        }
        DesktopControlRuntime.shared.abortEnvironmentSwitch()
    }
}

@MainActor
final class DesktopEnvironmentSettings: ObservableObject {
    static let shared = DesktopEnvironmentSettings()

    @Published private(set) var configuration: DesktopEnvironmentConfiguration
    @Published private(set) var appPageURL: URL
    @Published private(set) var generation = UUID()
    @Published private(set) var isApplying = false
    @Published var errorMessage: String?
    @Published var draftAppURL = ""
    @Published var draftGatewayURL = ""
    @Published var draftMCPURL = ""
    @Published var validationMessage: String?

    private let store: DesktopEnvironmentConfigurationStore
    private let launchURL: URL
    private let lifecycle: any DesktopEnvironmentSettingsLifecycle
    private var requiresApply = false
    private var switchNeedsRetry = false
    var hasTrustedConfiguration: Bool { !requiresApply }

    init(store: DesktopEnvironmentConfigurationStore = .shared, launchURL: URL = LaunchConfiguration.url(),
         lifecycle: any DesktopEnvironmentSettingsLifecycle = LiveDesktopEnvironmentSettingsLifecycle()) {
        self.store = store
        self.launchURL = launchURL
        self.lifecycle = lifecycle
        configuration = .production
        appPageURL = launchURL
        reloadDraft()
    }

    func reloadDraft() {
        do {
            configuration = try store.current(fallbackAppURL: launchURL)
            appPageURL = configuration.appPageURL
            draftAppURL = configuration.appURL.absoluteString
            draftGatewayURL = configuration.gatewayURL.absoluteString
            draftMCPURL = configuration.mcpURL.absoluteString
            errorMessage = nil
            validationMessage = nil
            requiresApply = false
        } catch DesktopEnvironmentConfigurationError.unconfiguredEnvironment {
            configuration = .production
            appPageURL = launchURL
            draftAppURL = Self.appBaseCandidate(launchURL)
            draftGatewayURL = ""
            draftMCPURL = ""
            errorMessage = DesktopEnvironmentConfigurationError.unconfiguredEnvironment.localizedDescription
            validationMessage = nil
            requiresApply = true
        } catch {
            configuration = .production
            appPageURL = store.hasStoredValue() ? NavigationPolicy.defaultURL : launchURL
            draftAppURL = configuration.appURL.absoluteString
            draftGatewayURL = configuration.gatewayURL.absoluteString
            draftMCPURL = configuration.mcpURL.absoluteString
            errorMessage = error.localizedDescription
            validationMessage = nil
            requiresApply = true
        }
    }

    func apply(_ next: DesktopEnvironmentConfiguration) async -> Bool {
        guard !isApplying else { return false }
        if next == configuration && !requiresApply && !switchNeedsRetry {
            do {
                try store.save(next)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            return errorMessage == nil
        }
        isApplying = true
        defer { isApplying = false }
        errorMessage = nil

        do {
            lifecycle.beginSwitch()
            try await lifecycle.prepareForSwitch()
            await lifecycle.waitForLocalSessions()
            try store.save(next)
            lifecycle.replaceHost(with: next.appPageURL)
            configuration = next
            appPageURL = next.appPageURL
            generation = UUID()
            draftAppURL = next.appURL.absoluteString
            draftGatewayURL = next.gatewayURL.absoluteString
            draftMCPURL = next.mcpURL.absoluteString
            requiresApply = false
            switchNeedsRetry = false
            lifecycle.completeSwitch()
            return true
        } catch {
            errorMessage = error.localizedDescription
            switchNeedsRetry = true
            lifecycle.abortSwitch()
            return false
        }
    }

    private static func appBaseCandidate(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.user = nil
        parts.password = nil
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        return parts.string ?? ""
    }
}

struct DesktopServerSettingsWindow: View {
    @ObservedObject private var settings = DesktopEnvironmentSettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("PersonaStack Servers")
                .font(.title2.weight(.semibold))
            Text("Use the base URL for each service. HTTP and HTTPS are supported.")
                .foregroundStyle(.secondary)
            Text("HTTP traffic is unencrypted. Use it only on a network you trust.")
                .font(.callout)
                .foregroundStyle(.orange)
            urlField("App URL", placeholder: "https://my.personastack.ai", text: $settings.draftAppURL)
            urlField("Agent Gateway URL", placeholder: "https://cluster-agent.personastack.ai", text: $settings.draftGatewayURL)
            urlField("MCP URL", placeholder: "https://mcp.personastack.ai", text: $settings.draftMCPURL)

            if let message = settings.validationMessage ?? settings.errorMessage {
                Text(message).font(.callout).foregroundStyle(.red)
            }

            HStack {
                Button("Reset to Production") { load(.production) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(settings.isApplying ? "Applying…" : "Save and Reload") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(settings.isApplying)
            }
        }
        .padding(24)
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            settings.reloadDraft()
        }
    }

    private func urlField(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .textContentType(.URL)
                .autocorrectionDisabled()
        }
    }

    private func load(_ configuration: DesktopEnvironmentConfiguration) {
        settings.draftAppURL = configuration.appURL.absoluteString
        settings.draftGatewayURL = configuration.gatewayURL.absoluteString
        settings.draftMCPURL = configuration.mcpURL.absoluteString
        settings.errorMessage = nil
        settings.validationMessage = nil
    }

    private func save() {
        do {
            let next = try DesktopEnvironmentConfiguration(
                appURL: settings.draftAppURL,
                gatewayURL: settings.draftGatewayURL,
                mcpURL: settings.draftMCPURL
            )
            settings.validationMessage = nil
            Task { if await settings.apply(next) { dismiss() } }
        } catch {
            settings.validationMessage = error.localizedDescription
        }
    }
}

struct DesktopServerSettingsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            DesktopConcernNotificationsMenuItem()
            Button("Server Settings…") {
                MainWebViewHost.showServerSettingsWindow { openWindow(id: "desktop-server-settings") }
            }
                .keyboardShortcut("u", modifiers: [.command, .option, .shift])
        }
    }
}

struct DesktopServerSettingsMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Server Settings…") {
            MainWebViewHost.showServerSettingsWindow { openWindow(id: "desktop-server-settings") }
        }
    }
}

/// Shared by the app menu and the menu-bar Settings menu.
struct DesktopConcernNotificationsMenuItem: View {
    @AppStorage(DesktopConcernNotificationSettings.enabledKey) private var enabled = true

    var body: some View {
        Toggle("Concern Notifications", isOn: $enabled)
    }
}
