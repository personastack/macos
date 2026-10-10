import AppKit
import PersonaStackCore
import ServiceManagement
import SwiftUI

struct AgentBridgeMenu: View {
    @AppStorage("agentBridge.backgroundError") private var backgroundError = ""
    @State private var message = ""
    @State private var working = false
    @State private var admissionPaused = false

    var body: some View {
        Menu("Background Agents") {
            Text("Linked Hermes and OpenClaw profiles keep running after Quit.")
            if !message.isEmpty { Text(message).font(.caption) }
            if !backgroundError.isEmpty { Text(backgroundError).font(.caption) }
            Button("Enable Background Agents") { enable() }.disabled(working)
            Button("Stop Background Agents") { stop() }.disabled(working)
            if admissionPaused {
                Button("Resume Background Agents") { resume() }.disabled(working)
            }
            Button("Review Login Items…") { SMAppService.openSystemSettingsLoginItems() }
        }
    }

    private func enable() {
        working = true
        Task { @MainActor in
            defer { working = false }
            do {
                try DesktopUpdater.shared.prepareToEnableBackgroundAgents()
                try await AgentBridgeService.shared.ensureEnabled()
                try await AgentBridgeService.shared.resume()
                admissionPaused = false
                message = "Background agents enabled."
            } catch { message = explanation(error) }
        }
    }
    private func stop() {
        working = true
        Task { @MainActor in
            defer { working = false }
            do {
                try await AgentBridgeService.shared.stopBackground()
                DesktopUpdater.shared.restoreAutomaticDownloadsAfterAgentsStopped()
                admissionPaused = false
                message = "Background agents stopped. Native runtimes remain installed."
            } catch {
                admissionPaused = error as? AgentBridgeFailure == .busy
                message = explanation(error)
            }
        }
    }
    private func resume() {
        working = true
        Task { @MainActor in
            defer { working = false }
            do {
                try await AgentBridgeService.shared.resume()
                admissionPaused = false
                message = "Background agents resumed."
            } catch { message = explanation(error) }
        }
    }
    private func explanation(_ error: any Error) -> String {
        switch error as? AgentBridgeFailure {
        case .busy: "Finish or Stop assigned persona work in PersonaStack. Retry Stop or Resume Background Agents. If an app update is staged, finish the update first."
        case .migrationIncomplete: "Finish the interrupted profile migration before stopping Background Agents. Select the same persona and profile to resume setup."
        case .backgroundApprovalRequired: "Allow PersonaStack in General → Login Items & Extensions, then retry."
        case .credentialUnavailable: "Unlock or authorize the saved Keychain credential, then retry setup."
        default: "Background agents are unavailable. Review Login Items and retry setup."
        }
    }
}
