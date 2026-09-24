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
        if !runtime.isCuaReady() { return "Cua service needs attention" }
        return runtime.gatewayConnected ? "Connected to PersonaStack" : "Waiting for PersonaStack connection"
    }

    @MainActor
    private func toggleRelay() async {
        loginItemError = ""
        if relayEnabled && !relayPaused {
            await DesktopControlRuntime.shared.pause()
            relayPaused = true
            return
        }
        do {
            try await DesktopControlRuntime.shared.resume()
            relayEnabled = true
            relayPaused = false
        } catch {
            loginItemError = "Cua service could not start: \(error.localizedDescription)"
            relayEnabled = false
        }
    }

    @MainActor
    private func repairCua() async {
        loginItemError = ""
        do {
            try await DesktopControlRuntime.shared.repair()
            relayPaused = false
        } catch {
            loginItemError = "Cua service could not be repaired: \(error.localizedDescription)"
        }
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
        do {
            try await DesktopControlRuntime.shared.disconnect()
            relayEnabled = false
            relayPaused = false
        } catch {
            if DesktopControlRuntime.shared.gatewayConnected {
                relayPaused = true
            } else {
                relayEnabled = false
                relayPaused = false
            }
            loginItemError = error.localizedDescription
        }
    }
}
