import Foundation
import Testing
@testable import PersonaStack

@Test func desktopControlSetupCommandsAreStrictAndVersioned() throws {
    let ticket = String(repeating: "a", count: 43)
    #expect(try DesktopControlSetupCommand.parse(["version": "1", "action": "sync", "scope": "session-1"] as [String: Any]) == .sync(scope: "session-1"))
    #expect(try DesktopControlSetupCommand.parse(["version": "1", "action": "state", "scope": "session-1"] as [String: Any]) == .state(scope: "session-1"))
    #expect(try DesktopControlSetupCommand.parse(["version": "1", "action": "state", "scope": ""] as [String: Any]) == .state(scope: ""))
    #expect(try DesktopControlSetupCommand.parse(["version": "1", "action": "prepare", "scope": "session-1", "enrollment_ticket": ticket] as [String: Any]) == .prepare(scope: "session-1", enrollmentTicket: ticket))
    #expect(try DesktopControlSetupCommand.parse(["version": "1", "action": "permissions", "scope": "session-1", "phase": "open"] as [String: Any]) == .permissions(scope: "session-1", phase: .open, message: nil))
    #expect(try DesktopControlSetupCommand.parse(["version": "1", "action": "permissions", "scope": "session-1", "phase": "completed"] as [String: Any]) == .permissions(scope: "session-1", phase: .completed, message: nil))
    #expect(try DesktopControlSetupCommand.parse(["version": "1", "action": "permissions", "scope": "session-1", "phase": "failed", "message": "Connection unavailable"] as [String: Any]) == .permissions(scope: "session-1", phase: .failed, message: "Connection unavailable"))
    #expect(try DesktopControlSetupCommand.parse(["version": "1", "action": "permissions", "scope": "session-1", "phase": "failed"] as [String: Any]) == .permissions(scope: "session-1", phase: .failed, message: nil))
}

@Test func desktopControlSetupRejectsUnknownFieldsAndUnsafeSetupValues() {
    let cases: [[String: Any]] = [
        ["version": "2", "action": "state", "scope": "session-1"],
        ["version": "1", "action": "state", "scope": "session-1", "installation_id": "attacker-choice"],
        ["version": "1", "action": "prepare", "scope": "session-1", "enrollment_ticket": String(repeating: "a", count: 42)],
        ["version": "1", "action": "prepare", "scope": "session-1", "enrollment_ticket": String(repeating: "a", count: 42) + ";"],
        ["version": "1", "action": "prepare", "scope": "session-1"],
        ["version": "1", "action": "run_command", "scope": "session-1", "command": "open Calculator"],
        ["version": "1", "action": "state", "scope": String(repeating: "a", count: 513)],
        ["version": "1", "action": "permissions", "scope": "session-1"],
        ["version": "1", "action": "permissions", "scope": "", "phase": "open"],
        ["version": "1", "action": "permissions", "scope": "session-1", "phase": "ready"],
        ["version": "1", "action": "permissions", "scope": "session-1", "phase": 1],
        ["version": "1", "action": "permissions", "scope": "session-1", "phase": "open", "message": "Not allowed"],
        ["version": "1", "action": "permissions", "scope": "session-1", "phase": "completed", "message": "Not allowed"],
        ["version": "1", "action": "permissions", "scope": "session-1", "phase": "failed", "message": 1],
        ["version": "1", "action": "permissions", "scope": "session-1", "phase": "failed", "message": String(repeating: "a", count: 513)],
        ["version": "1", "action": "permissions", "scope": "session-1", "phase": "failed", "message": String(repeating: "é", count: 257)],
        ["version": "1", "action": "permissions", "scope": String(repeating: "é", count: 257), "phase": "open"],
        ["version": "1", "action": "permissions", "scope": "session-1", "phase": "open", "installation_id": "untrusted"],
        ["version": "1", "action": "permissions", "scope": "session-1", "phase": "open", "enrollment_ticket": String(repeating: "a", count: 43)],
    ]
    for body in cases {
        #expect(throws: DesktopControlEnrollmentError.invalidRequest) {
            try DesktopControlSetupCommand.parse(body)
        }
    }
}

@Test func desktopControlPermissionMessagesUseUTF8ByteLimitsAndOnlyFailedHasMessage() throws {
    let scope = String(repeating: "é", count: 256)
    let message = String(repeating: "é", count: 256)
    #expect(try DesktopControlSetupCommand.parse(["version": "1", "action": "permissions", "scope": scope, "phase": "failed", "message": message] as [String: Any]) == .permissions(scope: scope, phase: .failed, message: message))
}

@Test func desktopControlSetupScopeFencesPendingWorkAfterWorkspaceChange() throws {
    var scope = DesktopControlSetupScope()
    scope.synchronize("workspace-a-session")
    let pendingGeneration = scope.generation
    try scope.require("workspace-a-session", generation: pendingGeneration)

    scope.synchronize("workspace-b-session")
    #expect(throws: DesktopControlEnrollmentError.invalidRequest) {
        try scope.require("workspace-a-session", generation: pendingGeneration)
    }
    try scope.require("workspace-b-session", generation: scope.generation)
}
