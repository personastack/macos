import AppKit
import PersonaStackCore
import SwiftUI

struct AgentBridgeMenu: View {
    @Environment(\.openWindow) private var openWindow
    @AppStorage("agentBridge.backgroundError") private var backgroundError = ""
    @State private var message = ""
    @State private var working = false
    @State private var admissionPaused = false
    @State private var localMessage = "Status not checked."
    @State private var localWorking = false

    var body: some View {
        Group {
            Menu("Agents on This Mac") {
                Text(localMessage).font(.caption)
                Button("Open Settings…") { openLocalSettings() }
                Button("Check Status") { localAction(.status) }.disabled(localWorking)
                Button("Stop") { localAction(.stop) }.disabled(localWorking)
                Button("Resume") { localAction(.resume) }.disabled(localWorking)
                Divider()
                Button("Remove Local Data…") { localAction(.remove) }.disabled(localWorking)
            }
            Menu("Hermes/OpenClaw") {
                Text("Linked profiles keep running after Quit or signing out. Work requires an awake, signed-in Mac.")
                if !message.isEmpty { Text(message).font(.caption) }
                if !backgroundError.isEmpty { Text(backgroundError).font(.caption) }
                Button("Enable Background Agents") { enable() }.disabled(working)
                Button("Stop Background Agents") { stop() }.disabled(working)
                if admissionPaused {
                    Button("Resume Background Agents") { resume() }.disabled(working)
                }
            }
        }
    }

    private enum LocalAction: Equatable { case status, stop, resume, remove }

    private func localAction(_ action: LocalAction) {
        if action == .stop, !confirmLocalStop() { return }
        if action == .remove, !confirmLocalRemoval() { return }
        localWorking = true
        Task { @MainActor in
            defer { localWorking = false }
            do {
                let service = AgentBridgeService.shared
                switch action {
                case .status: break
                case .stop:
                    try await service.stopLocalRuntime()
                    do { localMessage = Self.localStatus(try await service.localRuntimeSnapshot()) }
                    catch { localMessage = "Local runtime stop was confirmed. Current status is unavailable. Check again." }
                    do {
                        try await service.retireIfUnused()
                        DesktopUpdater.shared.restoreAutomaticDownloadsAfterAgentsStopped()
                    } catch {
                        localMessage = Self.localStopCleanupFailure(error as? AgentBridgeFailure)
                    }
                    return
                case .resume:
                    try DesktopUpdater.shared.prepareToEnableBackgroundAgents()
                    try await service.resumeLocalRuntime()
                case .remove:
                    try await service.removeLocalRuntimeData()
                    localMessage = "Local runtime files were removed. Cloud connection settings may still need attention."
                    do {
                        try await service.retireIfUnused()
                        DesktopUpdater.shared.restoreAutomaticDownloadsAfterAgentsStopped()
                    } catch {
                        localMessage = "Local runtime files were removed. Background service status is unavailable. Check again."
                    }
                    return
                }
                let snapshot = try await service.localRuntimeSnapshot()
                localMessage = Self.localStatus(snapshot)
            } catch {
                switch error as? AgentBridgeFailure {
                case .backgroundApprovalRequired:
                    localMessage = "Allow PersonaStack in General → Login Items & Extensions, then check again."
                case .busy, .localRuntimeActive:
                    localMessage = "A local operation is still finishing. Check again."
                default:
                    localMessage = action == .remove
                        ? "Local removal has not been confirmed. Check status before retrying."
                        : "Local runtime status is unavailable. Check again. Existing files are retained."
                }
            }
        }
    }

    static let credentialRecoveryMessage = "Restore access to your login Keychain. Sign out of macOS and sign back in to restart the background helper. Signing out of PersonaStack does not restart it."

    static func localStopCleanupFailure(_ failure: AgentBridgeFailure?) -> String {
        if failure == .credentialUnavailable {
            return "Local runtime stop was confirmed. " + credentialRecoveryMessage
        }
        return "Local runtime stop was confirmed. Background service cleanup is unconfirmed. Check again."
    }

    static func localStatus(_ snapshot: AgentBridgeLocalRuntimeSnapshot) -> String {
        if snapshot.installerActive { return "A local runtime operation is in progress." }
        if snapshot.hasBlockingReason { return "Local runtime status is unavailable. Check again." }
        if snapshot.safeReason == "local_data_removed" { return "Local runtime files were removed. Start a new setup to run agents on this Mac." }
        if snapshot.running { return "Local runtime is running. Agent status is available in settings." }
        if snapshot.installed { return "Local runtime is stopped. Agent files are retained." }
        return "Local runtime is not installed."
    }

    private func confirmLocalStop() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Stop agents on this Mac?"
        alert.informativeText = "This stops the local runtime and interrupts its active work. Agent files are retained. Hermes/OpenClaw connections keep their current state."
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmLocalRemoval() -> Bool {
        let alert = LocalClusterRemovalConfirmation.makeAlert(
            messageText: "Remove local agent files?",
            informativeText: "This stops the managed runtime and permanently removes its local agent files. This cannot be undone. Cloud connections may still need attention in Settings. Hermes/OpenClaw files are unchanged.",
            alertStyle: .warning)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func openLocalSettings() {
        MainWebViewHost.shared.openDesktopFlow(path: "/user/kubernetes/clusters", query: [:])
        MainWebViewHost.showMainWindow { openWindow(id: "personastack-main") }
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
                message = "Hermes/OpenClaw background agents stopped. Native runtimes remain installed."
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
                try await AgentBridgeService.shared.ensureEnabled()
                try await AgentBridgeService.shared.resume()
                admissionPaused = false
                message = "Background agents resumed."
            } catch { message = explanation(error) }
        }
    }
    private func explanation(_ error: any Error) -> String {
        switch error as? AgentBridgeFailure {
        case .busy: "Finish or Stop assigned persona work in PersonaStack. Retry Stop or Resume Background Agents. If an app update is staged, finish the update first."
        case .localRuntimeActive: "Stop Agents on This Mac before replacing the background helper."
        case .backgroundApprovalRequired: "Allow PersonaStack in General → Login Items & Extensions, then retry."
        case .credentialUnavailable: Self.credentialRecoveryMessage
        default: "Background agents are unavailable. Try Enable Background Agents again."
        }
    }
}
