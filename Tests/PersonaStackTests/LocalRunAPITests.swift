import Foundation
import Testing
@testable import PersonaStack
@testable import PersonaStackCore

struct LocalRunAPITests {
    @Test func localRunNativeRedemptionUsesSelectedOriginAndPrivateVerifier() async throws {
        let fixture = LocalRunHTTPFixture(status: 200, body: Data("{}".utf8))
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.unregister() }
        let body = try JSONEncoder().encode(["session_id": "session", "ticket": "ticket", "code_verifier": "private-verifier"])
        _ = try await LocalRunAPI.request(appURL: URL(string: "https://selected.example/user/personas?ignored=1")!, path: "/desktop/local-runs/redeem", body: body, session: session)
        let captured = try #require(fixture.captured)
        #expect(captured.url?.absoluteString == "https://selected.example/desktop/local-runs/redeem")
        #expect(captured.httpMethod == "POST")
        #expect(captured.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(captured.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(fixture.requestBody == body)
    }

    @Test func localRunNativeRevokeSendsBearerOnlyInAuthorizationHeader() async throws {
        let fixture = LocalRunHTTPFixture(status: 204)
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.unregister() }
        let body = Data(#"{"session_id":"session"}"#.utf8)
        let (_, response) = try await LocalRunAPI.request(appURL: URL(string: "https://selected.example")!, path: "/desktop/local-runs/revoke", body: body, bearer: "private-bearer", session: session)
        #expect(response.statusCode == 204)
        #expect(fixture.captured?.value(forHTTPHeaderField: "Authorization") == "Bearer private-bearer")
        #expect(!String(decoding: fixture.requestBody, as: UTF8.self).contains("private-bearer"))
        #expect(fixture.captured?.url?.query == nil)
    }

    @Test(arguments: [false, true]) func localRunRevokeRequiresConfirmedServerResponse(offline: Bool) async throws {
        let fixture = LocalRunHTTPFixture(status: 503, offline: offline)
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.unregister() }
        let bundle = try LocalRunTests().fixture()
        await #expect(throws: LocalRunError.revocationUnconfirmed) {
            try await LocalRunAPI.revoke(appURL: URL(string: "https://selected.example")!, bundle: bundle, session: session)
        }
        #expect(fixture.captured?.url?.path == "/desktop/local-runs/revoke")
    }

    @Test func localRunRevokeAcceptsOnlyNoContentSuccess() async throws {
        let fixture = LocalRunHTTPFixture(status: 204)
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.unregister() }
        try await LocalRunAPI.revoke(appURL: URL(string: "https://selected.example")!, bundle: LocalRunTests().fixture(), session: session)
    }

    @Test(arguments: [302, 307]) func localRunNativeRejectsRedirectResponse(status: Int) async throws {
        let fixture = LocalRunHTTPFixture(status: status)
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.unregister() }
        await #expect(throws: LocalRunError.invalidBundle) {
            try await LocalRunAPI.request(appURL: URL(string: "https://selected.example")!, path: "/desktop/local-runs/redeem", body: Data(), session: session)
        }
    }

    @Test func localRunNativeRejectsOversizedResponseBeforeReadingPayload() async throws {
        let fixture = LocalRunHTTPFixture(status: 200, length: 13 * 1024 * 1024)
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.unregister() }
        await #expect(throws: LocalRunError.invalidBundle) {
            try await LocalRunAPI.request(appURL: URL(string: "https://selected.example")!, path: "/desktop/local-runs/redeem", body: Data(), session: session)
        }
    }
}

private final class LocalRunHTTPFixture: @unchecked Sendable {
    let id = UUID().uuidString
    let status: Int
    let body: Data
    let length: Int?
    let offline: Bool
    private let lock = NSLock()
    private var request: URLRequest?
    private var receivedBody = Data()
    var captured: URLRequest? { lock.withLock { request } }
    var requestBody: Data { lock.withLock { receivedBody } }
    init(status: Int, body: Data = Data(), length: Int? = nil, offline: Bool = false) { self.status = status; self.body = body; self.length = length; self.offline = offline }
    func session() -> URLSession {
        LocalRunURLProtocol.registryLock.withLock { LocalRunURLProtocol.fixtures[id] = self }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalRunURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Local-Run-Test": id]
        return URLSession(configuration: configuration)
    }
    func unregister() { _ = LocalRunURLProtocol.registryLock.withLock { LocalRunURLProtocol.fixtures.removeValue(forKey: id) } }
    func capture(_ request: URLRequest) {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(contentsOf: buffer.prefix(read))
            }
        }
        lock.withLock { self.request = request; receivedBody = data }
    }
}

private final class LocalRunURLProtocol: URLProtocol, @unchecked Sendable {
    static let registryLock = NSLock()
    nonisolated(unsafe) static var fixtures: [String: LocalRunHTTPFixture] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: "X-Local-Run-Test"),
              let fixture = Self.registryLock.withLock({ Self.fixtures[id] }), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: LocalRunError.invalidFrame); return
        }
        fixture.capture(request)
        if fixture.offline { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let response = HTTPURLResponse(url: url, statusCode: fixture.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(fixture.length ?? fixture.body.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
