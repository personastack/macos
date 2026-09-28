import AppKit
import Foundation
import Testing
import WebKit
@testable import PersonaStack
@testable import PersonaStackCore

private final class LocalSessionConfigurationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID] = []
    func append(_ value: UUID) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    var all: [UUID] { lock.lock(); defer { lock.unlock() }; return values }
}

private func waitForSignal(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + 2) == .success
}

@MainActor
struct LocalSessionManagerTests {
    private func probe() -> LocalSessionHarnessProbe {
        LocalSessionHarnessProbe(executable: URL(fileURLWithPath: "/fixture/codex"), home: URL(fileURLWithPath: "/fixture/home"), profile: URL(fileURLWithPath: "/fixture/home/.codex"), shell: URL(fileURLWithPath: "/bin/zsh"))
    }

    @Test func localSessionManagerConfiguresIndependentHarnessesAndRemembersChoice() async throws {
        let fixture = LocalSessionBundleTests()
        let data = try JSONSerialization.data(withJSONObject: fixture.fixture())
        let result = probe()
        let defaults = try #require(UserDefaults(suiteName: "local-session-test-" + UUID().uuidString))
        let configurations = LocalSessionConfigurationRecorder()
        let fixtureURL = fixture.appURL
        let manager = LocalSessionManager(preferences: defaults, probe: { _ in result }, preflight: { _, _ in }, install: { bundle, appURL, id, profile in
            #expect(["persona-a", "persona-b"].contains(bundle.personaID))
            #expect(appURL == fixtureURL)
            #expect(profile.home.path == "/fixture/home")
            configurations.append(id)
            let root = URL(fileURLWithPath: "/fixture/sessions/" + id.uuidString)
            return LocalSessionInstalledFiles(directory: root, pluginManifest: root.appendingPathComponent("plugin.json"), skillDirectories: [])
        })
        let view = WKWebView()
        manager.register(view, appURL: fixture.appURL)
        let firstState = try await manager.apply(.state(scope: "account/workspace"), view: view)
        #expect(firstState["version"] as? String == "2")
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
        for (id, body) in requests { _ = try await manager.apply(.configure(scope: "account/workspace", pendingID: id, bundle: body), view: view) }
        #expect(configurations.all.count == 4 && Set(configurations.all).count == 4)
        await #expect(throws: LocalSessionError.staleRequest) {
            _ = try await manager.apply(.configure(scope: "account/workspace", pendingID: requests[0].0, bundle: data), view: view)
        }
        manager.invalidateSession()
        await #expect(throws: LocalSessionError.staleRequest) {
            _ = try await manager.apply(.prepare(scope: "account/workspace", persona: "persona-a", harness: .codex), view: view)
        }
        await #expect(throws: LocalSessionError.invalidRequest) {
            _ = try await manager.apply(.state(scope: "account/workspace"), view: WKWebView())
        }
    }

    @Test func localSessionManagerRejectsMissingCLIAndInstallerFailure() async throws {
        let fixture = LocalSessionBundleTests()
        let data = try JSONSerialization.data(withJSONObject: fixture.fixture())
        let view = WKWebView()
        let missing = LocalSessionManager(probe: { _ in throw LocalSessionError.missingHarness }, install: { _, _, _, _ in
            Issue.record("Missing CLI must not install files"); throw LocalSessionError.unsafeFiles
        })
        missing.register(view, appURL: fixture.appURL)
        _ = try await missing.apply(.state(scope: "scope"), view: view)
        await #expect(throws: LocalSessionError.missingHarness) {
            _ = try await missing.apply(.prepare(scope: "scope", persona: "persona-a", harness: .codex), view: view)
        }
        let result = probe()
        let failure = LocalSessionManager(probe: { _ in result }, preflight: { _, _ in }, install: { _, _, _, _ in
            throw LocalSessionError.unsafeFiles
        })
        failure.register(view, appURL: fixture.appURL)
        _ = try await failure.apply(.state(scope: "scope"), view: view)
        let prepared = try await failure.apply(.prepare(scope: "scope", persona: "persona-a", harness: .codex), view: view)
        let value = try #require(prepared["pending_id"] as? String)
        let id = try #require(UUID(uuidString: value))
        await #expect(throws: LocalSessionError.unsafeFiles) {
            _ = try await failure.apply(.configure(scope: "scope", pendingID: id, bundle: data), view: view)
        }
    }

    @Test func localSessionManagerRejectsPreflightBeforeHostedPreparation() async throws {
        let fixture = LocalSessionBundleTests()
        let result = probe()
        let manager = LocalSessionManager(probe: { _ in result }, preflight: { _, _ in throw LocalSessionError.unsafeFiles },
                                          install: { _, _, _, _ in Issue.record("Rejected preflight must not configure"); throw LocalSessionError.unsafeFiles })
        let view = WKWebView()
        manager.register(view, appURL: fixture.appURL)
        _ = try await manager.apply(.state(scope: "scope"), view: view)
        await #expect(throws: LocalSessionError.unsafeFiles) {
            _ = try await manager.apply(.prepare(scope: "scope", persona: "persona-a", harness: .codex), view: view)
        }
    }

    @Test func environmentSwitchWaitsForAnAlreadyStartedPluginInstall() async throws {
        let fixture = LocalSessionBundleTests()
        let data = try JSONSerialization.data(withJSONObject: fixture.fixture())
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = LocalSessionConfigurationRecorder()
        let result = probe()
        let manager = LocalSessionManager(probe: { _ in result }, preflight: { _, _ in }, install: { _, _, id, _ in
            started.signal()
            release.wait()
            finished.append(id)
            let root = URL(fileURLWithPath: "/fixture/sessions/" + id.uuidString)
            return LocalSessionInstalledFiles(directory: root, pluginManifest: root.appendingPathComponent("plugin.json"), skillDirectories: [])
        })
        let view = WKWebView()
        manager.register(view, appURL: fixture.appURL)
        _ = try await manager.apply(.state(scope: "switch-test"), view: view)
        let prepared = try await manager.apply(.prepare(scope: "switch-test", persona: "persona-a", harness: .codex), view: view)
        let pendingIDValue = try #require(prepared["pending_id"] as? String)
        let pendingID = try #require(UUID(uuidString: pendingIDValue))
        let configuring = Task { @MainActor in
            _ = try await manager.apply(.configure(scope: "switch-test", pendingID: pendingID, bundle: data), view: view)
        }

        let installStarted = await Task.detached { waitForSignal(started) }.value
        #expect(installStarted)
        try await Task.sleep(for: .milliseconds(20))
        let releaser = Task.detached {
            try? await Task.sleep(for: .milliseconds(30))
            release.signal()
        }

        await manager.invalidateAndWait(view)
        await releaser.value
        _ = try await configuring.value
        #expect(finished.all == [pendingID])
        await #expect(throws: LocalSessionError.invalidRequest) {
            _ = try await manager.apply(.state(scope: "switch-test"), view: view)
        }
    }

    @Test func configureRejectsScopeThatChangesAwayAndBackDuringMCPValidation() async throws {
        let fixture = LocalSessionBundleTests()
        let data = try JSONSerialization.data(withJSONObject: fixture.fixture())
        let validationStarted = DispatchSemaphore(value: 0)
        let releaseValidation = DispatchSemaphore(value: 0)
        let installations = LocalSessionConfigurationRecorder()
        let result = probe()
        let manager = LocalSessionManager(
            probe: { _ in result },
            preflight: { _, _ in },
            install: { _, _, id, _ in
                installations.append(id)
                let root = URL(fileURLWithPath: "/fixture/sessions/" + id.uuidString)
                return LocalSessionInstalledFiles(directory: root, pluginManifest: root.appendingPathComponent("plugin.json"), skillDirectories: [])
            },
            validateMCP: { _ in
                validationStarted.signal()
                let validationReleased = await Task.detached(operation: { waitForSignal(releaseValidation) }).value
                guard validationReleased else {
                    throw LocalSessionError.mcpUnavailable
                }
            }
        )
        let view = WKWebView()
        manager.register(view, appURL: fixture.appURL)
        _ = try await manager.apply(.state(scope: "same-scope"), view: view)
        let prepared = try await manager.apply(.prepare(scope: "same-scope", persona: "persona-a", harness: .codex), view: view)
        let pendingValue = try #require(prepared["pending_id"] as? String)
        let pendingID = try #require(UUID(uuidString: pendingValue))
        let configuring = Task { @MainActor in
            _ = try await manager.apply(.configure(scope: "same-scope", pendingID: pendingID, bundle: data), view: view)
        }

        #expect(await Task.detached { waitForSignal(validationStarted) }.value)
        manager.invalidateSession()
        _ = try await manager.apply(.state(scope: "same-scope"), view: view)
        releaseValidation.signal()

        await #expect(throws: LocalSessionError.staleRequest) { try await configuring.value }
        #expect(installations.all.isEmpty)
    }

    @Test func retiredPageCannotStartConfigurationAfterMCPValidation() async throws {
        let fixture = LocalSessionBundleTests()
        let data = try JSONSerialization.data(withJSONObject: fixture.fixture())
        let validationStarted = DispatchSemaphore(value: 0)
        let releaseValidation = DispatchSemaphore(value: 0)
        let installations = LocalSessionConfigurationRecorder()
        let result = probe()
        let manager = LocalSessionManager(
            probe: { _ in result },
            preflight: { _, _ in },
            install: { _, _, id, _ in
                installations.append(id)
                let root = URL(fileURLWithPath: "/fixture/sessions/" + id.uuidString)
                return LocalSessionInstalledFiles(directory: root, pluginManifest: root.appendingPathComponent("plugin.json"), skillDirectories: [])
            },
            validateMCP: { _ in
                validationStarted.signal()
                let validationReleased = await Task.detached(operation: { waitForSignal(releaseValidation) }).value
                guard validationReleased else {
                    throw LocalSessionError.mcpUnavailable
                }
            }
        )
        let view = WKWebView()
        manager.register(view, appURL: fixture.appURL)
        _ = try await manager.apply(.state(scope: "retired-page"), view: view)
        let prepared = try await manager.apply(.prepare(scope: "retired-page", persona: "persona-a", harness: .codex), view: view)
        let pendingValue = try #require(prepared["pending_id"] as? String)
        let pendingID = try #require(UUID(uuidString: pendingValue))
        let configuring = Task { @MainActor in
            _ = try await manager.apply(.configure(scope: "retired-page", pendingID: pendingID, bundle: data), view: view)
        }

        #expect(await Task.detached { waitForSignal(validationStarted) }.value)
        await manager.invalidateAndWait(view)
        releaseValidation.signal()

        await #expect(throws: LocalSessionError.staleRequest) { try await configuring.value }
        #expect(installations.all.isEmpty)
    }
}
