import AppKit
import ServiceManagement
import SwiftUI

struct DesktopControlMenu: View {
    @Environment(\.openWindow) private var openWindow
    @AppStorage("desktopControlRelayEnabled") private var relayEnabled = false
    @AppStorage("desktopControlRelayPaused") private var relayPaused = false
    @AppStorage("desktopControlLoginItemError") private var loginItemError = ""

    var body: some View {
        Text("Desktop Control")
            .font(.headline)
        Label(relayStatus, systemImage: relayEnabled ? "dot.radiowaves.left.and.right" : "pause.circle")
            .foregroundStyle(relayEnabled ? .green : .secondary)
        Divider()
        if relayEnabled {
            Button("Repair Cua Service") {
                Task { await repairCua() }
            }
        }
        if relayEnabled {
            Button(relayPaused ? "Resume Remote Control" : "Pause Remote Control") {
                Task { await toggleRelay() }
            }
            Button("Disconnect this Mac…", role: .destructive) {
                confirmDisconnect()
            }
        } else {
            Button("Start Local Service") {
                Task { await toggleRelay() }
            }
        }
        Button("Launch at Login") {
            registerLoginItem()
        }
        .disabled(SMAppService.mainApp.status == .enabled)
        Divider()
        Button("Open PersonaStack") {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "personastack-main")
        }
        Button("Quit PersonaStack Desktop") {
            NSApp.terminate(nil)
        }
        if !loginItemError.isEmpty {
            Text(loginItemError)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var relayStatus: String {
        if !relayEnabled { return "Relay paused" }
        if relayPaused { return "Remote control paused. Connection active." }
        let runtime = DesktopControlRuntime.shared
        if let message = runtime.sessionRecoveryMessage { return message }
        if !runtime.isCuaReady() { return "Cua service needs attention" }
        return runtime.gatewayConnected ? "Connected to PersonaStack" : "Waiting for PersonaStack connection"
    }

    @MainActor
    private func toggleRelay() async {
        loginItemError = ""
        if relayEnabled && !relayPaused {
            let runtime = DesktopControlRuntime.shared
            guard let generation = runtime.beginPause() else { return }
            await runtime.pause(generation: generation)
            guard runtime.isCurrentLifecycle(generation) else { return }
            relayPaused = runtime.paused
            return
        }
        let runtime = DesktopControlRuntime.shared
        var generation: UUID?
        do {
            let current = try runtime.beginResume()
            generation = current
            try await runtime.resume(generation: current)
            guard runtime.isCurrentLifecycle(current) else { return }
            relayEnabled = true
            relayPaused = false
        } catch is CancellationError {
            return
        } catch {
            guard let generation, runtime.isCurrentLifecycle(generation) else { return }
            loginItemError = "Cua service could not start: \(error.localizedDescription)"
            relayEnabled = runtime.hasActiveInstallation
            relayPaused = runtime.paused
        }
    }

    @MainActor
    private func repairCua() async {
        loginItemError = ""
        let runtime = DesktopControlRuntime.shared
        var generation: UUID?
        do {
            let current = try runtime.beginRepair()
            generation = current
            try await runtime.repair(generation: current)
            guard runtime.isCurrentLifecycle(current) else { return }
        } catch is CancellationError {
            return
        } catch {
            guard let generation, runtime.isCurrentLifecycle(generation) else { return }
            loginItemError = "Cua service could not be repaired: \(error.localizedDescription)"
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
