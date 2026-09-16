import AppKit
import Foundation
import Testing
import WebKit
@testable import PersonaStack
@testable import PersonaStackCore

@MainActor
struct LocalSessionManagerTests {
    private func probe() -> LocalSessionHarnessProbe {
        LocalSessionHarnessProbe(executable: URL(fileURLWithPath: "/fixture/codex"), home: URL(fileURLWithPath: "/fixture/home"), profile: URL(fileURLWithPath: "/fixture/home/.codex"), shell: URL(fileURLWithPath: "/bin/zsh"))
    }

    @Test func localSessionManagerLaunchesIndependentSessionsAndRemembersChoice() async throws {
        let fixture = LocalSessionBundleTests()
        let data = try JSONSerialization.data(withJSONObject: fixture.fixture())
        let result = probe()
        let defaults = try #require(UserDefaults(suiteName: "local-session-test-" + UUID().uuidString))
        var launches: [UUID] = []
        var opened: [URL] = []
        let manager = LocalSessionManager(preferences: defaults, probe: { _ in result }, install: { bundle, appURL, id, profile in
            #expect(["persona-a", "persona-b"].contains(bundle.personaID))
            #expect(appURL == fixture.appURL)
            #expect(profile.home.path == "/fixture/home")
            launches.append(id)
            let root = URL(fileURLWithPath: "/fixture/sessions/" + id.uuidString)
            return LocalSessionInstalledFiles(directory: root, launcher: root.appendingPathComponent("launch.command"), skillDirectories: [])
        }, terminal: { opened.append($0) })
        let view = WKWebView()
        manager.register(view, appURL: fixture.appURL)
        let firstState = try await manager.apply(.state(scope: "account/workspace"), view: view)
        #expect(firstState["harness"] == nil)
        _ = try await manager.apply(.select(scope: "account/workspace", harness: .codex), view: view)
        #expect(try await manager.apply(.state(scope: "account/workspace"), view: view)["harness"] as? String == "codex")
        var requests: [(UUID, Data)] = []
        for persona in ["persona-a", "persona-a", "persona-b", "persona-b"] {
            let prepared = try await manager.apply(.prepare(scope: "account/workspace", persona: persona, harness: .codex), view: view)
            let value = try #require(prepared["pending_id"] as? String)
            let id = try #require(UUID(uuidString: value))
            var body = fixture.fixture()
            body["persona_id"] = persona
            requests.append((id, try JSONSerialization.data(withJSONObject: body)))
        }
        for (id, body) in requests { _ = try await manager.apply(.launch(scope: "account/workspace", pendingID: id, bundle: body), view: view) }
        #expect(launches.count == 4 && Set(launches).count == 4)
        #expect(opened.count == 4 && Set(opened).count == 4)
        await #expect(throws: LocalSessionError.staleRequest) {
            _ = try await manager.apply(.launch(scope: "account/workspace", pendingID: requests[0].0, bundle: data), view: view)
        }
        manager.invalidateSession()
        #expect(opened.count == 4) // Invalidation never closes already handed-off sessions.
        await #expect(throws: LocalSessionError.staleRequest) {
            _ = try await manager.apply(.prepare(scope: "account/workspace", persona: "persona-a", harness: .codex), view: view)
        }
        await #expect(throws: LocalSessionError.invalidRequest) {
            _ = try await manager.apply(.state(scope: "account/workspace"), view: WKWebView())
        }
    }

    @Test func localSessionManagerMissingCLIAndFailedHandoff() async throws {
        let fixture = LocalSessionBundleTests()
        let data = try JSONSerialization.data(withJSONObject: fixture.fixture())
        let view = WKWebView()
        let missing = LocalSessionManager(probe: { _ in throw LocalSessionError.missingHarness }, install: { _, _, _, _ in
            Issue.record("Missing CLI must not install files"); throw LocalSessionError.unsafeFiles
        }, terminal: { _ in Issue.record("Missing CLI must not open Terminal") })
        missing.register(view, appURL: fixture.appURL)
        _ = try await missing.apply(.state(scope: "scope"), view: view)
        await #expect(throws: LocalSessionError.missingHarness) {
            _ = try await missing.apply(.prepare(scope: "scope", persona: "persona-a", harness: .codex), view: view)
        }
        let result = probe()
        let failure = LocalSessionManager(probe: { _ in result }, install: { _, _, _, _ in
            LocalSessionInstalledFiles(directory: result.home, launcher: result.home.appendingPathComponent("launch.command"), skillDirectories: [])
        }, terminal: { _ in throw LocalSessionError.terminalUnavailable })
        failure.register(view, appURL: fixture.appURL)
        _ = try await failure.apply(.state(scope: "scope"), view: view)
        let prepared = try await failure.apply(.prepare(scope: "scope", persona: "persona-a", harness: .codex), view: view)
        let value = try #require(prepared["pending_id"] as? String)
        let id = try #require(UUID(uuidString: value))
        await #expect(throws: LocalSessionError.terminalUnavailable) {
            _ = try await failure.apply(.launch(scope: "scope", pendingID: id, bundle: data), view: view)
        }
    }
}
