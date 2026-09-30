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
        refresh = Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.revision &+= 1 }
    }
}

struct DesktopControlMenu: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var serverSettings = DesktopEnvironmentSettings.shared
    @AppStorage("desktopControlLoginItemError") private var loginItemError = ""
    @AppStorage("desktopControlRepairError") private var repairError = ""
    @ObservedObject private var status = DesktopControlMenuStatus()

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
        Text("Desktop Control")
            .font(.headline)
        Label(relayStatus, systemImage: relayEnabled ? "dot.radiowaves.left.and.right" : "pause.circle")
            .foregroundStyle(relayEnabled ? .green : .secondary)
            .onReceive(status.objectWillChange) { _ in
                DesktopLoginItemRegistration.clearResolvedApprovalError()
                let savedRepairError = UserDefaults.standard.string(forKey: "desktopControlRepairError") ?? ""
                if repairError != savedRepairError { repairError = savedRepairError }
                let savedLoginItemError = UserDefaults.standard.string(forKey: "desktopControlLoginItemError") ?? ""
                if loginItemError != savedLoginItemError { loginItemError = savedLoginItemError }
            }
        Divider()
        if relayEnabled || DesktopControlRuntime.shared.hasPendingEnvironmentSwitch {
            Button(status.isRepairing ? "Repairing Cua Service…" : "Repair Cua Service") {
                Task { await repairCua() }
            }
            .disabled(status.isRepairing || DesktopControlRuntime.shared.isDisconnecting)
        }
        if relayEnabled && DesktopControlRuntime.shared.requiresForegroundSessionConfirmation {
            Button("Confirm This Mac Is Unlocked") {
                do {
                    try DesktopControlRuntime.shared.confirmForegroundSession()
                } catch is CancellationError {
                    return
                } catch {
                    loginItemError = error.localizedDescription
                }
            }
        }
        if relayEnabled {
            Button(!relayError.isEmpty ? "Retry Remote Control" : (relayPaused ? "Resume Remote Control" : "Pause Remote Control")) {
                Task { await toggleRelay() }
            }
            .disabled(DesktopControlRuntime.shared.hasPendingEnvironmentSwitch)
        }
        if relayEnabled || DesktopControlRuntime.shared.hasPendingEnvironmentSwitch {
            Button("Disconnect this Mac…", role: .destructive) {
                confirmDisconnect()
            }
        } else {
            Button(relayError.isEmpty ? "Start Local Service" : "Retry Remote Control") {
                Task { await toggleRelay() }
            }.disabled(!serverSettings.hasTrustedConfiguration || DesktopControlRuntime.shared.hasPendingEnvironmentSwitch)
        }
        Button("Launch at Login") {
            registerLoginItem()
        }
        .disabled(SMAppService.mainApp.status == .enabled)
        Divider()
        Button("Open PersonaStack") {
            MainWebViewHost.showMainWindow {
                openWindow(id: "personastack-main")
            }
        }
        DesktopServerSettingsMenuItem()
        Button("Quit PersonaStack Desktop") {
            NSApp.terminate(nil)
        }
        if !loginItemError.isEmpty {
            Text(loginItemError)
                .font(.caption)
                .foregroundStyle(.red)
        }
        if !repairError.isEmpty && !DesktopControlRuntime.shared.isCuaReady() {
            Text(repairError)
                .font(.caption)
                .foregroundStyle(.red)
        }
        if !relayError.isEmpty {
            Text(relayError)
                .font(.caption)
                .foregroundStyle(.red)
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
        if !relayError.isEmpty { return "Desktop Control needs attention" }
        if !relayEnabled { return "Relay paused" }
        if relayPaused { return "Remote control paused. Connection active." }
        let runtime = DesktopControlRuntime.shared
        if let message = runtime.sessionRecoveryMessage { return message }
        if !runtime.isCuaReady() { return "Cua service needs attention" }
        switch runtime.readiness {
        case "permission_required": return "Cua permissions need attention"
        case "cua_unavailable": return "Cua service needs attention"
        case "locked": return "Mac is locked"
        case "paused": return "Remote control paused"
        case "upgrade_required": return "Desktop update required"
        case "ready": break
        default: return "Desktop Control is starting"
        }
        return runtime.gatewayConnected ? "Connected to PersonaStack" : "Waiting for PersonaStack connection"
    }

    @MainActor
    private func toggleRelay() async {
        loginItemError = ""
        if relayEnabled && !relayPaused && relayError.isEmpty {
            let runtime = DesktopControlRuntime.shared
            guard let generation = runtime.beginPause() else { return }
            await runtime.pause(generation: generation)
            guard runtime.isCurrentLifecycle(generation) else { return }
            relayPaused = runtime.paused
            return
        }
        let runtime = DesktopControlRuntime.shared
        var generation: UUID?
        relayError = ""
        do {
            let current = try runtime.beginResume()
            generation = current
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
            try SMAppService.mainApp.register()
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
