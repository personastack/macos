import Foundation
import PersonaStackCore
import ServiceManagement
import Testing
import WebKit
@testable import PersonaStack

private final class LocalClusterLifecycleEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func append(_ value: String) { lock.withLock { entries.append(value) } }
    var values: [String] { lock.withLock { entries } }
}
private final class LocalClusterLifecycleKeychain: DesktopControlKeychainAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: Data] = [:]
    private var locked = false
    private var custodyLocked = false
    func setLocked(_ value: Bool) { lock.withLock { locked = value } }
    func setCustodyLocked(_ value: Bool) { lock.withLock { custodyLocked = value } }
    let refuseWrites: Bool
    let events: LocalClusterLifecycleEvents
    init(key: Data, custody: Data, installationID: String, events: LocalClusterLifecycleEvents, refuseWrites: Bool) {
        entries["ai.personastack.desktop.local-cluster-installation/installation-ed25519-v1"] = key
        entries["ai.personastack.desktop.local-cluster-custody/" + installationID] = custody
        self.events = events; self.refuseWrites = refuseWrites
    }
    func read(service: String, account: String, interaction: DesktopControlKeychainInteraction) throws -> Data? {
        try lock.withLock {
            if locked || (custodyLocked && service.hasSuffix("local-cluster-custody")) { throw AgentBridgeFailure.credentialUnavailable }
            return entries[service + "/" + account]
        }
    }
    func write(_ data: Data, service: String, account: String, interaction: DesktopControlKeychainInteraction) throws {
        guard !refuseWrites else { throw AgentBridgeFailure.credentialUnavailable }
        events.append("key-write")
        lock.withLock { entries[service + "/" + account] = data }
    }
    func remove(service: String, account: String) throws { Issue.record("Lifecycle must not delete retained credentials") }
}
@MainActor private final class LocalClusterLifecycleRegistration: AgentBridgeServiceRegistration {
    var status: SMAppService.Status { .enabled }
    func register() throws { Issue.record("Unexpected registration") }
    func unregister() async throws { Issue.record("Unexpected unregister") }
}
private enum LocalClusterReadbackFailure: Sendable { case unavailable, network }
private enum LocalClusterReadbackScopeChange: Sendable { case none, cookie, document }
@MainActor private final class LocalClusterReadbackFence {
    var cookie = "personastack_session=fixture"
    var invalidate: (() -> Void)?
    let change: LocalClusterReadbackScopeChange
    init(_ change: LocalClusterReadbackScopeChange) { self.change = change }
    func readbackFailed() {
        if change == .cookie { cookie = "personastack_session=changed" }
        if change == .document { invalidate?() }
    }
}
private actor LocalClusterLifecycleHTTP: LocalClusterHTTPTransport {
    let fingerprint: String
    let failStop: Bool
    let failRetire: Bool
    let extraFingerprint: String?
    let readbackFailure: LocalClusterReadbackFailure?
    let readbackFence: LocalClusterReadbackFence
    let events: LocalClusterLifecycleEvents
    var status = "active"
    var version: Int64 = 7
    var visible = true
    init(fingerprint: String, failStop: Bool, failRetire: Bool, disabled: Bool, extraFingerprint: String?, readbackFailure: LocalClusterReadbackFailure?, readbackFence: LocalClusterReadbackFence, events: LocalClusterLifecycleEvents) {
        status = disabled ? "disabled" : "active"
        self.fingerprint = fingerprint; self.extraFingerprint = extraFingerprint; self.failStop = failStop; self.failRetire = failRetire; self.events = events
        self.readbackFailure = readbackFailure; self.readbackFence = readbackFence
    }
    func request(_ request: URLRequest) async throws -> (Data, Int) {
        let path = try #require(request.url?.path)
        #expect(request.value(forHTTPHeaderField: "X-PersonaStack-Native-Client") == "macos-local-cluster-v1")
        if path == "/user/kubernetes/clusters/native-scope" {
            #expect(request.httpMethod == "GET")
            if status == "disabled", let readbackFailure {
                events.append("cloud-readback-unavailable")
                await readbackFence.readbackFailed()
                if readbackFailure == .network { throw URLError(.networkConnectionLost) }
                return (Data("{}".utf8), 503)
            }
            let cluster: [String: Any] = ["cluster_id": "cluster-own", "name": "This Mac", "management": ["kind": "macos_app", "installation_id": fingerprint],
                "status": status, "config_version": version, "connection_state": "connected", "agent_connected": status == "active", "agent_capabilities_ready": true]
            var clusters = visible ? [cluster] : []
            if let extraFingerprint {
                var other = cluster
                other["cluster_id"] = "cluster-another-mac"
                other["management"] = ["kind": "macos_app", "installation_id": extraFingerprint]
                clusters.append(other)
            }
            return (try JSONSerialization.data(withJSONObject: ["user_id": "user-a", "workspace_id": "ws-a", "app_origin": "https://my.personastack.ai", "clusters": clusters]), 200)
        }
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "X-PersonaStack-Workspace-ID") == "ws-a")
        let requestBody = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        #expect(body["expected_config_version"] as? Int64 == version)
        switch path {
        case "/user/kubernetes/clusters/cluster-own/stop":
            events.append("cloud-stop")
            return (Data(failStop ? "{}".utf8 : #"{"accepted":true}"#.utf8), failStop ? 503 : 200)
        case "/user/kubernetes/clusters/cluster-own/native-status":
            status = try #require(body["status"] as? String); version += 1
            events.append("cloud-" + status)
            return (try JSONSerialization.data(withJSONObject: ["cluster_id": "cluster-own", "installation_id": fingerprint, "status": status, "config_version": version]), 200)
        case "/user/kubernetes/clusters/cluster-own/retire":
            events.append("cloud-retire")
            if failRetire { return (Data("{}".utf8), 503) }
            visible = false
            return (try JSONSerialization.data(withJSONObject: ["cluster_id": "cluster-own", "installation_id": fingerprint, "retirement_state": "retiring"]), 200)
        default:
            Issue.record("Unexpected cloud operation: \(path)")
            throw AgentBridgeFailure.invalidRequest
        }
    }
}
private actor LocalClusterLifecycleControl: AgentBridgeControlTransport {
    let binding: [String: String]
    let events: LocalClusterLifecycleEvents
    var removed: Bool
    var blank = false
    var running: Bool
    var partial: Bool
    let repairFails: Bool
    let localStopFails: Bool
    let bindingChangesAfterReadbackFailure: Bool
    var task: [String: Any]?
    init(fingerprint: String, removed: Bool, disabled: Bool, partial: Bool, repairFails: Bool, localStopFails: Bool, bindingChangesAfterReadbackFailure: Bool, events: LocalClusterLifecycleEvents) {
        binding = ["integration_id": "cluster-own", "installation_id": fingerprint]
        self.removed = removed; self.partial = partial; self.repairFails = repairFails; self.localStopFails = localStopFails; self.bindingChangesAfterReadbackFailure = bindingChangesAfterReadbackFailure
        running = !removed && !disabled && !partial; self.events = events
    }
    func exchange(_ request: Data) async throws -> Data {
        let object = try #require(JSONSerialization.jsonObject(with: request) as? [String: Any])
        let operation = try #require(object["operation"] as? String)
        let payload = try #require(object["payload"] as? [String: Any])
        let result: [String: Any]
        switch operation {
        case "status": result = ["connections": [], "local_cluster_control_version": 1]
        case "local_cluster_runtime_status":
            var value: [String: Any] = ["installed": !removed && !blank && !partial, "running": running, "kubernetes_available": running, "enabled": running, "installer_active": false]
            if removed { value["safe_reason"] = "local_data_removed"; value["action"] = "none" }
            if partial { value["safe_reason"] = "local_data_unavailable"; value["action"] = "details" }
            result = value
        case "local_cluster_binding":
            var value: [String: Any] = ["removed": removed]
            if blank { value["previous_removed_binding"] = binding } else { value["binding"] = binding }
            if bindingChangesAfterReadbackFailure && events.values.contains("cloud-readback-unavailable") {
                var changed = binding; changed["integration_id"] = "cluster-changed"
                value["binding"] = changed
            }
            result = value
        case "local_cluster_status":
            if let task, payload["attempt_id"] != nil || !blank { result = ["local_cluster": task] }
            else { result = ["local_cluster": ["state": "no_task", "action": "none"]] }
        case "local_cluster_runtime_stop":
            if partial { Issue.record("Partial removal must not depend on reconstructing Lima Stop metadata"); throw AgentBridgeFailure.serviceUnavailable }
            events.append("local-stop")
            if localStopFails { throw AgentBridgeFailure.serviceUnavailable }
            running = false; task = nil
            result = ["active": true]
        case "local_cluster_runtime_resume":
            #expect(!removed)
            events.append("local-resume"); running = true
            let scope = try #require(payload["scope"] as? [String: Any])
            let snapshot: [String: Any] = ["attempt_id": "22222222-2222-4222-8222-222222222222", "scope": scope, "state": "completed", "operation": "resume", "action": "none"]
            task = snapshot; result = ["local_cluster": snapshot]
        case "local_cluster_start":
            events.append("local-repair")
            if repairFails { throw AgentBridgeFailure.serviceUnavailable }
            let scope = try #require(payload["scope"] as? [String: Any])
            let snapshot: [String: Any] = ["attempt_id": "22222222-2222-4222-8222-222222222222", "scope": scope, "state": "installed", "operation": "install", "action": "none"]
            task = snapshot; result = ["local_cluster": snapshot]
        case "local_cluster_remove", "local_cluster_new_setup":
            let selected = try #require(payload["binding"] as? [String: String])
            #expect(selected == binding)
            if operation == "local_cluster_remove" { running = false; partial = false }
            else { #expect(!running) }
            let scope = try #require(payload["scope"] as? [String: Any])
            let op = operation == "local_cluster_remove" ? "remove" : "new_setup"
            events.append("local-" + op)
            if op == "remove" { removed = true }
            else { #expect(removed); removed = false; blank = true }
            let snapshot: [String: Any] = ["attempt_id": "22222222-2222-4222-8222-222222222222", "scope": scope, "state": "completed", "operation": op, "action": "none"]
            task = snapshot; result = ["local_cluster": snapshot]
        default:
            Issue.record("Unexpected helper operation: \(operation)")
            throw AgentBridgeFailure.invalidRequest
        }
        return try JSONSerialization.data(withJSONObject: ["version": 1, "request_id": object["request_id"]!, "result": result])
    }
}

@Suite @MainActor struct LocalClusterLifecycleManagerTests {
    private struct Rig {
        let manager: LocalClusterSetupManager
        let view: WKWebView
        let keychain: LocalClusterLifecycleKeychain
        let events: LocalClusterLifecycleEvents
        let fingerprint: String
    }
    private func rig(removed: Bool = false, disabled: Bool = false, wrongRetainedKey: Bool = false, changeCookieOnThirdRead: Bool = false, partial: Bool = false, repairFails: Bool = false, startupFailure: Bool = false, failStop: Bool = false, failRetire: Bool = false, refuseWrites: Bool = false, readbackFailure: LocalClusterReadbackFailure? = nil, readbackScopeChange: LocalClusterReadbackScopeChange = .none, localStopFails: Bool = false, bindingChangesAfterReadbackFailure: Bool = false) throws -> Rig {
        let key = try LocalClusterInstallationKey(rawRepresentation: Data(repeating: 7, count: 32))
        let retainedKey = wrongRetainedKey ? try LocalClusterInstallationKey(rawRepresentation: Data(repeating: 8, count: 32)) : key
        let events = LocalClusterLifecycleEvents()
        let enrollment = try JSONDecoder().decode(LocalClusterEnrollment.self, from: Data(#"{"cluster_id":"cluster-own","setup_manifest":"native-only-fixture"}"#.utf8))
        let scope = LocalClusterScope(appOrigin: "https://my.personastack.ai", accountID: "user-a", workspaceID: "ws-a", documentID: UUID())
        let custody = LocalClusterCredentialCustody(scope: scope, enrollment: enrollment)
        let keychain = LocalClusterLifecycleKeychain(key: retainedKey.rawRepresentation, custody: try JSONEncoder().encode(custody), installationID: key.installationID, events: events, refuseWrites: refuseWrites)
        let control = LocalClusterLifecycleControl(fingerprint: key.installationID, removed: removed, disabled: disabled, partial: partial, repairFails: repairFails, localStopFails: localStopFails, bindingChangesAfterReadbackFailure: bindingChangesAfterReadbackFailure, events: events)
        let client = AgentBridgeControlClient(transport: control)
        let readbackFence = LocalClusterReadbackFence(readbackScopeChange)
        let http = LocalClusterLifecycleHTTP(fingerprint: key.installationID, failStop: failStop, failRetire: failRetire, disabled: disabled,
            extraFingerprint: wrongRetainedKey ? retainedKey.installationID : nil, readbackFailure: readbackFailure, readbackFence: readbackFence, events: events)
        let preferences = try #require(UserDefaults(suiteName: "LocalClusterLifecycle." + UUID().uuidString))
        let service = AgentBridgeService(registration: LocalClusterLifecycleRegistration(), client: client, preferences: preferences, requireSignature: {}, clearDisabledPreference: {})
        var cookieReads = 0
        let manager = LocalClusterSetupManager(client: client, hosted: LocalClusterEnrollmentClient(transport: http), service: service,
            qualifiedRuntime: true, keychain: keychain, requireSignature: {}, prepareBackgroundEnable: { if startupFailure { throw AgentBridgeFailure.credentialUnavailable } }, approveEnvironment: { _ in },
            helperControlVersion: { 1 }, requirementsReader: { Issue.record("Existing lifecycle must not read fresh setup requirements"); throw AgentBridgeFailure.runtimeUnsupported },
            confirmSetupBudget: { _ in Issue.record("Existing lifecycle must not prompt for fresh setup"); return false }, configuration: { _ in .production }, cookieReader: { _, _ in
                cookieReads += 1
                return changeCookieOnThirdRead && cookieReads >= 3 ? "personastack_session=changed" : readbackFence.cookie
            },
            csrfReader: { _ in "csrf-fixture" }, confirmRemove: { true }, confirmNewSetup: { true }, confirmRotation: { Issue.record("Healthy custody must not rotate"); return false })
        let view = WKWebView(); manager.register(view, appURL: DesktopEnvironmentConfiguration.production.appURL)
        readbackFence.invalidate = { [weak manager, weak view] in
            guard let view else { return }; manager?.invalidate(view)
        }
        return Rig(manager: manager, view: view, keychain: keychain, events: events, fingerprint: key.installationID)
    }
    private func run(_ action: String, _ rig: Rig) async throws -> [String: Any] {
        let initial = try await rig.manager.apply(LocalClusterPageCommand.parse(["version": "1", "action": "state", "scope": ""]), view: rig.view)
        let scope = try #require(initial["scope"] as? String)
        return try await rig.manager.apply(LocalClusterPageCommand.parse(["version": "1", "action": action, "scope": scope]), view: rig.view)
    }
    @Test func disconnectRetainsIndependentStopFailureAfterDisableAndLocalStop() async throws {
        let rig = try rig(failStop: true)
        let response = try await run("disconnect", rig)
        let lifecycle = try #require(response["lifecycle"] as? [String: Any])
        #expect(lifecycle["cloud"] as? String == "disconnected")
        #expect(lifecycle["local"] as? String == "stopped")
        #expect(lifecycle["failure"] as? String == "stop_unconfirmed")
        #expect(rig.events.values == ["cloud-stop", "cloud-disabled", "local-stop"])
    }
    @Test(arguments: [LocalClusterReadbackFailure.unavailable, .network])
    private func disconnectStillStopsLocallyWhenDisabledCloudReadbackIsUnavailable(failure: LocalClusterReadbackFailure) async throws {
        let rig = try rig(readbackFailure: failure)
        let response = try await run("disconnect", rig)
        let lifecycle = try #require(response["lifecycle"] as? [String: Any])
        #expect(lifecycle["cloud"] as? String == "unknown")
        #expect(lifecycle["local"] as? String == "stopped")
        #expect(lifecycle["failure"] as? String == "status_change_unconfirmed")
        #expect(response["api_readiness"] as? String == "unknown")
        #expect(response["cluster_id"] == nil)
        #expect(rig.events.values == ["cloud-stop", "cloud-disabled", "cloud-readback-unavailable", "local-stop", "cloud-readback-unavailable"])
    }
    @Test(arguments: [LocalClusterReadbackScopeChange.cookie, .document])
    private func disconnectReadbackFailureCannotStopAfterRealScopeChange(change: LocalClusterReadbackScopeChange) async throws {
        let rig = try rig(readbackFailure: .unavailable, readbackScopeChange: change)
        await #expect(throws: AgentBridgeFailure.scopeChanged) { _ = try await run("disconnect", rig) }
        #expect(rig.events.values == ["cloud-stop", "cloud-disabled", "cloud-readback-unavailable"])
    }
    @Test func disconnectReadbackFailureCannotStopAfterPrivateBindingChange() async throws {
        let rig = try rig(readbackFailure: .unavailable, bindingChangesAfterReadbackFailure: true)
        await #expect(throws: AgentBridgeFailure.scopeChanged) { _ = try await run("disconnect", rig) }
        #expect(rig.events.values == ["cloud-stop", "cloud-disabled", "cloud-readback-unavailable"])
    }
    @Test func disconnectReadbackAndLocalStopFailureRemainUnconfirmed() async throws {
        let rig = try rig(readbackFailure: .unavailable, localStopFails: true)
        let response = try await run("disconnect", rig)
        let lifecycle = try #require(response["lifecycle"] as? [String: Any])
        #expect(lifecycle["cloud"] as? String == "unknown")
        #expect(lifecycle["local"] as? String == "running")
        #expect(lifecycle["failure"] as? String == "local_stop_unconfirmed")
        #expect(response["api_readiness"] as? String == "unknown")
        #expect(response["cluster_id"] == nil)
        #expect(rig.events.values == ["cloud-stop", "cloud-disabled", "cloud-readback-unavailable", "local-stop", "cloud-readback-unavailable"])
    }
    @Test func healthyResumeDoesNotRepeatFreshSetupConsent() async throws {
        let rig = try rig()
        _ = try await run("start", rig)
        #expect(rig.events.values == ["local-resume"])
    }
    @Test func reconnectReusesCustodyKeyAndExactTargetWithoutRotation() async throws {
        let rig = try rig(disabled: true)
        let response = try await run("reconnect", rig)
        let lifecycle = try #require(response["lifecycle"] as? [String: Any])
        #expect(lifecycle["cloud"] as? String == "connected")
        #expect(lifecycle["local"] as? String == "running")
        #expect(lifecycle["failure"] == nil)
        #expect(rig.events.values == ["cloud-active", "local-resume"])
        let retained = try rig.keychain.read(service: "ai.personastack.desktop.local-cluster-installation", account: "installation-ed25519-v1", interaction: .forbidden)
        let bytes = try #require(retained)
        #expect(try LocalClusterInstallationKey(rawRepresentation: bytes).installationID == rig.fingerprint)
    }
    @Test func cloudRetirementFailureDoesNotClaimLocalFilesWereRetained() async throws {
        let rig = try rig(failRetire: true)
        let response = try await run("remove", rig)
        let lifecycle = try #require(response["lifecycle"] as? [String: Any])
        #expect(lifecycle["local"] as? String == "removed")
        #expect(lifecycle["failure"] as? String == "retirement_unconfirmed")
        #expect(rig.events.values == ["cloud-retire", "local-remove"])
    }
    @Test func pendingCloudRetirementAndCompletedLocalRemovalStaySeparate() async throws {
        let rig = try rig()
        let response = try await run("remove", rig)
        let lifecycle = try #require(response["lifecycle"] as? [String: Any])
        #expect(lifecycle["cloud"] as? String == "retirement_pending")
        #expect(lifecycle["local"] as? String == "removed")
        #expect(lifecycle["available_actions"] as? [String] == ["new_setup"])
    }
    @Test func partialRemovalCanRetryWithoutSeparateLimaStop() async throws {
        let rig = try rig(partial: true, failRetire: true)
        let response = try await run("remove", rig)
        let lifecycle = try #require(response["lifecycle"] as? [String: Any])
        #expect(lifecycle["local"] as? String == "removed")
        #expect(rig.events.values == ["cloud-retire", "local-remove"])
    }
    @Test func fastRepairCompletionDoesNotLeaveRequestActionBusy() async throws {
        let rig = try rig()
        let response = try await run("repair", rig)
        let lifecycle = try #require(response["lifecycle"] as? [String: Any])
        let native = try #require(response["native_status"] as? [String: Any])
        #expect(lifecycle["action"] as? String == "none")
        #expect(native["state"] as? String == "installed")
        #expect(rig.events.values == ["local-repair"])
    }
    @Test func failedRepairDoesNotLeaveRequestActionBusy() async throws {
        let rig = try rig(repairFails: true)
        await #expect(throws: AgentBridgeFailure.serviceUnavailable) { _ = try await run("repair", rig) }
        let response = try await run("state", rig)
        let lifecycle = try #require(response["lifecycle"] as? [String: Any])
        #expect(lifecycle["action"] as? String == "none")
        #expect(rig.events.values == ["local-repair"])
    }
    @Test func externalStartupCredentialErrorIsNotLocalCustodyGuidance() async throws {
        let rig = try rig(startupFailure: true)
        await #expect(throws: AgentBridgeFailure.credentialUnavailable) { _ = try await run("repair", rig) }
        let response = try await run("state", rig)
        let native = try #require(response["native_status"] as? [String: Any])
        #expect(native["safe_reason"] as? String != "local_credentials_unavailable")
        #expect(rig.events.values.isEmpty)
    }
    @Test func lockedNativeKeyCanBeRecheckedWithoutGeneratingAnotherIdentity() async throws {
        let rig = try rig()
        rig.keychain.setLocked(true)
        let blocked = try await run("repair", rig)
        #expect((blocked["native_status"] as? [String: Any])?["safe_reason"] as? String == "local_credentials_unavailable")
        rig.keychain.setLocked(false)
        let refreshed = try await run("state", rig)
        let native = try #require(refreshed["native_status"] as? [String: Any])
        let lifecycle = try #require(refreshed["lifecycle"] as? [String: Any])
        #expect(native["safe_reason"] as? String != "local_credentials_unavailable")
        #expect((lifecycle["available_actions"] as? [String])?.contains("repair") == true)
        #expect(lifecycle["failure"] == nil)
        _ = try await run("repair", rig)
        #expect(rig.events.values == ["local-repair"])
    }
    @Test func lockedNativeCustodyCanBeRecheckedBeforeSameTargetReconnect() async throws {
        let rig = try rig(disabled: true)
        rig.keychain.setCustodyLocked(true)
        let blocked = try await run("reconnect", rig)
        #expect((blocked["native_status"] as? [String: Any])?["safe_reason"] as? String == "local_credentials_unavailable")
        rig.keychain.setCustodyLocked(false)
        let refreshed = try await run("state", rig)
        #expect((refreshed["native_status"] as? [String: Any])?["safe_reason"] as? String != "local_credentials_unavailable")
        _ = try await run("reconnect", rig)
        #expect(rig.events.values == ["cloud-active", "local-resume"])
    }
    @Test func anotherOwnedMacKeyCannotCreateOrSelectATargetForThisRuntime() async throws {
        let rig = try rig(wrongRetainedKey: true)
        let response = try await run("install", rig)
        #expect(response["api_readiness"] as? String == "unknown")
        #expect(response["cluster_id"] == nil)
        #expect((response["native_status"] as? [String: Any])?["safe_reason"] as? String == "local_credentials_unavailable")
        #expect(rig.events.values.isEmpty)
    }
    @Test func changedCookieDuringNativeStateCannotEmitPriorReadyTarget() async throws {
        let rig = try rig(changeCookieOnThirdRead: true)
        await #expect(throws: AgentBridgeFailure.scopeChanged) { _ = try await run("state", rig) }
        #expect(rig.events.values.isEmpty)
    }
    @Test func blankSetupCannotRekeyAnExistingRuntime() async throws {
        let rig = try rig()
        let response = try await run("new_setup", rig)
        let lifecycle = try #require(response["lifecycle"] as? [String: Any])
        #expect(lifecycle["failure"] as? String == "new_setup_unconfirmed")
        #expect(rig.events.values.isEmpty)
    }
    @Test func failedFreshKeyWriteCannotReleaseRemovedTombstone() async throws {
        let rig = try rig(removed: true, refuseWrites: true)
        let response = try await run("new_setup", rig)
        let lifecycle = try #require(response["lifecycle"] as? [String: Any])
        #expect(lifecycle["local"] as? String == "removed")
        #expect(lifecycle["failure"] as? String == "new_setup_unconfirmed")
        #expect(!rig.events.values.contains("local-new_setup"))
    }
    @Test func explicitBlankSetupPersistsFreshIdentityBeforeReleasingTombstone() async throws {
        let rig = try rig(removed: true)
        let response = try await run("new_setup", rig)
        let lifecycle = try #require(response["lifecycle"] as? [String: Any])
        #expect(lifecycle["cloud"] as? String == "unknown")
        #expect(lifecycle["local"] as? String == "stopped")
        #expect(lifecycle["available_actions"] as? [String] == ["install"])
        #expect(rig.events.values == ["key-write", "local-new_setup"])
        let retained = try rig.keychain.read(service: "ai.personastack.desktop.local-cluster-installation", account: "installation-ed25519-v1", interaction: .forbidden)
        let bytes = try #require(retained)
        #expect(try LocalClusterInstallationKey(rawRepresentation: bytes).installationID != rig.fingerprint)
    }
}
