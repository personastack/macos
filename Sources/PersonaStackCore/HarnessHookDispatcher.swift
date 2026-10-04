import Darwin
import Foundation

/// Each installed connection hook applies the same harness event to its own contributor.
public enum HarnessHookDispatcher {
    public static func dispatch(_ credential: HarnessActivityCredential, event: String, input: HarnessHookInput,
                                store: HarnessHookState, ownerPID: Int32 = getppid(),
                                report: (String, String) async throws -> Bool) async throws -> String? {
        guard credential.routingEnabled else { return nil }
        guard ["UserPromptSubmit", "Stop", "StopFailure", "Interrupt", "SessionEnd"].contains(event) else { throw LocalSessionError.invalidRequest }
        let active = try store.lock(connectionID: credential.connectionID, sessionID: input.sessionID)
        defer { active.unlock() }
        let previous = try active.read()
        if event == "UserPromptSubmit" {
            if let previous, let turnID = input.turnID, previous.turnID == turnID { return nil }
            let turn = HarnessHookTurn(runID: UUID().uuidString.lowercased(), turnID: input.turnID, ownerPID: ownerPID)
            try active.write(turn)
            do {
                guard try await report(turn.runID, "start") else { try active.clear(); return nil }
            } catch { try active.clear(); throw error }
            return turn.runID
        }
        if let previous {
            if let turnID = input.turnID, previous.turnID != nil, previous.turnID != turnID { return nil }
            try active.clear()
            _ = try await report(previous.runID, "stop")
        }
        return nil
    }
}
