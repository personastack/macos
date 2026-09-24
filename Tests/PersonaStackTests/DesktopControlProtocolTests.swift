import Foundation
import PersonaStackCore
import Testing

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
