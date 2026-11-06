import Foundation
import Testing
@testable import PersonaStackCore

struct HarnessActivitySequenceTests {
    @Test func sessionOrderingSurvivesClearingAndNewTurn() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("hook-order-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let connection = UUID().uuidString.lowercased()
        let credential = HarnessActivityCredential(connectionID: connection, activityToken: "fixture-only", appURL: URL(string: "https://app.example")!, harness: .codex, routingEnabled: true)
        let store = HarnessHookState(root: root)
        let first = try HarnessHookInput.decode(Data("{\"session_id\":\"same\",\"turn_id\":\"one\"}".utf8))
        let next = try HarnessHookInput.decode(Data("{\"session_id\":\"same\",\"turn_id\":\"two\"}".utf8))
        var reports: [Int64] = []
        let firstRun = try #require(await HarnessHookDispatcher.dispatch(credential, event: "UserPromptSubmit", input: first, store: store) { _, state, sequence in
            #expect(state == "start"); reports.append(sequence); return true
        })
        var renewal = HarnessActivityRenewal(leaseStartedAt: Date())
        let renewed = try await renewal.step(store: store, connectionID: connection, sessionID: "same", runID: firstRun, ownerAlive: { _ in true }, report: { state, sequence in
            #expect(state == "heartbeat"); reports.append(sequence); return true
        })
        #expect(renewed)
        _ = try await HarnessHookDispatcher.dispatch(credential, event: "Stop", input: first, store: store) { _, state, sequence in
            #expect(state == "stop"); reports.append(sequence); return true
        }
        let reopened = HarnessHookState(root: root)
        let nextRun = try #require(await HarnessHookDispatcher.dispatch(credential, event: "UserPromptSubmit", input: next, store: reopened) { _, state, sequence in
            #expect(state == "start"); reports.append(sequence); return true
        })
        #expect(firstRun != nextRun)
        #expect(reports == [1, 2, 3, 4])
        #expect(try await !renewal.step(store: reopened, connectionID: connection, sessionID: "same", runID: firstRun, report: { _, _ in
            Issue.record("Old turn must not allocate or report activity"); return true
        }))
        let locked = try reopened.lock(connectionID: connection, sessionID: "same")
        defer { locked.unlock() }
        #expect(try locked.nextSequence() == 5)
    }

    @Test func countersAreScopedToConnectionAndSession() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("hook-order-scope-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HarnessHookState(root: root)
        let first = UUID().uuidString.lowercased(), other = UUID().uuidString.lowercased()
        for (connection, session) in [(first, "one"), (first, "two"), (other, "one")] {
            let locked = try store.lock(connectionID: connection, sessionID: session)
            #expect(try locked.nextSequence() == 1)
            locked.unlock()
        }
    }

    @Test func reporterRequiresAndEncodesNumericOrder() async throws {
        struct Body: Decodable { let connection_id: String; let session_id: String; let run_id: String; let state: String; let sequence: Int64 }
        let credential = HarnessActivityCredential(connectionID: UUID().uuidString.lowercased(), activityToken: "fixture-only", appURL: URL(string: "https://app.example")!, harness: .codex, routingEnabled: true)
        let run = UUID().uuidString.lowercased()
        let applied = try await HarnessActivityReporter.report(credential, sessionID: "session", runID: run, state: "heartbeat", sequence: 42, transport: { request in
            let body = try JSONDecoder().decode(Body.self, from: #require(request.httpBody))
            #expect(body.sequence == 42 && body.state == "heartbeat" && body.run_id == run)
            #expect(body.connection_id == credential.connectionID && body.session_id == "session")
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data("{\"applied\":true}".utf8), response)
        })
        #expect(applied)
        do {
            _ = try await HarnessActivityReporter.report(credential, sessionID: "session", runID: run, state: "start", sequence: 0, transport: { _ in
                Issue.record("Invalid order must not reach the API"); throw URLError(.badURL)
            })
            Issue.record("Zero sequence was accepted")
        } catch LocalSessionError.invalidRequest { }
    }
}
