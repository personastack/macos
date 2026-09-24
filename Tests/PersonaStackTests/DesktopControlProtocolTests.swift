import Foundation
import PersonaStackCore
import Testing
@testable import PersonaStack

@Test func desktopControlProtocolUsesGoCompatibleFramesAndFractionalTimestamps() throws {
    let raw = Data(#"{"version":1,"type":"command","request_id":"r-1","target":{"installation_id":"i-1","workspace_id":"w-1","config_id":"c-1","persona_id":"p-1","run_id":"run-1","generation":2},"operation":"desktop_control_observe","arguments":{"mode":"screenshot"},"deadline_at":"2026-09-23T18:30:00.123456Z"}"#.utf8)
    let frame = try DesktopControlFrameCodec.decode(raw)
    #expect(frame.type == "command")
    #expect(frame.requestID == "r-1")
    #expect(frame.target?.workspaceID == "w-1")
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
