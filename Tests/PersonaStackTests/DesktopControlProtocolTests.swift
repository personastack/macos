import Foundation
import PersonaStackCore
import Testing
@testable import PersonaStack

@Test func desktopControlProtocolUsesGoCompatibleFramesAndFractionalTimestamps() throws {
    let raw = Data(#"{"version":1,"type":"command","request_id":"r-1","target":{"installation_id":"i-1","workspace_id":"w-1","config_id":"c-1","persona_id":"p-1","run_id":"run-1","generation":2,"owner_display":{"persona_name":"Researcher","workspace_name":"Lab"}},"operation":"desktop_control_observe","arguments":{"mode":"screenshot"},"deadline_at":"2026-09-23T18:30:00.123456Z"}"#.utf8)
    let frame = try DesktopControlFrameCodec.decode(raw)
    #expect(frame.type == "command")
    #expect(frame.requestID == "r-1")
    #expect(frame.target?.workspaceID == "w-1")
    #expect(frame.target?.ownerDisplay?.personaName == "Researcher")
    #expect(frame.target?.ownerDisplay?.workspaceName == "Lab")
    #expect(frame.arguments == .object(["mode": .string("screenshot")]))

    let encoded = try DesktopControlFrameCodec.encode(DesktopControlFrame(
        type: "heartbeat",
        lastHeartbeat: ISO8601DateFormatter().date(from: "2026-09-23T18:30:00Z"),
        readiness: "paused"
    ))
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["last_heartbeat"] as? String != nil)
    #expect(object["readiness"] as? String == "paused")
    #expect(object["lastHeartbeat"] == nil)

    let oldGatewayReady = try DesktopControlFrameCodec.decode(Data(#"{"version":1,"type":"ready"}"#.utf8))
    #expect(oldGatewayReady.diagnosticsSupported == nil)
    let oldCommand = try DesktopControlFrameCodec.decode(Data(#"{"version":1,"type":"command","target":{"installation_id":"i-1","workspace_id":"w-1","config_id":"c-1","persona_id":"p-1","run_id":"run-1","generation":2}}"#.utf8))
    #expect(oldCommand.target?.ownerDisplay == nil)
    let diagnosticHeartbeat = DesktopControlFrame(type: "heartbeat", diagnostics: DesktopControlDiagnostics(
        activeProcesses: 2, openFileHandles: 3, bufferedOutputBytes: 4096, outputGapsTotal: 1
    ))
    let diagnosticObject = try #require(JSONSerialization.jsonObject(with: DesktopControlFrameCodec.encode(diagnosticHeartbeat)) as? [String: Any])
    let diagnosticPayload = try #require(diagnosticObject["diagnostics"] as? [String: Any])
    #expect(diagnosticPayload["active_processes"] as? Int == 2)
    #expect(diagnosticPayload["open_file_handles"] as? Int == 3)
    #expect(diagnosticPayload["buffered_output_bytes"] as? Int == 4096)
    #expect(diagnosticPayload["output_gaps_total"] as? Int == 1)
}

@Test func desktopControlOwnerDisplayDropsMalformedOrOversizedLabels() throws {
    let target: [String: Any] = [
        "installation_id": "i-1", "workspace_id": "w-1", "config_id": "c-1",
        "persona_id": "p-1", "run_id": "run-1", "generation": 2,
    ]
    let cases: [[String: Any]] = [
        ["persona_name": ["invalid"], "workspace_name": "Lab"],
        ["persona_name": String(repeating: "x", count: 129), "workspace_name": "Lab"],
        ["persona_name": "Researcher", "workspace_name": "Lab\nTeam"],
        ["persona_name": "\nResearcher", "workspace_name": "Lab"],
        ["persona_name": "Researcher\n", "workspace_name": "Lab"],
        ["persona_name": String(repeating: " ", count: 128) + "Name", "workspace_name": "Lab"],
        ["persona_name": "\u{202E}Researcher", "workspace_name": "Lab"],
    ]
    for ownerDisplay in cases {
        var commandTarget = target
        commandTarget["owner_display"] = ownerDisplay
        let bytes = try JSONSerialization.data(withJSONObject: ["version": 1, "type": "command", "target": commandTarget])
        let frame = try DesktopControlFrameCodec.decode(bytes)
        #expect(frame.target != nil)
        #expect(frame.target?.ownerDisplay == nil)
    }
}

@Test func desktopControlGatewayRejectsInvalidOrStaleRelayCommands() throws {
    let target = DesktopControlTarget(installationID: "install-1", workspaceID: "workspace-1",
                                      configID: "config-1", personaID: "persona-1", runID: "run-1", generation: 1)
    let valid = DesktopControlFrame(type: "command", requestID: "request-1", target: target,
                                    operation: "desktop_control_status", arguments: .object([:]),
                                    deadlineAt: Date().addingTimeInterval(30))
    #expect(DesktopControlGatewayConnection.validCommand(valid, installationID: "install-1"))
    #expect(!DesktopControlGatewayConnection.validCommand(valid, installationID: "other-install"))

    let expired = DesktopControlFrame(type: "command", requestID: "request-1", target: target,
                                      operation: "desktop_control_status", arguments: .object([:]),
                                      deadlineAt: Date(timeIntervalSince1970: 1))
    #expect(!DesktopControlGatewayConnection.validCommand(expired, installationID: "install-1"))
    let incomplete = DesktopControlFrame(type: "command", requestID: "request-1", target: target,
                                         operation: "desktop_control_status", arguments: nil,
                                         deadlineAt: Date().addingTimeInterval(30))
    #expect(!DesktopControlGatewayConnection.validCommand(incomplete, installationID: "install-1"))

    let revokeTarget = DesktopControlTarget(installationID: "install-1", workspaceID: "workspace-1",
                                            configID: "config-1", personaID: "", runID: "", generation: 0,
                                            configVersion: 2)
    let revoke = DesktopControlFrame(type: "command", requestID: "revoke-1", target: revokeTarget,
                                     operation: "desktop_control_revoke_config", arguments: .object([:]),
                                     deadlineAt: Date().addingTimeInterval(30))
    #expect(DesktopControlGatewayConnection.validCommand(revoke, installationID: "install-1"))
    let unversionedRevoke = DesktopControlTarget(installationID: "install-1", workspaceID: "workspace-1",
                                                 configID: "config-1", personaID: "", runID: "", generation: 0)
    let invalidRevoke = DesktopControlFrame(type: "command", requestID: "revoke-2", target: unversionedRevoke,
                                            operation: "desktop_control_revoke_config", arguments: .object([:]),
                                            deadlineAt: Date().addingTimeInterval(30))
    #expect(!DesktopControlGatewayConnection.validCommand(invalidRevoke, installationID: "install-1"))
}

@Test func desktopControlGatewayHandshakeRequiresACompatibleProtocol() {
    #expect(DesktopControlGatewayConnection.handshakeError(for: DesktopControlFrame(type: "ready")) == nil)
    #expect(DesktopControlGatewayConnection.handshakeError(for: DesktopControlFrame(version: 2, type: "ready")) == .upgradeRequired)
    #expect(DesktopControlGatewayConnection.handshakeError(for: DesktopControlFrame(
        type: "failure", errorCode: "upgrade_required"
    )) == .upgradeRequired)
    #expect(DesktopControlGatewayConnection.handshakeError(for: DesktopControlFrame(type: "failure")) == .rejected)
}

@Test func desktopControlGatewayReservesOneCommandSlotForConfigRevocation() {
    #expect(DesktopControlGatewayConnection.hasCapacity(for: "desktop_control_status", activeCount: 30))
    #expect(!DesktopControlGatewayConnection.hasCapacity(for: "desktop_control_status", activeCount: 31))
    #expect(DesktopControlGatewayConnection.hasCapacity(for: "desktop_control_revoke_config", activeCount: 31))
    #expect(!DesktopControlGatewayConnection.hasCapacity(for: "desktop_control_revoke_config", activeCount: 32))
    #expect(!DesktopControlGatewayConnection.hasCapacity(for: "desktop_control_revoke_config", activeCount: -1))
}

@Test func configRevocationStopsIdleRelayOnlyAfterConfirmedCleanup() {
    let revoke = DesktopControlFrame(type: "command", requestID: "revoke-1", operation: "desktop_control_revoke_config")
    let success = DesktopControlFrame(type: "result", requestID: "revoke-1", result: .object(["revoked": .bool(true)]))
    let failed = DesktopControlFrame(type: "failure", requestID: "revoke-1", errorCode: "desktop_control_revoke_incomplete")
    let malformed = DesktopControlFrame(type: "result", requestID: "revoke-1", result: .object(["revoked": .bool(false)]))
    let ordinary = DesktopControlFrame(type: "command", requestID: "ordinary-1", operation: "desktop_control_status")

    #expect(DesktopControlGatewayConnection.shouldReconcileAfterConfigRevocation(revoke, response: success))
    #expect(!DesktopControlGatewayConnection.shouldReconcileAfterConfigRevocation(revoke, response: failed))
    #expect(!DesktopControlGatewayConnection.shouldReconcileAfterConfigRevocation(revoke, response: malformed))
    #expect(!DesktopControlGatewayConnection.shouldReconcileAfterConfigRevocation(ordinary, response: success))
}

@Test func desktopControlProtocolRejectsMalformedFramesAndTimestamps() {
    let cases = [
        Data("{".utf8),
        Data(#"{"version":1,"type":"command","deadline_at":"not-a-timestamp"}"#.utf8),
    ]
    for data in cases {
        #expect(throws: (any Error).self) {
            try DesktopControlFrameCodec.decode(data)
        }
    }
}
