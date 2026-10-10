import Foundation
import Testing
@testable import PersonaStackCore

private actor AgentBridgeDeadlineTransport: AgentBridgeControlTransport {
    enum Reply: Equatable, Sendable { case verified, cancelled, expired }
    let reply: Reply
    private(set) var calls = 0
    init(_ reply: Reply) { self.reply = reply }
    func exchange(_ request: Data) throws -> Data {
        calls += 1
        let envelope = try #require(JSONSerialization.jsonObject(with: request) as? [String: Any])
        #expect(envelope["operation"] as? String == "check")
        if reply == .cancelled { withUnsafeCurrentTask { $0?.cancel() } }
        var response: [String: Any] = ["version": 1, "request_id": envelope["request_id"]!]
        if reply == .expired {
            response["error"] = ["code": "operation_timeout", "message": "Local operation timed out or was cancelled. Check this connection before trying again."]
        } else {
            response["result"] = ["connections": []]
        }
        return try JSONSerialization.data(withJSONObject: response)
    }
}

@Suite struct AgentBridgeControlClientTests {
    @Test func socketWaitIncludesHelperDeadlineReplyGrace() {
        #expect(AgentBridgeSocketTransport.responseTimeoutSeconds == 10)
        #expect(AgentBridgeSocketTransport.responseTimeoutSeconds > 8)
    }

    @Test func cancelledCallerDoesNotDispatch() async {
        let transport = AgentBridgeDeadlineTransport(.verified)
        let client = AgentBridgeControlClient(transport: transport)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.send(AgentBridgeRequest(operation: "check", payload: [:]), returning: AgentBridgeConnections.self)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await transport.calls == 0)
    }

    @Test func cancellationDuringExchangeNeverAcceptsAReply() async {
        let transport = AgentBridgeDeadlineTransport(.cancelled)
        let client = AgentBridgeControlClient(transport: transport)
        let task = Task {
            try await client.send(AgentBridgeRequest(operation: "check", payload: [:]), returning: AgentBridgeConnections.self)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await transport.calls == 1)
    }

    @Test func helperExpiryIsAFiniteFailureWithoutRetryOrReadiness() async {
        let transport = AgentBridgeDeadlineTransport(.expired)
        let client = AgentBridgeControlClient(transport: transport)
        await #expect(throws: AgentBridgeFailure.operationTimeout) {
            _ = try await client.send(AgentBridgeRequest(operation: "check", payload: [:]), returning: AgentBridgeConnections.self)
        }
        #expect(await transport.calls == 1)
    }
}
