import Foundation
import Testing
@testable import PersonaStack

@Test func desktopControlSetupCommandsAreStrictAndVersioned() throws {
    let ticket = String(repeating: "a", count: 43)
    #expect(try DesktopControlSetupCommand.parse(["version": "1", "action": "sync", "scope": "session-1"] as [String: Any]) == .sync(scope: "session-1"))
    #expect(try DesktopControlSetupCommand.parse(["version": "1", "action": "state", "scope": "session-1"] as [String: Any]) == .state(scope: "session-1"))
    #expect(try DesktopControlSetupCommand.parse(["version": "1", "action": "prepare", "scope": "session-1", "enrollment_ticket": ticket] as [String: Any]) == .prepare(scope: "session-1", enrollmentTicket: ticket))
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
    ]
    for body in cases {
        #expect(throws: DesktopControlEnrollmentError.invalidRequest) {
            try DesktopControlSetupCommand.parse(body)
        }
    }
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
