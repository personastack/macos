import AppKit
import Foundation
import PersonaStackCore

@MainActor
final class AgentBridgeMigrationCoordinator {
    enum WorkChoice { case wait, stop, cancel }
    struct Dependencies {
        var verifyReplacement: @MainActor () async throws -> Void = { throw AgentBridgeFailure.migrationRequired }
        var readState: @MainActor () async throws -> AgentBridgeMigrationState = { throw AgentBridgeFailure.migrationRequired }
        var stopAssignedRun: @MainActor () async throws -> Void = { throw AgentBridgeFailure.migrationRequired }
        var confirmWork: @MainActor () -> WorkChoice = { .cancel }
        var confirmCutover: @MainActor () -> Bool = { false }
        var setPause: @MainActor (Bool, Int) async throws -> Int
        var capture: @MainActor (Bool, Int) async throws -> AgentBridgeMigrationCapture = { _, _ in throw AgentBridgeFailure.migrationRequired }
        var stopSupervisor: @MainActor (String) async throws -> Void = { _ in throw AgentBridgeFailure.migrationRequired }
        var cancelCapture: @MainActor (AgentBridgeMigrationCapture) async throws -> Void = { _ in throw AgentBridgeFailure.migrationRequired }
        var revoke: @MainActor () async throws -> Void = { throw AgentBridgeFailure.migrationRequired }
        var validateScope: @MainActor () async throws -> Void
        var readiness: @MainActor (AgentBridgeBindingKey) async throws -> Void
        var wait: @MainActor () async throws -> Void = { try await Task.sleep(for: .milliseconds(250)) }
    }
    struct Cutover {
        let capture: AgentBridgeMigrationCapture
        let wasPaused: Bool
        let pauseVersion: Int
    }
    private let dependencies: Dependencies
    private(set) var revoked = false
    private(set) var preparedCutover: Cutover?
    private(set) var revocationVerified = false
    init(_ dependencies: Dependencies) { self.dependencies = dependencies }

    func begin() async throws -> Cutover {
        guard !revoked else { throw AgentBridgeFailure.scopeChanged }
        try await dependencies.verifyReplacement()
        let original = try await dependencies.readState()
        if !original.laneIdle {
            switch dependencies.confirmWork() {
            case .cancel: throw AgentBridgeFailure.busy
            case .stop: try await dependencies.validateScope(); try await dependencies.stopAssignedRun()
            case .wait: break
            }
            try await waitForIdle()
        }
        try await dependencies.validateScope()
        guard dependencies.confirmCutover() else { throw AgentBridgeFailure.runtimeConflict }
        let beforePause = try await dependencies.readState()
        guard beforePause.userPaused == original.userPaused, beforePause.pauseVersion == original.pauseVersion else {
            throw AgentBridgeFailure.scopeChanged
        }
        var pauseVersion = original.pauseVersion
        var pauseChanged = false
        var capturedBeforeRevoke: AgentBridgeMigrationCapture?
        do {
            try await dependencies.validateScope()
            if !original.userPaused {
                pauseVersion = try await dependencies.setPause(true, pauseVersion)
                pauseChanged = true
            }
            try await waitForIdle()
            try await dependencies.validateScope()
            let capture = try await dependencies.capture(original.userPaused, pauseVersion)
            guard capture.legacyServiceScope == "user_launch_agent" else { throw AgentBridgeFailure.migrationRequired }
            capturedBeforeRevoke = capture
            // The caller has proven the lane is idle after the consented Pause.
            try await dependencies.stopSupervisor(capture.legacyServiceScope)
            try await dependencies.validateScope()
            // From the first revoke attempt onward rollback never resumes old credentials.
            let cutover = Cutover(capture: capture, wasPaused: original.userPaused, pauseVersion: pauseVersion)
            preparedCutover = cutover
            revoked = true
            try await dependencies.revoke()
            revocationVerified = true
            return cutover
        } catch {
            if !revoked, let capture = capturedBeforeRevoke {
                try? await dependencies.cancelCapture(capture)
            }
            if pauseChanged && !revoked {
                do {
                    try await dependencies.validateScope()
                    _ = try await dependencies.setPause(false, pauseVersion)
                } catch { /* Changed authority must never restore a different user's pause. */ }
            }
            throw error
        }
    }

    /// Called only after authenticated absence and exact helper-capture readback.
    func recover(_ capture: AgentBridgeMigrationCapture, wasPaused: Bool, pauseVersion: Int) throws -> Cutover {
        guard capture.legacyServiceScope == "user_launch_agent", capture.wasPaused == wasPaused,
              capture.pauseVersion == pauseVersion, pauseVersion >= 0 else { throw AgentBridgeFailure.scopeChanged }
        let cutover = Cutover(capture: capture, wasPaused: wasPaused, pauseVersion: pauseVersion)
        preparedCutover = cutover
        revoked = true; revocationVerified = true
        return cutover
    }

    func ensureRevoked() async throws {
        guard revoked else { throw AgentBridgeFailure.scopeChanged }
        guard !revocationVerified else { return }
        try await dependencies.validateScope()
        try await dependencies.revoke()
        revocationVerified = true
    }

    func finish(_ cutover: Cutover, binding: AgentBridgeBindingKey) async throws {
        guard revoked, revocationVerified else { throw AgentBridgeFailure.scopeChanged }
        try await dependencies.validateScope()
        try await dependencies.readiness(binding)
        try await dependencies.validateScope()
        guard !cutover.wasPaused else { return }
        _ = try await dependencies.setPause(false, cutover.pauseVersion)
        try await dependencies.validateScope()
    }

    private func waitForIdle() async throws {
        for _ in 0..<120 {
            try await dependencies.validateScope()
            if try await dependencies.readState().laneIdle { return }
            try await dependencies.wait()
        }
        throw AgentBridgeFailure.busy
    }

    static func confirmWork() -> WorkChoice {
        let alert = NSAlert()
        alert.messageText = "This persona has a PersonaStack run in progress."
        alert.informativeText = "Wait for this run to finish, or explicitly stop its PersonaStack run before migration. Unrelated native work is not stopped."
        alert.addButton(withTitle: "Wait for Run")
        alert.addButton(withTitle: "Stop PersonaStack Run")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .wait
        case .alertSecondButtonReturn: return .stop
        default: return .cancel
        }
    }
    static func confirmCutover() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Pause and migrate this persona?"
        alert.informativeText = "Pause can cancel a new PersonaStack assignment that arrives before the cutover. The app will pause this persona, stop its previous background service, revoke the previous connection, and connect the selected profile through Background Agents. The old profile config is backed up. The original pause setting returns only after readiness. If setup fails before completion, use Repair. Send test wake is a separate action."
        alert.addButton(withTitle: "Pause and Migrate")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
