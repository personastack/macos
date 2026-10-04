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

    private func makeManager(preferences: UserDefaults = .standard,
        probe: @escaping @Sendable (LocalSessionHarness) throws -> LocalSessionHarnessProbe,
        preflight: @escaping @Sendable (LocalSessionHarness, LocalSessionHarnessProbe) throws -> Void = { _, _ in },
        install: @escaping @Sendable (LocalSessionBundle, URL, UUID, LocalSessionHarnessProbe) throws -> LocalSessionInstalledFiles,
        validateMCP: @escaping @Sendable (URL) async throws -> Void = { _ in }) -> LocalSessionManager {
        LocalSessionManager(preferences: preferences, probe: probe, preflight: preflight, install: install, validateMCP: validateMCP, storeCredential: { _, _ in }, revokeCredential: { _ in })
    }

    private func fixtureData(id: UUID, persona: String = "persona-a") throws -> Data {
        var body = LocalSessionBundleTests().fixture()
        body["connection_id"] = id.uuidString.lowercased()
        body["persona_id"] = persona
        var endpoint = URLComponents(string: body["mcp_url"] as! String)!
        endpoint.queryItems = [URLQueryItem(name: "connection_id", value: id.uuidString.lowercased()), URLQueryItem(name: "persona_id", value: persona), URLQueryItem(name: "workspace_id", value: body["workspace_id"] as? String)]
        body["mcp_url"] = endpoint.string!
        return try JSONSerialization.data(withJSONObject: body)
    }

    @Test func nativeProfileSelectionKeepsConnectionsIndependentAndRemovesOnlySelectedProfile() async throws {
        let personal = try HarnessFilesFixture(.codex, profileRelative: ".ai/eg/codex")
        let work = try HarnessFilesFixture(.codex, home: personal.root, profileRelative: ".ai/epic/codex")
        let link = personal.root.appendingPathComponent(".codex")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: personal.profile)
        let detected = LocalSessionHarnessProbe(executable: personal.executable, home: personal.root, profile: link, shell: personal.probe.shell, environment: ["PATH": "/usr/bin:/bin"])
        let revoked = LocalSessionConfigurationRecorder()
        let removedCredentials = LocalSessionConfigurationRecorder()
        let manager = LocalSessionManager(probe: { _ in detected }, preflight: { _, _ in }, install: { bundle, appURL, _, probe in
            let selected = probe.profile.path == personal.profile.path ? personal : work
            #expect(probe.profile.path == selected.profile.path)
            #expect(probe.environment["CODEX_HOME"] == selected.profile.path)
            #expect(probe.executable == selected.executable)
            return try selected.files.configure(bundle: bundle, appURL: appURL, home: probe.home, profile: probe.profile,
                sessionID: UUID(), executable: probe.executable, loginShell: probe.shell, harnessEnvironment: probe.environment)
        }, storeCredential: { _, _ in }, revokeCredential: { id in revoked.append(UUID(uuidString: id)!) },
        removeFiles: { id, harness, probe, appURL in
            #expect(probe.profile.path == work.profile.path)
            try work.files.remove(id, harness: harness, probe: probe, appURL: appURL)
        }, removeCredential: { id in removedCredentials.append(UUID(uuidString: id)!) })
        let view = WKWebView()
        manager.register(view, appURL: personal.source.appURL)
        _ = try await manager.apply(.state(scope: "profiles"), view: view)
        let choices = try await manager.apply(.profiles(scope: "profiles", harness: .codex), view: view)
        let rows = try #require(choices["profiles"] as? [[String: String]])
        #expect(rows.map { $0["label"] } == ["Personal (current)", "Work"])
        #expect(rows.allSatisfy { Set($0.keys) == ["label", "profile_id"] })
        let personalID = try #require(UUID(uuidString: rows[0]["profile_id"]!))
        let workID = try #require(UUID(uuidString: rows[1]["profile_id"]!))
        #expect(choices["profile_id"] as? String == personalID.uuidString.lowercased())
        func prepareAndConfigure() async throws -> UUID {
            let pending = try await manager.apply(.prepare(scope: "profiles", persona: "persona-a", harness: .codex, workspace: "ws_11111111111111111111111111111111"), view: view)
            let id = try #require(UUID(uuidString: pending["connection_id"] as! String))
            _ = try await manager.apply(.configure(scope: "profiles", pendingID: id, bundle: fixtureData(id: id)), view: view)
            return id
        }
        func connections() async throws -> [[String: Any]] {
            let response = try await manager.apply(.connections(scope: "profiles", harness: .codex), view: view)
            return try #require(response["connections"] as? [[String: Any]])
        }
        let personalConnection = try await prepareAndConfigure()
        #expect(try await connections().map { $0["connection_id"] as? String } == [personalConnection.uuidString.lowercased()])
        _ = try await manager.apply(.selectProfile(scope: "profiles", harness: .codex, profileID: workID), view: view)
        #expect(try await connections().isEmpty)
        let workConnection = try await prepareAndConfigure()
        #expect(workConnection != personalConnection)
        #expect(try await connections().map { $0["connection_id"] as? String } == [workConnection.uuidString.lowercased()])
        await #expect(throws: LocalSessionError.unsafeFiles) {
            _ = try await manager.apply(.remove(scope: "profiles", harness: .codex, connectionID: personalConnection), view: view)
        }
        #expect(revoked.all.isEmpty && removedCredentials.all.isEmpty)
        _ = try await manager.apply(.remove(scope: "profiles", harness: .codex, connectionID: workConnection), view: view)
        #expect(revoked.all == [workConnection] && removedCredentials.all == [workConnection])
        #expect(try await connections().isEmpty)
        _ = try await manager.apply(.selectProfile(scope: "profiles", harness: .codex, profileID: personalID), view: view)
        #expect(try await connections().map { $0["connection_id"] as? String } == [personalConnection.uuidString.lowercased()])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == personal.profile.path)
    }

    @Test func unsupportedAndStaleProfileHandlesRejectBeforeMutation() async throws {
        let personal = try HarnessFilesFixture(.codex, profileRelative: ".ai/eg/codex")
        let work = try HarnessFilesFixture(.codex, home: personal.root, profileRelative: ".ai/epic/codex")
        let detected = personal.probe
        let effects = LocalSessionConfigurationRecorder()
        let manager = LocalSessionManager(probe: { _ in detected }, preflight: { _, _ in effects.append(UUID()) },
            install: { _, _, _, _ in effects.append(UUID()); throw LocalSessionError.unsafeFiles },
            storeCredential: { _, _ in effects.append(UUID()) }, revokeCredential: { _ in effects.append(UUID()) },
            removeFiles: { _, _, _, _ in effects.append(UUID()) }, removeCredential: { _ in effects.append(UUID()) })
        let view = WKWebView()
        manager.register(view, appURL: personal.source.appURL)
        _ = try await manager.apply(.state(scope: "profiles"), view: view)
        let response = try await manager.apply(.profiles(scope: "profiles", harness: .codex), view: view)
        let rows = try #require(response["profiles"] as? [[String: String]])
        let workID = try #require(UUID(uuidString: rows[1]["profile_id"]!))
        await #expect(throws: LocalSessionError.staleRequest) {
            _ = try await manager.apply(.selectProfile(scope: "profiles", harness: .codex, profileID: UUID()), view: view)
        }
        await #expect(throws: LocalSessionError.staleRequest) {
            _ = try await manager.apply(.selectProfile(scope: "profiles", harness: .claudeCode, profileID: workID), view: view)
        }
        let otherPage = WKWebView()
        manager.register(otherPage, appURL: personal.source.appURL)
        _ = try await manager.apply(.state(scope: "profiles"), view: otherPage)
        await #expect(throws: LocalSessionError.staleRequest) {
            _ = try await manager.apply(.selectProfile(scope: "profiles", harness: .codex, profileID: workID), view: otherPage)
        }
        _ = try await manager.apply(.selectProfile(scope: "profiles", harness: .codex, profileID: workID), view: view)
        try FileManager.default.moveItem(at: work.profile, to: work.root.appendingPathComponent("moved-work-profile"))
        let id = UUID()
        let commands: [LocalSessionCommand] = [
            .selectProfile(scope: "profiles", harness: .codex, profileID: workID),
            .prepare(scope: "profiles", persona: "persona-a", harness: .codex, workspace: "ws_11111111111111111111111111111111"),
            .connections(scope: "profiles", harness: .codex),
            .check(scope: "profiles", harness: .codex, connectionID: id),
            .reconnect(scope: "profiles", harness: .codex, connectionID: id),
            .remove(scope: "profiles", harness: .codex, connectionID: id)
        ]
        for command in commands {
            await #expect(throws: LocalSessionError.staleRequest) { _ = try await manager.apply(command, view: view) }
        }
        #expect(effects.all.isEmpty)
    }

    @Test func changingProfileInvalidatesPreparedConnectionBeforeCredentialsOrFiles() async throws {
        let personal = try HarnessFilesFixture(.codex, profileRelative: ".ai/eg/codex")
        let work = try HarnessFilesFixture(.codex, home: personal.root, profileRelative: ".ai/epic/codex")
        let detected = personal.probe
        let effects = LocalSessionConfigurationRecorder()
        let manager = LocalSessionManager(probe: { _ in detected }, preflight: { _, _ in },
            install: { _, _, _, _ in effects.append(UUID()); throw LocalSessionError.unsafeFiles },
            storeCredential: { _, _ in effects.append(UUID()) }, revokeCredential: { _ in effects.append(UUID()) })
        let view = WKWebView()
        manager.register(view, appURL: personal.source.appURL)
        _ = try await manager.apply(.state(scope: "profiles"), view: view)
        let response = try await manager.apply(.profiles(scope: "profiles", harness: .codex), view: view)
        let rows = try #require(response["profiles"] as? [[String: String]])
        let workID = try #require(UUID(uuidString: rows[1]["profile_id"]!))
        let pending = try await manager.apply(.prepare(scope: "profiles", persona: "persona-a", harness: .codex, workspace: "ws_11111111111111111111111111111111"), view: view)
        let id = try #require(UUID(uuidString: pending["connection_id"] as! String))
        _ = try await manager.apply(.selectProfile(scope: "profiles", harness: .codex, profileID: workID), view: view)
        await #expect(throws: LocalSessionError.staleRequest) {
            _ = try await manager.apply(.configure(scope: "profiles", pendingID: id, bundle: fixtureData(id: id)), view: view)
        }
        let next = try await manager.apply(.prepare(scope: "profiles", persona: "persona-a", harness: .codex, workspace: "ws_11111111111111111111111111111111"), view: view)
        let nextID = try #require(UUID(uuidString: next["connection_id"] as! String))
        try FileManager.default.moveItem(at: work.profile, to: work.root.appendingPathComponent("moved-prepared-profile"))
        await #expect(throws: LocalSessionError.staleRequest) {
            _ = try await manager.apply(.configure(scope: "profiles", pendingID: nextID, bundle: fixtureData(id: nextID)), view: view)
        }
        #expect(effects.all.isEmpty)
    }

    @Test func localSessionManagerConfiguresIndependentHarnessesAndRemembersChoice() async throws {
        let fixture = LocalSessionBundleTests()
        let data = try JSONSerialization.data(withJSONObject: fixture.fixture())
        let result = probe()
        let defaults = try #require(UserDefaults(suiteName: "local-session-test-" + UUID().uuidString))
        let configurations = LocalSessionConfigurationRecorder()
        let fixtureURL = fixture.appURL
        let manager = makeManager(preferences: defaults, probe: { _ in result }, preflight: { _, _ in }, install: { bundle, appURL, id, profile in
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
            let prepared = try await manager.apply(.prepare(scope: "account/workspace", persona: persona, harness: .codex, workspace: "ws_11111111111111111111111111111111"), view: view)
            let value = try #require(prepared["pending_id"] as? String)
            let id = try #require(UUID(uuidString: value))
            var body = fixture.fixture()
            body["persona_id"] = persona
            requests.append((id, try fixtureData(id: id, persona: persona)))
        }
        for (id, body) in requests { _ = try await manager.apply(.configure(scope: "account/workspace", pendingID: id, bundle: body), view: view) }
        #expect(configurations.all.count == 4 && Set(configurations.all).count == 4)
        await #expect(throws: LocalSessionError.staleRequest) {
            _ = try await manager.apply(.configure(scope: "account/workspace", pendingID: requests[0].0, bundle: data), view: view)
        }
        manager.invalidateSession()
        await #expect(throws: LocalSessionError.staleRequest) {
            _ = try await manager.apply(.prepare(scope: "account/workspace", persona: "persona-a", harness: .codex, workspace: "ws_11111111111111111111111111111111"), view: view)
        }
        await #expect(throws: LocalSessionError.invalidRequest) {
            _ = try await manager.apply(.state(scope: "account/workspace"), view: WKWebView())
        }
    }

    @Test func localSessionManagerRejectsMissingCLIAndInstallerFailure() async throws {
        let fixture = LocalSessionBundleTests()
        let data = try JSONSerialization.data(withJSONObject: fixture.fixture())
        let view = WKWebView()
        let missing = makeManager(probe: { _ in throw LocalSessionError.missingHarness }, install: { _, _, _, _ in
            Issue.record("Missing CLI must not install files"); throw LocalSessionError.unsafeFiles
        })
        missing.register(view, appURL: fixture.appURL)
        _ = try await missing.apply(.state(scope: "scope"), view: view)
        await #expect(throws: LocalSessionError.missingHarness) {
            _ = try await missing.apply(.prepare(scope: "scope", persona: "persona-a", harness: .codex, workspace: "ws_11111111111111111111111111111111"), view: view)
        }
        let result = probe()
        let failure = makeManager(probe: { _ in result }, preflight: { _, _ in }, install: { _, _, _, _ in
            throw LocalSessionError.unsafeFiles
        })
        failure.register(view, appURL: fixture.appURL)
        _ = try await failure.apply(.state(scope: "scope"), view: view)
        let prepared = try await failure.apply(.prepare(scope: "scope", persona: "persona-a", harness: .codex, workspace: "ws_11111111111111111111111111111111"), view: view)
        let value = try #require(prepared["pending_id"] as? String)
        let id = try #require(UUID(uuidString: value))
        await #expect(throws: LocalSessionError.unsafeFiles) {
            _ = try await failure.apply(.configure(scope: "scope", pendingID: id, bundle: fixtureData(id: id)), view: view)
        }
    }

    @Test func localSessionManagerRejectsPreflightBeforeHostedPreparation() async throws {
        let fixture = LocalSessionBundleTests()
        let result = probe()
        let manager = makeManager(probe: { _ in result }, preflight: { _, _ in throw LocalSessionError.unsafeFiles },
                                          install: { _, _, _, _ in Issue.record("Rejected preflight must not configure"); throw LocalSessionError.unsafeFiles })
        let view = WKWebView()
        manager.register(view, appURL: fixture.appURL)
        _ = try await manager.apply(.state(scope: "scope"), view: view)
        await #expect(throws: LocalSessionError.unsafeFiles) {
            _ = try await manager.apply(.prepare(scope: "scope", persona: "persona-a", harness: .codex, workspace: "ws_11111111111111111111111111111111"), view: view)
        }
    }

    @Test func environmentSwitchWaitsForAnAlreadyStartedPluginInstall() async throws {
        let fixture = LocalSessionBundleTests()
        let data = try JSONSerialization.data(withJSONObject: fixture.fixture())
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = LocalSessionConfigurationRecorder()
        let result = probe()
        let manager = makeManager(probe: { _ in result }, preflight: { _, _ in }, install: { _, _, id, _ in
            started.signal()
            release.wait()
            finished.append(id)
            let root = URL(fileURLWithPath: "/fixture/sessions/" + id.uuidString)
            return LocalSessionInstalledFiles(directory: root, pluginManifest: root.appendingPathComponent("plugin.json"), skillDirectories: [])
        })
        let view = WKWebView()
        manager.register(view, appURL: fixture.appURL)
        _ = try await manager.apply(.state(scope: "switch-test"), view: view)
        let prepared = try await manager.apply(.prepare(scope: "switch-test", persona: "persona-a", harness: .codex, workspace: "ws_11111111111111111111111111111111"), view: view)
        let pendingIDValue = try #require(prepared["pending_id"] as? String)
        let pendingID = try #require(UUID(uuidString: pendingIDValue))
        let configuring = Task { @MainActor in
            _ = try await manager.apply(.configure(scope: "switch-test", pendingID: pendingID, bundle: fixtureData(id: pendingID)), view: view)
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
        #expect(finished.all.count == 1)
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
        let manager = makeManager(
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
        let prepared = try await manager.apply(.prepare(scope: "same-scope", persona: "persona-a", harness: .codex, workspace: "ws_11111111111111111111111111111111"), view: view)
        let pendingValue = try #require(prepared["pending_id"] as? String)
        let pendingID = try #require(UUID(uuidString: pendingValue))
        let configuring = Task { @MainActor in
            _ = try await manager.apply(.configure(scope: "same-scope", pendingID: pendingID, bundle: fixtureData(id: pendingID)), view: view)
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
        let manager = makeManager(
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
        let prepared = try await manager.apply(.prepare(scope: "retired-page", persona: "persona-a", harness: .codex, workspace: "ws_11111111111111111111111111111111"), view: view)
        let pendingValue = try #require(prepared["pending_id"] as? String)
        let pendingID = try #require(UUID(uuidString: pendingValue))
        let configuring = Task { @MainActor in
            _ = try await manager.apply(.configure(scope: "retired-page", pendingID: pendingID, bundle: fixtureData(id: pendingID)), view: view)
        }

        #expect(await Task.detached { waitForSignal(validationStarted) }.value)
        await manager.invalidateAndWait(view)
        releaseValidation.signal()

        await #expect(throws: LocalSessionError.staleRequest) { try await configuring.value }
        #expect(installations.all.isEmpty)
    }
}
