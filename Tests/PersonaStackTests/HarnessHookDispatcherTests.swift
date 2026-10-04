import Darwin
import Foundation
import Testing
@testable import PersonaStackCore

struct HarnessHookDispatcherTests {
    private func input(_ session: String = "same-session", turn: String = "turn") throws -> HarnessHookInput {
        try HarnessHookInput.decode(JSONSerialization.data(withJSONObject: ["session_id": session, "turn_id": turn]))
    }
    private func credential(_ harness: LocalSessionHarness) throws -> HarnessActivityCredential {
        let source = LocalSessionBundleTests()
        var body = source.fixture()
        body["harness"] = harness.rawValue
        let connection = UUID().uuidString.lowercased()
        body["connection_id"] = connection
        body["activity_token"] = String(repeating: connection.replacingOccurrences(of: "-", with: ""), count: 2)
        body["mcp_url"] = "https://mcp.personastack.ai/v1/mcp?connection_id=" + connection + "&persona_id=persona-a&workspace_id=ws_11111111111111111111111111111111"
        return HarnessActivityCredential(bundle: try LocalSessionBundle.decode(JSONSerialization.data(withJSONObject: body), appURL: source.appURL, now: source.now), appURL: source.appURL)
    }
    private func read(_ store: HarnessHookState, _ credential: HarnessActivityCredential, session: String = "same-session") throws -> HarnessHookTurn? {
        let active = try store.lock(connectionID: credential.connectionID, sessionID: session)
        defer { active.unlock() }
        return try active.read()
    }
    private func report(_ credential: HarnessActivityCredential, input: HarnessHookInput, run: String, state: String) async throws -> Bool {
        try await HarnessActivityReporter.report(credential, sessionID: input.sessionID, runID: run, state: state, transport: { request in
            #expect(request.url?.absoluteString == "https://my.personastack.ai/desktop/harnesses/activity")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + credential.activityToken)
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            let data = try #require(request.httpBody)
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
            #expect(body == ["connection_id": credential.connectionID, "session_id": input.sessionID, "run_id": run, "state": state])
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data("{\"applied\":true}".utf8), response)
        })
    }

    @Test(arguments: [LocalSessionHarness.codex, .claudeCode])
    func currentCredentialsEnableEveryAttachedConnection(_ harness: LocalSessionHarness) throws {
        for _ in 0..<2 {
            let current = try credential(harness)
            #expect(current.routingEnabled)
            let restored = try JSONDecoder().decode(HarnessActivityCredential.self, from: JSONEncoder().encode(current))
            #expect(restored.routingEnabled)
            #expect(restored.connectionID == current.connectionID)
            #expect(restored.harness == harness)
        }
    }

    @Test(arguments: ["Stop", "StopFailure", "Interrupt", "SessionEnd"])
    func profileSessionStartsEveryConnectionAndStopsOnlyItsOwnTurn(_ terminal: String) async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("hook-dispatch-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HarnessHookState(root: root), first = try credential(.codex), second = try credential(.codex)
        #expect(first.activityToken != second.activityToken)
        let shared = try input(), siblingSession = try input("sibling-session")
        var reports: [String] = []
        func dispatch(_ credential: HarnessActivityCredential, _ event: String, _ input: HarnessHookInput) async throws -> String? {
            try await HarnessHookDispatcher.dispatch(credential, event: event, input: input, store: store, ownerPID: getpid()) { run, state in
                reports.append(credential.connectionID + ":" + state)
                return try await report(credential, input: input, run: run, state: state)
            }
        }
        let firstRun = try #require(await dispatch(first, "UserPromptSubmit", shared))
        let secondRun = try #require(await dispatch(second, "UserPromptSubmit", shared))
        let siblingRun = try #require(await dispatch(first, "UserPromptSubmit", siblingSession))
        #expect(firstRun != secondRun)
        #expect(try read(store, first)?.runID == firstRun)
        #expect(try read(store, second)?.runID == secondRun)
        #expect(try await dispatch(first, terminal, shared) == nil)
        #expect(try read(store, first) == nil)
        #expect(try read(store, second)?.runID == secondRun)
        #expect(try read(store, first, session: "sibling-session")?.runID == siblingRun)
        #expect(reports == [first.connectionID + ":start", second.connectionID + ":start", first.connectionID + ":start", first.connectionID + ":stop"])
        #expect(try await dispatch(second, terminal, shared) == nil)
        #expect(try read(store, second) == nil)
        #expect(try read(store, first, session: "sibling-session")?.runID == siblingRun)
    }

    @Test func duplicateStartAndStaleStopLeaveBothConnectionsActive() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("hook-fence-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HarnessHookState(root: root), first = try credential(.codex), second = try credential(.codex)
        let old = try input(), newer = try input(turn: "new-turn")
        for current in [first, second] {
            _ = try await HarnessHookDispatcher.dispatch(current, event: "UserPromptSubmit", input: old, store: store) { _, state in #expect(state == "start"); return true }
        }
        let secondTurn = try read(store, second)
        let newRun = try await HarnessHookDispatcher.dispatch(first, event: "UserPromptSubmit", input: newer, store: store) { _, state in #expect(state == "start"); return true }
        for (event, input) in [("UserPromptSubmit", newer), ("Stop", old)] {
            #expect(try await HarnessHookDispatcher.dispatch(first, event: event, input: input, store: store) { _, _ in Issue.record("Fenced event must not report"); return true } == nil)
        }
        #expect(try read(store, first)?.runID == newRun)
        #expect(try read(store, second) == secondTurn)
    }

    @Test(arguments: ["rejected", "failed"])
    func unsuccessfulStartClearsOnlyItsConnection(_ reason: String) async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("hook-reject-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HarnessHookState(root: root), first = try credential(.codex), second = try credential(.codex), input = try input()
        let siblingRun = try await HarnessHookDispatcher.dispatch(second, event: "UserPromptSubmit", input: input, store: store) { _, _ in true }
        do {
            let result = try await HarnessHookDispatcher.dispatch(first, event: "UserPromptSubmit", input: input, store: store) { _, _ in
                if reason == "failed" { throw HarnessActivityReportError.authorizationDenied }
                return false
            }
            #expect(reason == "rejected")
            #expect(result == nil)
        } catch HarnessActivityReportError.authorizationDenied { #expect(reason == "failed") }
        #expect(try read(store, first) == nil)
        #expect(try read(store, second)?.runID == siblingRun)
    }

    @Test func legacyCredentialCannotReportOrCreateSessionState() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("hook-disabled-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credential = HarnessActivityCredential(connectionID: UUID().uuidString.lowercased(), activityToken: "legacy-fixture", appURL: URL(string: "https://my.personastack.ai")!, harness: .codex, routingEnabled: false)
        #expect(try await HarnessHookDispatcher.dispatch(credential, event: "UserPromptSubmit", input: input(), store: HarnessHookState(root: root)) { _, _ in Issue.record("Legacy credential must not report"); return true } == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
