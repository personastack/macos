import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol LocalClusterHTTPTransport: Sendable {
    func request(_ request: URLRequest) async throws -> (Data, Int)
}
public struct LocalClusterURLTransport: LocalClusterHTTPTransport {
    private let session: URLSession
    private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: RedirectBlocker(), delegateQueue: nil)
    }
    public func request(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, data.count <= AgentBridgeRequest.maximumBytes else { throw AgentBridgeFailure.invalidRequest }
        return (data, response.statusCode)
    }
}

/// All destinations are fixed paths on the native configured App origin.
public struct LocalClusterEnrollmentClient: Sendable {
    public let transport: any LocalClusterHTTPTransport
    public init(transport: any LocalClusterHTTPTransport = LocalClusterURLTransport()) { self.transport = transport }
    public func scope(configuration: DesktopEnvironmentConfiguration, cookies: String) async throws -> LocalClusterAuthenticatedScope {
        let response: LocalClusterAuthenticatedScope = try await send(configuration: configuration, cookies: cookies,
            path: "user/kubernetes/clusters/native-scope", method: "GET", workspaceID: nil, csrf: nil, body: nil)
        guard response.appOrigin == configuration.appOrigin, !response.userID.isEmpty, !response.workspaceID.isEmpty,
              response.userID.utf8.count <= 256, response.workspaceID.utf8.count <= 256 else { throw AgentBridgeFailure.scopeChanged }
        return response
    }
    public func prepare(configuration: DesktopEnvironmentConfiguration, cookies: String, workspaceID: String, csrf: String,
                        publicKey: String, documentID: String, name: String, operation: String = "create",
                        integrationID: String? = nil, configVersion: Int64? = nil) async throws -> LocalClusterSetupReceipt {
        struct Body: Encodable { let installation_public_key: String; let document_id: String; let operation: String; let name: String
            let integration_id: String?; let expected_config_version: Int64? }
        return try await send(configuration: configuration, cookies: cookies, path: "user/kubernetes/clusters/desktop-setups", method: "POST", workspaceID: workspaceID, csrf: csrf,
            body: JSONEncoder().encode(Body(installation_public_key: publicKey, document_id: documentID, operation: operation, name: name, integration_id: integrationID, expected_config_version: configVersion)))
    }
    public func redeem(configuration: DesktopEnvironmentConfiguration, cookies: String, csrf: String,
                       receipt: LocalClusterSetupReceipt, signature: Data) async throws -> LocalClusterEnrollment {
        guard receipt.setupID.range(of: "^[A-Za-z0-9_-]{1,256}$", options: .regularExpression) != nil,
              signature.count == 64 else { throw AgentBridgeFailure.invalidRequest }
        struct Body: Encodable { let document_id: String; let installation_public_key: String; let signature: String }
        let result: LocalClusterEnrollment = try await send(configuration: configuration, cookies: cookies,
            path: "user/kubernetes/clusters/desktop-setups/\(receipt.setupID)/redeem", method: "POST", workspaceID: receipt.workspaceID, csrf: csrf,
            body: JSONEncoder().encode(Body(document_id: receipt.documentID, installation_public_key: receipt.installationPublicKey, signature: signature.base64EncodedString())))
        guard !result.clusterID.isEmpty, !result.setupManifest.isEmpty, result.setupManifest.utf8.count <= 192 * 1024 else { throw AgentBridgeFailure.invalidRequest }
        return result
    }
    public func stop(configuration: DesktopEnvironmentConfiguration, cookies: String, workspaceID: String, csrf: String,
                     binding: LocalClusterTargetBinding, configVersion: Int64) async throws {
        struct Accepted: Decodable { let accepted: Bool }
        let result: Accepted = try await lifecycle(configuration: configuration, cookies: cookies, workspaceID: workspaceID, csrf: csrf,
            binding: binding, version: configVersion, operation: "stop")
        guard result.accepted else { throw AgentBridgeFailure.serviceUnavailable }
    }
    public func setStatus(configuration: DesktopEnvironmentConfiguration, cookies: String, workspaceID: String, csrf: String,
                          binding: LocalClusterTargetBinding, configVersion: Int64, enabled: Bool) async throws -> LocalClusterStatusChange {
        let status = enabled ? "active" : "disabled"
        let result: LocalClusterStatusChange = try await lifecycle(configuration: configuration, cookies: cookies, workspaceID: workspaceID, csrf: csrf,
            binding: binding, version: configVersion, operation: "native-status", status: status)
        try result.require(binding: binding, status: status, previousVersion: configVersion)
        return result
    }
    public func retire(configuration: DesktopEnvironmentConfiguration, cookies: String, workspaceID: String, csrf: String,
                       binding: LocalClusterTargetBinding, configVersion: Int64) async throws -> LocalClusterRetirement {
        let result: LocalClusterRetirement = try await lifecycle(configuration: configuration, cookies: cookies, workspaceID: workspaceID, csrf: csrf,
            binding: binding, version: configVersion, operation: "retire")
        try result.require(binding: binding)
        return result
    }
    private struct LifecycleBody: Encodable { let expected_config_version: Int64; let status: String? }
    private func lifecycle<T: Decodable>(configuration: DesktopEnvironmentConfiguration, cookies: String, workspaceID: String, csrf: String,
                                          binding: LocalClusterTargetBinding, version: Int64, operation: String, status: String? = nil) async throws -> T {
        try binding.requireValid()
        guard version > 0, ["stop", "native-status", "retire"].contains(operation) else { throw AgentBridgeFailure.invalidRequest }
        return try await send(configuration: configuration, cookies: cookies,
            path: "user/kubernetes/clusters/\(binding.integrationID)/\(operation)", method: "POST", workspaceID: workspaceID, csrf: csrf,
            body: JSONEncoder().encode(LifecycleBody(expected_config_version: version, status: status)))
    }
    private func send<T: Decodable>(configuration: DesktopEnvironmentConfiguration, cookies: String,
                                    path: String, method: String, workspaceID: String?, csrf: String?, body: Data?) async throws -> T {
        guard !cookies.isEmpty, !cookies.contains("\n"), !cookies.contains("\r") else { throw AgentBridgeFailure.scopeChanged }
        var request = URLRequest(url: configuration.appURL.appendingPathComponent(path))
        request.httpMethod = method; request.httpBody = body; request.httpShouldHandleCookies = false
        request.timeoutInterval = 15
        request.setValue(cookies, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("macos-local-cluster-v1", forHTTPHeaderField: "X-PersonaStack-Native-Client")
        if body != nil {
            guard let workspaceID, !workspaceID.isEmpty, workspaceID.utf8.count <= 256,
                  !workspaceID.contains(where: { $0.isWhitespace }),
                  let csrf, !csrf.isEmpty, csrf.utf8.count <= 512, !csrf.contains(where: { $0.isWhitespace }) else { throw AgentBridgeFailure.scopeChanged }
            request.setValue(workspaceID, forHTTPHeaderField: "X-PersonaStack-Workspace-ID")
            request.setValue(csrf, forHTTPHeaderField: "X-CSRF-Token")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, status) = try await transport.request(request)
        guard data.count <= AgentBridgeRequest.maximumBytes, [200, 201].contains(status) else {
            throw [401, 403].contains(status) ? AgentBridgeFailure.scopeChanged : AgentBridgeFailure.serviceUnavailable
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
