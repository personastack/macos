import Darwin
import Foundation
import Testing
@testable import PersonaStackCore

private final class HarnessRenewalClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value.addTimeInterval(seconds) }
}

struct HarnessActivityRenewalTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("hook-renewal-" + UUID().uuidString)
    }
    private func credential(_ connection: String) -> HarnessActivityCredential {
        .init(connectionID: connection, activityToken: "fixture-only", appURL: URL(string: "https://my.personastack.ai/base?discard=true")!, harness: .codex, routingEnabled: false)
    }
    private func write(_ turn: HarnessHookTurn, store: HarnessHookState, connection: String) throws {
        let state = try store.lock(connectionID: connection, sessionID: "session"); defer { state.unlock() }
        try state.write(turn)
    }
    private func read(_ store: HarnessHookState, connection: String) throws -> HarnessHookTurn? {
        let state = try store.lock(connectionID: connection, sessionID: "session"); defer { state.unlock() }
        return try state.read()
    }
    private func report(_ credential: HarnessActivityCredential, run: String, state: String, status: Int, applied: Bool = true) async throws -> Bool {
        try await HarnessActivityReporter.report(credential, sessionID: "session", runID: run, state: state, transport: { request in
            #expect(request.url?.absoluteString == "https://my.personastack.ai/desktop/harnesses/activity")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-only")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(request.timeoutInterval == 5)
            let requestBody = try #require(request.httpBody)
            let body = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: String])
            #expect(body == ["connection_id": credential.connectionID, "session_id": "session", "run_id": run, "state": state])
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil))
            return (Data("{\"applied\":\(applied)}".utf8), response)
        })
    }

    @Test(arguments: [401, 403])
    func permanentDenialClearsMatchingRunAndExits(status: Int) async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = HarnessHookState(root: root), connection = UUID().uuidString.lowercased(), run = UUID().uuidString.lowercased()
        let credential = credential(connection), clock = HarnessRenewalClock()
        try write(.init(runID: run, turnID: "turn", ownerPID: getpid()), store: store, connection: connection)
        var renewal = HarnessActivityRenewal(leaseStartedAt: clock.now())
        clock.advance(15)
        let retry = try await renewal.step(store: store, connectionID: connection, sessionID: "session", runID: run, now: clock.now, ownerAlive: { _ in true }, report: { state in
            try await report(credential, run: run, state: state, status: status)
        })
        #expect(!retry)
        #expect(try read(store, connection: connection) == nil)
    }

    @Test func transientFailuresRetryOnlyWithinAcceptedLeaseAndRecoveryRenewsBudget() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = HarnessHookState(root: root), connection = UUID().uuidString.lowercased(), run = UUID().uuidString.lowercased()
        let credential = credential(connection), clock = HarnessRenewalClock()
        let turn = HarnessHookTurn(runID: run, turnID: "turn", ownerPID: getpid())
        try write(turn, store: store, connection: connection)
        var renewal = HarnessActivityRenewal(leaseStartedAt: clock.now())
        clock.advance(15)
        #expect(try await renewal.step(store: store, connectionID: connection, sessionID: "session", runID: run, now: clock.now, ownerAlive: { _ in true }, report: { _ in throw URLError(.timedOut) }))
        #expect(try read(store, connection: connection) == turn)
        clock.advance(15)
        #expect(try await renewal.step(store: store, connectionID: connection, sessionID: "session", runID: run, now: clock.now, ownerAlive: { _ in true }, report: { state in try await report(credential, run: run, state: state, status: 200) }))
        clock.advance(30)
        #expect(try await renewal.step(store: store, connectionID: connection, sessionID: "session", runID: run, now: clock.now, ownerAlive: { _ in true }, report: { state in try await report(credential, run: run, state: state, status: 503) }))
        clock.advance(15)
        #expect(try await !renewal.step(store: store, connectionID: connection, sessionID: "session", runID: run, now: clock.now, ownerAlive: { _ in true }, report: { _ in Issue.record("An expired lease must not be retried"); return true }))
        #expect(try read(store, connection: connection) == nil)
    }

    @Test func transientRequestThatCrossesLeaseExpiryClearsState() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = HarnessHookState(root: root), connection = UUID().uuidString.lowercased(), run = UUID().uuidString.lowercased(), clock = HarnessRenewalClock()
        try write(.init(runID: run, turnID: nil, ownerPID: getpid()), store: store, connection: connection)
        var renewal = HarnessActivityRenewal(leaseStartedAt: clock.now())
        clock.advance(42)
        let retry = try await renewal.step(store: store, connectionID: connection, sessionID: "session", runID: run, now: clock.now, ownerAlive: { _ in true }, report: { _ in clock.advance(6); throw URLError(.timedOut) })
        #expect(!retry)
        #expect(try read(store, connection: connection) == nil)
    }

    @Test func replacedRunExitsWithoutReportingOrClearingNewTurn() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = HarnessHookState(root: root), connection = UUID().uuidString.lowercased(), clock = HarnessRenewalClock()
        let newer = HarnessHookTurn(runID: UUID().uuidString.lowercased(), turnID: "newer", ownerPID: getpid())
        try write(newer, store: store, connection: connection)
        var renewal = HarnessActivityRenewal(leaseStartedAt: clock.now())
        #expect(try await !renewal.step(store: store, connectionID: connection, sessionID: "session", runID: UUID().uuidString.lowercased(), now: clock.now, ownerAlive: { _ in true }, report: { _ in Issue.record("Stale renewal must not report"); return true }))
        #expect(try read(store, connection: connection) == newer)
    }

    @Test(arguments: ["unapplied", "parent-ended"])
    func terminalRenewalClearsOnlyCurrentRun(reason: String) async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = HarnessHookState(root: root), connection = UUID().uuidString.lowercased(), run = UUID().uuidString.lowercased(), clock = HarnessRenewalClock()
        let credential = credential(connection)
        try write(.init(runID: run, turnID: nil, ownerPID: getpid()), store: store, connection: connection)
        var renewal = HarnessActivityRenewal(leaseStartedAt: clock.now())
        let retry = try await renewal.step(store: store, connectionID: connection, sessionID: "session", runID: run, now: clock.now, ownerAlive: { _ in reason != "parent-ended" }, report: { state in
            #expect(state == (reason == "parent-ended" ? "stop" : "heartbeat"))
            return try await report(credential, run: run, state: state, status: 200, applied: false)
        })
        #expect(!retry)
        #expect(try read(store, connection: connection) == nil)
    }
}
