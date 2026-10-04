import Foundation
import Testing
import PersonaStackCore
@testable import PersonaStack

struct DesktopBrowserHandshakeValidationTests {
    private var prepared: [String: DesktopControlJSONValue] {
        ["status": .string("ok"), "prepared": .bool(true), "prepared_pid": .number(42),
         "action": .string("attached_existing_profile"),
         "endpoint_ownership": .object(["owner_pid": .number(42), "method": .string("listening_socket_pid")]),
         "attachment": .object(["kind": .string("existing_profile"), "browser": .string("chromium"),
            "capabilities_invalidated": .bool(true), "next_action": .string("get_browser_state")])]
    }
    private func envelope(_ structured: [String: DesktopControlJSONValue], isError: Bool = false) throws -> Data {
        try JSONEncoder().encode(DesktopControlJSONValue.object([
            "result": .object(["structuredContent": .object(structured), "isError": .bool(isError)]),
        ]))
    }

    @Test func exactSelectedExistingAttachmentAndEndedSessionAreAccepted() throws {
        try DesktopBrowserHandshakeValidation.requirePrepared(envelope(prepared), pid: 42)
        try DesktopBrowserHandshakeValidation.requireEnded(envelope(["session": .string("owned"), "active": .bool(false)]), session: "owned")
    }

    @Test(arguments: ["missing", "unprepared", "numeric", "foreignPID", "foreignOwner", "noOwnership", "isolated", "missingAttachment", "wrongAttachment", "isError"])
    func missingOrWrongAttachmentProofIsRejected(mode: String) throws {
        var result = prepared
        switch mode {
        case "missing": result.removeValue(forKey: "prepared")
        case "unprepared": result["prepared"] = .bool(false)
        case "numeric": result["prepared"] = .number(1)
        case "foreignPID": result["prepared_pid"] = .number(43)
        case "foreignOwner": result["endpoint_ownership"] = .object(["owner_pid": .number(43), "method": .string("listening_socket_pid")])
        case "noOwnership": result["endpoint_ownership"] = .null
        case "isolated": result["action"] = .string("launched_isolated_browser")
        case "missingAttachment": result.removeValue(forKey: "attachment")
        case "wrongAttachment": result["attachment"] = .object(["kind": .string("isolated_new")])
        default: break
        }
        let data = try envelope(result, isError: mode == "isError")
        #expect(throws: CuaMCPProxyError.permissionsRequired) {
            try DesktopBrowserHandshakeValidation.requirePrepared(data, pid: 42)
        }
    }

    @Test(arguments: ["missing", "foreign", "active", "numeric", "isError"])
    func incompleteSessionCleanupCannotConfirmSetup(mode: String) throws {
        var result: [String: DesktopControlJSONValue] = ["session": .string("owned"), "active": .bool(false)]
        switch mode {
        case "missing": result.removeValue(forKey: "active")
        case "foreign": result["session"] = .string("foreign")
        case "active": result["active"] = .bool(true)
        case "numeric": result["active"] = .number(0)
        default: break
        }
        let data = try envelope(result, isError: mode == "isError")
        #expect(throws: CuaMCPProxyError.permissionsRequired) {
            try DesktopBrowserHandshakeValidation.requireEnded(data, session: "owned")
        }
    }

    @Test func envelopeWithoutStructuredProofIsRejected() throws {
        let data = Data(#"{"result":{"content":[],"isError":false}}"#.utf8)
        #expect(throws: CuaMCPProxyError.permissionsRequired) {
            try DesktopBrowserHandshakeValidation.requirePrepared(data, pid: 42)
        }
        #expect(throws: CuaMCPProxyError.permissionsRequired) {
            try DesktopBrowserHandshakeValidation.requireEnded(data, session: "owned")
        }
    }
}
