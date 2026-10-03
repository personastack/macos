import AppKit
import Combine
import PersonaStackCore
import ServiceManagement
import SwiftUI

private final class DesktopControlMenuStatus: ObservableObject {
    @Published var revision = 0
    @Published var isRepairing = false
    private var refresh: AnyCancellable?

    init() {
        // Menu tracking must not rebuild SwiftUI's native submenu hierarchy.
        refresh = Timer.publish(every: 2, on: .main, in: .default)
            .autoconnect()
            .sink { [weak self] _ in self?.revision &+= 1 }
    }
}

struct DesktopControlMenu: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var serverSettings = DesktopEnvironmentSettings.shared
    @AppStorage("desktopControlLoginItemError") private var loginItemError = ""
    @AppStorage("desktopControlRepairError") private var repairError = ""
    @StateObject private var status = DesktopControlMenuStatus()
    @ObservedObject private var presentation = DesktopControlPresentationStore.shared

    private var relayEnabled: Bool {
        get { serverSettings.hasTrustedConfiguration && UserDefaults.standard.bool(forKey: preferenceKey(DesktopControlPreferenceKeys.relayEnabled)) }
        nonmutating set {
            guard serverSettings.hasTrustedConfiguration else { return }
            UserDefaults.standard.set(newValue, forKey: preferenceKey(DesktopControlPreferenceKeys.relayEnabled))
        }
    }

    private var relayPaused: Bool {
        get {
            serverSettings.hasTrustedConfiguration
                && (UserDefaults.standard.bool(forKey: preferenceKey(DesktopControlPreferenceKeys.relayPaused))
                    || DesktopControlRuntime.shared.paused)
        }
        nonmutating set {
            guard serverSettings.hasTrustedConfiguration else { return }
            UserDefaults.standard.set(newValue, forKey: preferenceKey(DesktopControlPreferenceKeys.relayPaused))
        }
    }

    private var relayError: String {
        get { serverSettings.hasTrustedConfiguration ? UserDefaults.standard.string(forKey: preferenceKey(DesktopControlPreferenceKeys.relayError)) ?? "" : "" }
        nonmutating set {
            guard serverSettings.hasTrustedConfiguration else { return }
            UserDefaults.standard.set(newValue, forKey: preferenceKey(DesktopControlPreferenceKeys.relayError))
        }
    }

    var body: some View {
        Button("Open PersonaStack") {
            MainWebViewHost.showMainWindow {
                openWindow(id: "personastack-main")
            }
        }
        Divider()
        connectionStatus
        if let activity = presentation.snapshot.activity {
            Text(activity.ownerLabel)
            Text("\(activity.operation?.rawValue ?? "Control session") · \(activity.elapsedLabel)")
                .font(.caption)
        }
        if !loginItemError.isEmpty {
            Text(loginItemError)
                .font(.caption)
                .foregroundStyle(.red)
        }
        if let action = relayAction {
            Button(action.title) {
                toggleRelay()
            }
            .disabled(!action.isEnabled)
        }
        Menu("Desktop Control") {
            desktopControlActions
        }
        Divider()
        Menu("Settings") {
            DesktopConcernNotificationsMenuItem()
            DesktopServerSettingsMenuItem()
            Button("Launch at Login") {
                registerLoginItem()
            }
            .disabled(DesktopLoginItemRegistration.loginStatus() == .enabled)
            Divider()
            DesktopAutomaticUpdatesMenuItem()
        }
        Menu("Updates") {
            DesktopUpdatesMenuSection()
        }
        Divider()
        Button("Quit PersonaStack") {
            NSApp.terminate(nil)
        }
    }

    private var connectionStatus: some View {
        Label(relayStatus, systemImage: presentation.snapshot.symbol)
            .foregroundStyle(statusColor)
            .onReceive(status.objectWillChange) { _ in
                DesktopLoginItemRegistration.clearResolvedApprovalError()
                let savedRepairError = UserDefaults.standard.string(forKey: "desktopControlRepairError") ?? ""
                if repairError != savedRepairError { repairError = savedRepairError }
                let savedLoginItemError = UserDefaults.standard.string(forKey: "desktopControlLoginItemError") ?? ""
                if loginItemError != savedLoginItemError { loginItemError = savedLoginItemError }
            }
    }

    private var relayAction: DesktopMenuRelayAction? {
        DesktopMenuRelayAction(relayEnabled: relayEnabled, relayPaused: relayPaused,
                               hasError: !relayError.isEmpty,
                               hasTrustedConfiguration: serverSettings.hasTrustedConfiguration,
                               environmentSwitchPending: DesktopControlRuntime.shared.hasPendingEnvironmentSwitch,
                               activelyControlling: presentation.snapshot.activity != nil,
                               cleanupPending: presentation.snapshot.cleanupPending)
    }

    @ViewBuilder
    private var desktopControlActions: some View {
        if !relayError.isEmpty {
            Text(relayError)
                .font(.caption)
                .foregroundStyle(.red)
        }
        if !repairError.isEmpty && !DesktopControlRuntime.shared.isCuaReady() {
            Text(repairError)
                .font(.caption)
                .foregroundStyle(.red)
        }
        Button("Permissions and Setup…") {
            DesktopPermissionChecklist.shared.window.presentForRepair()
        }
        Button("Diagnostics…") {
            DesktopControlDiagnosticsWindow.shared.present()
        }
        if relayEnabled || DesktopControlRuntime.shared.hasPendingEnvironmentSwitch {
            Button(status.isRepairing ? "Repairing Desktop Control…" : "Repair Desktop Control") {
                Task { await repairCua() }
            }
            .disabled(status.isRepairing || DesktopControlRuntime.shared.isDisconnecting)
            Divider()
            Button("Disconnect This Mac…", role: .destructive) {
                confirmDisconnect()
            }
        }
    }

    private func preferenceKey(_ key: (DesktopEnvironmentConfiguration) -> String) -> String {
        key(serverSettings.configuration)
    }

    private var relayStatus: String {
        _ = status.revision
        if !serverSettings.hasTrustedConfiguration { return "Set all three server URLs to enable Desktop Control" }
        if DesktopControlRuntime.shared.hasPendingEnvironmentSwitch { return "Server change incomplete. Retry Server Settings, repair, or disconnect." }
        if status.isRepairing { return "Repairing Cua Service…" }
        return presentation.snapshot.message
    }

    private var statusColor: Color {
        switch presentation.snapshot.state {
        case .ready: .green
        case .controlling: .blue
        case .needsAttention: .orange
        default: .secondary
        }
    }

    @MainActor
    private func toggleRelay() {
        loginItemError = ""
        let runtime = DesktopControlRuntime.shared
        if runtime.presentationSnapshot().activity != nil || (relayEnabled && !relayPaused && relayError.isEmpty) {
            guard let generation = runtime.beginPause() else { return }
            relayPaused = true
            presentation.refresh()
            Task {
                await runtime.pause(generation: generation)
                guard runtime.isCurrentLifecycle(generation) else { return }
                relayPaused = runtime.paused
                presentation.refresh()
            }
            return
        }
        Task { await resumeRelay() }
    }

    @MainActor
    private func resumeRelay() async {
        let runtime = DesktopControlRuntime.shared
        var generation: UUID?
        relayError = ""
        do {
            let current = try runtime.beginResume()
            generation = current
            try await runtime.authorizeSavedInstallation(generation: current)
            try await runtime.resume(generation: current)
            guard runtime.isCurrentLifecycle(current) else { return }
            guard runtime.hasActiveInstallation else {
                relayEnabled = false
                relayPaused = false
                relayError = "No active Desktop Control configuration remains. Open PersonaStack to add one."
                return
            }
            relayEnabled = true
            relayPaused = false
        } catch is CancellationError {
            return
        } catch {
            guard let generation, runtime.isCurrentLifecycle(generation) else { return }
            relayError = error.localizedDescription
            relayEnabled = runtime.hasActiveInstallation
            relayPaused = runtime.paused
        }
    }

    @MainActor
    private func repairCua() async {
        guard !status.isRepairing else { return }
        status.isRepairing = true
        defer { status.isRepairing = false }
        loginItemError = ""
        repairError = ""
        let runtime = DesktopControlRuntime.shared
        var generation: UUID?
        do {
            let current = try runtime.beginRepair()
            generation = current
            try await runtime.repair(generation: current)
            guard runtime.isCurrentLifecycle(current) else { return }
            relayError = ""
        } catch is CancellationError {
            return
        } catch {
            guard let generation, runtime.isCurrentLifecycle(generation) else { return }
            repairError = "Cua service could not be repaired: \(error.localizedDescription)"
        }
        guard let generation, runtime.isCurrentLifecycle(generation) else { return }
        relayPaused = runtime.paused
    }

    @MainActor
    private func registerLoginItem() {
        loginItemError = ""
        do {
            let status = try DesktopLoginItemRegistration.registerAndMigrateLegacy()
            if status != .enabled {
                loginItemError = status == .requiresApproval
                    ? DesktopLoginItemRegistration.approvalMessage
                    : DesktopLoginItemRegistration.unconfirmedMessage
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            loginItemError = error.localizedDescription
        }
    }

    @MainActor
    private func confirmDisconnect() {
        let alert = NSAlert()
        alert.messageText = "Disconnect this Mac from PersonaStack?"
        alert.informativeText = "This revokes the desktop connection for every workspace. It does not uninstall Cua. Managed commands are closed where possible, but detached programs may continue."
        alert.addButton(withTitle: "Disconnect Desktop Control")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await disconnectRelay() }
    }

    @MainActor
    private func disconnectRelay() async {
        loginItemError = ""
        relayError = ""
        let runtime = DesktopControlRuntime.shared
        var generation: UUID?
        do {
            let current = try runtime.beginDisconnect()
            generation = current
            try await runtime.disconnect(generation: current)
            guard runtime.isCurrentLifecycle(current) else { return }
            relayEnabled = false
            relayPaused = false
        } catch is CancellationError {
            return
        } catch {
            guard let generation, runtime.isCurrentLifecycle(generation) else { return }
            if runtime.hasActiveInstallation {
                relayEnabled = true
                relayPaused = true
            } else {
                relayEnabled = false
                relayPaused = false
            }
            loginItemError = error.localizedDescription
        }
    }

}

/// Presentation of the existing relay action, shared by its single menu button.
struct DesktopMenuRelayAction: Equatable {
    let title: String
    let isEnabled: Bool

    init?(relayEnabled: Bool, relayPaused: Bool, hasError: Bool,
          hasTrustedConfiguration: Bool, environmentSwitchPending: Bool,
          activelyControlling: Bool = false, cleanupPending: Bool = false) {
        guard relayEnabled || !environmentSwitchPending || activelyControlling else { return nil }
        if cleanupPending { title = "Stopping Control…" }
        else if activelyControlling { title = "Stop Control" }
        else if hasError { title = "Retry Remote Control" }
        else if !relayEnabled { title = "Start Desktop Control" }
        else { title = relayPaused ? "Resume Remote Control" : "Pause Remote Control" }
        isEnabled = !cleanupPending && (activelyControlling
            || (!environmentSwitchPending && (relayEnabled || hasTrustedConfiguration)))
    }
}
