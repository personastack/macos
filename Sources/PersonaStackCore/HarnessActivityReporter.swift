import Foundation
import Darwin

public enum HarnessActivityReportError: Error, Sendable {
    case authorizationDenied
}

public enum HarnessActivityReporter {
    private struct ActivityBody: Encodable {
        let connectionID: String
        let sessionID: String
        let runID: String
        let state: String
        let sequence: Int64
        enum CodingKeys: String, CodingKey {
            case connectionID = "connection_id", sessionID = "session_id", runID = "run_id", state, sequence
        }
    }
    private struct RevokeBody: Encodable {
        let connectionID: String
        enum CodingKeys: String, CodingKey { case connectionID = "connection_id" }
    }
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    public static func report(_ credential: HarnessActivityCredential, sessionID: String, runID: String, state: String, sequence: Int64) async throws -> Bool {
        try await report(credential, sessionID: sessionID, runID: runID, state: state, sequence: sequence, transport: send)
    }

    static func report(_ credential: HarnessActivityCredential, sessionID: String, runID: String, state: String, sequence: Int64, transport: Transport) async throws -> Bool {
        guard ["start", "heartbeat", "stop"].contains(state), HarnessHookInput.safeID(sessionID), UUID(uuidString: runID) != nil, sequence > 0 else { throw LocalSessionError.invalidRequest }
        return try await post(credential, path: "/desktop/harnesses/activity", body: ActivityBody(connectionID: credential.connectionID, sessionID: sessionID, runID: runID, state: state, sequence: sequence), transport: transport)
    }

    public static func revoke(_ credential: HarnessActivityCredential) async throws {
        _ = try await post(credential, path: "/desktop/harnesses/revoke", body: RevokeBody(connectionID: credential.connectionID), transport: send)
    }

    private static func post<Body: Encodable>(_ credential: HarnessActivityCredential, path: String, body: Body, transport: Transport) async throws -> Bool {
        guard var components = URLComponents(url: credential.appURL, resolvingAgainstBaseURL: false),
              ["https", "http"].contains(components.scheme ?? ""), components.user == nil, components.password == nil else { throw LocalSessionError.invalidRequest }
        components.path = path; components.query = nil; components.fragment = nil
        guard let url = components.url else { throw LocalSessionError.invalidRequest }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("Bearer " + credential.activityToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse else { throw LocalSessionError.mcpUnavailable }
        if [401, 403].contains(http.statusCode) { throw HarnessActivityReportError.authorizationDenied }
        guard (200..<300).contains(http.statusCode) else { throw LocalSessionError.mcpUnavailable }
        if path.hasSuffix("/revoke") { return true }
        guard data.count < 8192, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let applied = object["applied"] as? Bool else { throw LocalSessionError.invalidRequest }
        return applied
    }

    private static func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 5; configuration.timeoutIntervalForResource = 6
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await session.data(for: request)
    }
}

/// Retry transient failures only while the last accepted activity lease can still be live.
public struct HarnessActivityRenewal {
    private var lastAcceptedAt: Date
    private let leaseDuration: TimeInterval
    public init(leaseStartedAt: Date, leaseDuration: TimeInterval = 45) {
        self.lastAcceptedAt = leaseStartedAt; self.leaseDuration = leaseDuration
    }

    public mutating func step(store: HarnessHookState, connectionID: String, sessionID: String, runID: String,
                              now: () -> Date = Date.init,
                              ownerAlive: (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM },
                              report: (String, Int64) async throws -> Bool) async throws -> Bool {
        let active = try store.lock(connectionID: connectionID, sessionID: sessionID)
        defer { active.unlock() }
        guard let turn = try active.read(), turn.runID == runID else { return false }
        guard ownerAlive(turn.ownerPID) else {
            try active.clear()
            _ = try? await report("stop", active.nextSequence())
            return false
        }
        let attemptTime = now()
        guard attemptTime.timeIntervalSince(lastAcceptedAt) < leaseDuration else { try active.clear(); return false }
        do {
            guard try await report("heartbeat", active.nextSequence()) else { try active.clear(); return false }
            lastAcceptedAt = attemptTime
            return true
        } catch HarnessActivityReportError.authorizationDenied {
            try active.clear()
            return false
        } catch {
            guard now().timeIntervalSince(lastAcceptedAt) < leaseDuration else { try active.clear(); return false }
            return true
        }
    }
}

public struct HarnessHookInput: Sendable, Equatable {
    public let sessionID: String
    public let turnID: String?
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 512 * 1024, let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let session = body["session_id"] as? String, safeID(session) else { throw LocalSessionError.invalidRequest }
        let turn = body["turn_id"] as? String
        guard turn == nil || safeID(turn!) else { throw LocalSessionError.invalidRequest }
        // No other payload field is retained. Hook inputs may contain private prompts and transcripts.
        return Self(sessionID: session, turnID: turn)
    }
    public static func safeID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128 && id.unicodeScalars.allSatisfy { (48...57).contains($0.value) || (65...90).contains($0.value) || (97...122).contains($0.value) || "-_.:".unicodeScalars.contains($0) }
    }
}
