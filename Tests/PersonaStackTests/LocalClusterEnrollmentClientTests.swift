import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PersonaStackCore
import Testing

private actor LocalClusterHTTPFixture: LocalClusterHTTPTransport {
    struct Expected: Sendable { let path: String; let method: String; let bodyFields: Set<String>; let response: String; let status: Int }
    var expected: [Expected]
    private(set) var calls = 0
    init(_ expected: [Expected]) { self.expected = expected }
    func request(_ request: URLRequest) async throws -> (Data, Int) {
        guard !expected.isEmpty else { throw AgentBridgeFailure.invalidRequest }
        let next = expected.removeFirst(); calls += 1
        #expect(request.url?.scheme == "https")
        #expect(request.url?.host == "app.example")
        #expect(request.url?.path == next.path)
        #expect(request.httpMethod == next.method)
        #expect(request.url?.query == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == "personastack_session=fixture")
        #expect(request.value(forHTTPHeaderField: "X-PersonaStack-Native-Client") == "macos-local-cluster-v1")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.httpShouldHandleCookies == false)
        for name in ["Origin", "Referer", "Sec-Fetch-Site", "Sec-Fetch-Mode", "Authorization"] { #expect(request.value(forHTTPHeaderField: name) == nil) }
        if next.method == "POST" {
            #expect(request.value(forHTTPHeaderField: "X-CSRF-Token") == "csrf-fixture")
            #expect(request.value(forHTTPHeaderField: "X-PersonaStack-Workspace-ID") == "ws-a")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            let data = try #require(request.httpBody)
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(Set(body.keys) == next.bodyFields)
            if next.path.hasSuffix("/redeem") { #expect(Data(base64Encoded: try #require(body["signature"] as? String))?.count == 64) }
            else if next.path.hasSuffix("/desktop-setups") { #expect(body["operation"] as? String == "create"); #expect(body["name"] as? String == "This Mac") }
            else {
                #expect(body["expected_config_version"] as? Int == (next.path.hasSuffix("/retire") ? 8 : 7))
                if next.path.hasSuffix("/native-status") { #expect(body["status"] as? String == "disabled") }
            }
        } else { #expect(request.httpBody == nil); #expect(request.value(forHTTPHeaderField: "X-PersonaStack-Workspace-ID") == nil) }
        return (Data(next.response.utf8), next.status)
    }
}

@Suite struct LocalClusterEnrollmentClientTests {
    private let configuration = try! DesktopEnvironmentConfiguration(appURL: "https://app.example", gatewayURL: "https://gateway.example", mcpURL: "https://mcp.example")
    private let cookies = "personastack_session=fixture"

    @Test func nativeCurrentScopeUsesFixedOriginAndNoBrowserHeaders() async throws {
        let fixture = LocalClusterHTTPFixture([.init(path: "/user/kubernetes/clusters/native-scope", method: "GET", bodyFields: [],
            response: #"{"user_id":"user-a","workspace_id":"ws-a","app_origin":"https://app.example","clusters":[]}"#, status: 200)])
        let owner = try await LocalClusterEnrollmentClient(transport: fixture).scope(configuration: configuration, cookies: cookies)
        #expect(owner.userID == "user-a")
        #expect(await fixture.calls == 1)
    }

    @Test func prepareAndRedeemNeverSendPageAuthorityOrRetry() async throws {
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        let receiptJSON = "{\"setup_id\":\"setup-a\",\"expires_at\":\"1970-01-01T00:03:20Z\",\"user_id\":\"user-a\",\"workspace_id\":\"ws-a\",\"app_origin\":\"https://app.example\",\"document_id\":\"11111111-1111-4111-8111-111111111111\",\"installation_public_key\":\"\(key)\",\"installation_id\":\"fingerprint\",\"operation\":\"create\",\"name\":\"This Mac\"}"
        let fixture = LocalClusterHTTPFixture([
            .init(path: "/user/kubernetes/clusters/desktop-setups", method: "POST", bodyFields: ["installation_public_key", "document_id", "operation", "name"], response: receiptJSON, status: 201),
            .init(path: "/user/kubernetes/clusters/desktop-setups/setup-a/redeem", method: "POST", bodyFields: ["document_id", "installation_public_key", "signature"], response: "{}", status: 500)])
        let client = LocalClusterEnrollmentClient(transport: fixture)
        let receipt = try await client.prepare(configuration: configuration, cookies: cookies, workspaceID: "ws-a", csrf: "csrf-fixture", publicKey: key,
            documentID: "11111111-1111-4111-8111-111111111111", name: "This Mac")
        await #expect(throws: AgentBridgeFailure.serviceUnavailable) {
            _ = try await client.redeem(configuration: configuration, cookies: cookies, csrf: "csrf-fixture", receipt: receipt, signature: Data(repeating: 1, count: 64))
        }
        #expect(await fixture.calls == 2)
    }

    @Test func lifecycleRequestsUseExactBindingVersionAndNoCredentialMutation() async throws {
        let fingerprint = String(repeating: "a", count: 64)
        let binding = try LocalClusterTargetBinding(integrationID: "cluster-own", installationID: fingerprint)
        let changed = "{\"cluster_id\":\"cluster-own\",\"installation_id\":\"\(fingerprint)\",\"status\":\"disabled\",\"config_version\":8}"
        let retired = "{\"cluster_id\":\"cluster-own\",\"installation_id\":\"\(fingerprint)\",\"retirement_state\":\"retiring\"}"
        let fixture = LocalClusterHTTPFixture([
            .init(path: "/user/kubernetes/clusters/cluster-own/stop", method: "POST", bodyFields: ["expected_config_version"], response: "{\"accepted\":true}", status: 200),
            .init(path: "/user/kubernetes/clusters/cluster-own/native-status", method: "POST", bodyFields: ["expected_config_version", "status"], response: changed, status: 200),
            .init(path: "/user/kubernetes/clusters/cluster-own/retire", method: "POST", bodyFields: ["expected_config_version"], response: retired, status: 200)])
        let client = LocalClusterEnrollmentClient(transport: fixture)
        try await client.stop(configuration: configuration, cookies: cookies, workspaceID: "ws-a", csrf: "csrf-fixture", binding: binding, configVersion: 7)
        _ = try await client.setStatus(configuration: configuration, cookies: cookies, workspaceID: "ws-a", csrf: "csrf-fixture", binding: binding, configVersion: 7, enabled: false)
        let result = try await client.retire(configuration: configuration, cookies: cookies, workspaceID: "ws-a", csrf: "csrf-fixture", binding: binding, configVersion: 8)
        #expect(result.state == .retiring)
        #expect(await fixture.calls == 3)
    }

    @Test func authDenialAndWrongOriginNeverBecomeSuccess() async throws {
        for (status, response) in [(403, "{}"), (302, "{}"), (200, #"{"user_id":"user-a","workspace_id":"ws-a","app_origin":"https://evil.example","clusters":[]}"#)] {
            let fixture = LocalClusterHTTPFixture([.init(path: "/user/kubernetes/clusters/native-scope", method: "GET", bodyFields: [], response: response, status: status)])
            await #expect(throws: (any Error).self) { _ = try await LocalClusterEnrollmentClient(transport: fixture).scope(configuration: configuration, cookies: cookies) }
            #expect(await fixture.calls == 1)
        }
    }
}
