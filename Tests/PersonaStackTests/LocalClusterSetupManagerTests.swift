import Foundation
import PersonaStackCore
import ServiceManagement
import Testing
import WebKit
@testable import PersonaStack

private actor LocalClusterPageHTTPFixture: LocalClusterHTTPTransport {
    private(set) var calls = 0
    func request(_ request: URLRequest) async throws -> (Data, Int) {
        calls += 1
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/user/kubernetes/clusters/native-scope")
        return (Data(#"{"user_id":"user-a","workspace_id":"ws-a","app_origin":"https://my.personastack.ai","clusters":[]}"#.utf8), 200)
    }
}
private actor LocalClusterPageControlFixture: AgentBridgeControlTransport {
    private(set) var operations: [String] = []
    let runtimeFailure: Bool
    init(runtimeFailure: Bool = false) { self.runtimeFailure = runtimeFailure }
    func exchange(_ request: Data) async throws -> Data {
        let object = try #require(JSONSerialization.jsonObject(with: request) as? [String: Any])
        let operation = try #require(object["operation"] as? String)
        operations.append(operation)
        #expect(["local_cluster_status", "local_cluster_runtime_status"].contains(operation))
        if runtimeFailure && operation == "local_cluster_runtime_status" {
            return try JSONSerialization.data(withJSONObject: ["version": 1, "request_id": object["request_id"]!,
                "result": ["installed": true, "running": false, "kubernetes_available": false, "enabled": false,
                    "installer_active": false, "safe_reason": "component_unverified", "action": "update_app"]])
        }
        return try JSONSerialization.data(withJSONObject: ["version": 1, "request_id": object["request_id"]!,
            "error": ["code": "runtime_unsupported", "message": "Managed local cluster setup is unavailable."]])
    }
}

@MainActor private final class LocalClusterEnabledRegistration: AgentBridgeServiceRegistration {
    var status: SMAppService.Status { .enabled }
    func register() throws { Issue.record("Unexpected registration") }
    func unregister() async throws { Issue.record("Unexpected unregister") }
}
private final class LocalClusterMissingKeychain: DesktopControlKeychainAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var writes = 0
    var writeCount: Int { lock.withLock { writes } }
    func read(service: String, account: String, interaction: DesktopControlKeychainInteraction) throws -> Data? { nil }
    func write(_ data: Data, service: String, account: String, interaction: DesktopControlKeychainInteraction) throws {
        lock.withLock { writes += 1 }
        Issue.record("A missing retained key must not be replaced")
        throw AgentBridgeFailure.credentialUnavailable
    }
    func remove(service: String, account: String) throws { Issue.record("Existing credentials must not be removed") }
}
private actor LocalClusterInstalledControlFixture: AgentBridgeControlTransport {
    private(set) var operations: [String] = []
    func exchange(_ request: Data) async throws -> Data {
        let object = try #require(JSONSerialization.jsonObject(with: request) as? [String: Any])
        let operation = try #require(object["operation"] as? String)
        operations.append(operation)
        let result: [String: Any]
        switch operation {
        case "status": result = ["connections": [], "local_cluster_control_version": 1]
        case "local_cluster_binding": result = ["removed": false]
        case "local_cluster_runtime_status":
            result = ["installed": true, "running": true, "kubernetes_available": true, "enabled": true, "installer_active": false]
        case "local_cluster_status":
            let payload = try #require(object["payload"] as? [String: Any])
            let scope = try #require(payload["scope"] as? [String: Any])
            result = ["local_cluster": ["attempt_id": "22222222-2222-4222-8222-222222222222", "scope": scope,
                "operation": "install", "state": "installed", "action": "none"]]
        default:
            Issue.record("Unexpected helper mutation after installation key loss: \(operation)")
            throw AgentBridgeFailure.invalidRequest
        }
        return try JSONSerialization.data(withJSONObject: ["version": 1, "request_id": object["request_id"]!, "result": result])
    }
}

@MainActor private final class LocalClusterApprovalRegistration: AgentBridgeServiceRegistration {
    var status: SMAppService.Status = .requiresApproval
    func register() throws { Issue.record("Approval is required, not another registration") }
    func unregister() async throws { Issue.record("Unexpected unregister") }
}

@Suite @MainActor struct LocalClusterSetupManagerTests {
    @Test func handlerPresenceDoesNotAdvertiseQualifiedRuntimeOrAllowInstall() async throws {
        let http = LocalClusterPageHTTPFixture(), control = LocalClusterPageControlFixture()
        let manager = LocalClusterSetupManager(client: AgentBridgeControlClient(transport: control),
            hosted: LocalClusterEnrollmentClient(transport: http), helperControlVersion: { 1 }, configuration: { _ in .production },
            cookieReader: { _, _ in "personastack_session=fixture" }, csrfReader: { _ in "csrf-fixture" })
        let view = WKWebView()
        manager.register(view, appURL: DesktopEnvironmentConfiguration.production.appURL)
        let response = try await manager.apply(command("state"), view: view)
        let capability = try #require(response["capability"] as? [String: Any])
        #expect(capability["supported"] as? Bool == false)
        #expect(response["helper_supported"] as? Bool == false)
        #expect(response["api_readiness"] as? String == "unknown")
        #expect(response["cluster_id"] == nil)
        let scope = try #require(response["scope"] as? String)
        await #expect(throws: AgentBridgeFailure.runtimeUnsupported) { _ = try await manager.apply(command("install", scope: scope), view: view) }
        #expect(await control.operations == ["local_cluster_status", "local_cluster_runtime_status"])
        #expect(await http.calls == 2)
    }
    @Test func documentAndSessionInvalidationRejectOldActionsBeforeProtectedRead() async throws {
        let http = LocalClusterPageHTTPFixture(), control = LocalClusterPageControlFixture()
        let manager = LocalClusterSetupManager(client: AgentBridgeControlClient(transport: control),
            hosted: LocalClusterEnrollmentClient(transport: http), helperControlVersion: { 1 }, configuration: { _ in .production },
            cookieReader: { _, _ in "personastack_session=fixture" })
        let view = WKWebView()
        manager.register(view, appURL: DesktopEnvironmentConfiguration.production.appURL)
        let first = try await manager.apply(command("state"), view: view)
        let firstScope = try #require(first["scope"] as? String)
        manager.invalidate(view)
        await #expect(throws: AgentBridgeFailure.scopeChanged) { _ = try await manager.apply(command("continue", scope: firstScope), view: view) }
        #expect(await http.calls == 1)
        let second = try await manager.apply(command("state"), view: view)
        #expect(second["scope"] as? String != firstScope)
        manager.invalidateSession()
        let secondScope = try #require(second["scope"] as? String)
        await #expect(throws: AgentBridgeFailure.scopeChanged) { _ = try await manager.apply(command("start", scope: secondScope), view: view) }
        manager.unregister(view)
        await #expect(throws: AgentBridgeFailure.scopeChanged) { _ = try await manager.apply(command("state"), view: view) }
        #expect(await http.calls == 2)
    }
    @Test func recoveryActionsAreExplicitAndPreserveDormantInstallerGate() async throws {
        let http = LocalClusterPageHTTPFixture(), control = LocalClusterPageControlFixture(runtimeFailure: true)
        var settings = 0, updates = 0, details = 0
        let manager = LocalClusterSetupManager(client: AgentBridgeControlClient(transport: control),
            hosted: LocalClusterEnrollmentClient(transport: http), helperControlVersion: { 1 }, configuration: { _ in .production },
            cookieReader: { _, _ in "personastack_session=fixture" },
            openSettings: { settings += 1 }, openUpdates: { updates += 1 }, showDetails: { details += 1 })
        let view = WKWebView()
        manager.register(view, appURL: DesktopEnvironmentConfiguration.production.appURL)
        let first = try await manager.apply(command("state"), view: view)
        let native = try #require(first["native_status"] as? [String: Any])
        #expect(native["safe_reason"] as? String == "component_unverified")
        #expect(native["action"] as? String == "update_app")
        #expect(settings == 0 && updates == 0 && details == 0)
        let scope = try #require(first["scope"] as? String)
        for action in ["open_settings", "open_updates", "details"] { _ = try await manager.apply(command(action, scope: scope), view: view) }
        #expect(settings == 1 && updates == 1 && details == 1)
        #expect(await control.operations.allSatisfy { ["local_cluster_status", "local_cluster_runtime_status"].contains($0) })
        manager.invalidate(view)
        await #expect(throws: AgentBridgeFailure.scopeChanged) { _ = try await manager.apply(command("open_updates", scope: scope), view: view) }
        #expect(updates == 1)
    }
    @Test func missingKeyOnExistingRuntimeNeverRekeysOrCreatesAnotherTarget() async throws {
        let http = LocalClusterPageHTTPFixture(), transport = LocalClusterInstalledControlFixture()
        let client = AgentBridgeControlClient(transport: transport)
        let keychain = LocalClusterMissingKeychain()
        var credentialDetails = 0, genericDetails = 0
        let preferences = try #require(UserDefaults(suiteName: "LocalClusterMissingKey." + UUID().uuidString))
        let service = AgentBridgeService(registration: LocalClusterEnabledRegistration(), client: client, preferences: preferences,
            requireSignature: {}, clearDisabledPreference: {})
        let manager = LocalClusterSetupManager(client: client, hosted: LocalClusterEnrollmentClient(transport: http), service: service,
            qualifiedRuntime: true, keychain: keychain, requireSignature: {}, prepareBackgroundEnable: {}, approveEnvironment: { _ in },
            helperControlVersion: { 1 }, configuration: { _ in .production }, cookieReader: { _, _ in "personastack_session=fixture" },
            showDetails: { genericDetails += 1 }, showCredentialDetails: { credentialDetails += 1 })
        let view = WKWebView()
        manager.register(view, appURL: DesktopEnvironmentConfiguration.production.appURL)
        let first = try await manager.apply(command("state"), view: view)
        let scope = try #require(first["scope"] as? String)
        for action in ["install", "continue"] {
            let response = try await manager.apply(command(action, scope: scope), view: view)
            let native = try #require(response["native_status"] as? [String: Any])
            #expect(native["safe_reason"] as? String == "local_credentials_unavailable")
            #expect(native["action"] as? String == "details")
        }
        _ = try await manager.apply(command("details", scope: scope), view: view)
        #expect(credentialDetails == 1 && genericDetails == 0)
        #expect(keychain.writeCount == 0)
        #expect(await transport.operations.allSatisfy { ["status", "local_cluster_status", "local_cluster_runtime_status", "local_cluster_binding"].contains($0) })
        // The strict HTTP fixture permits only canonical GET. Prepare/redeem
        // would fail the fixture and cannot be hidden by this error assertion.
        #expect(await http.calls == 4)
    }
    @Test func legacyHelperCapabilityAbsenceNeverProbesNewOperations() async throws {
        let http = LocalClusterPageHTTPFixture(), control = LocalClusterPageControlFixture()
        let manager = LocalClusterSetupManager(client: AgentBridgeControlClient(transport: control), hosted: LocalClusterEnrollmentClient(transport: http),
            qualifiedRuntime: true, requireSignature: {}, helperControlVersion: { nil }, configuration: { _ in .production }, cookieReader: { _, _ in "personastack_session=fixture" })
        let view = WKWebView()
        manager.register(view, appURL: DesktopEnvironmentConfiguration.production.appURL)
        let response = try await manager.apply(command("state"), view: view)
        let native = try #require(response["native_status"] as? [String: Any])
        #expect((response["capability"] as? [String: Any])?["supported"] as? Bool == true)
        #expect(response["helper_supported"] as? Bool == false)
        #expect(native["safe_reason"] as? String == "helper_update_required")
        #expect(native["action"] as? String == "update_app")
        #expect(await control.operations.isEmpty)
    }
    @Test func backgroundApprovalHasExplicitSettingsGuidanceWithoutInstallRetry() async throws {
        let http = LocalClusterPageHTTPFixture(), transport = LocalClusterInstalledControlFixture()
        let client = AgentBridgeControlClient(transport: transport)
        let registration = LocalClusterApprovalRegistration()
        let preferences = try #require(UserDefaults(suiteName: "LocalClusterApproval." + UUID().uuidString))
        let service = AgentBridgeService(registration: registration, client: client, preferences: preferences, requireSignature: {}, clearDisabledPreference: {})
        var settings = 0
        let manager = LocalClusterSetupManager(client: client, hosted: LocalClusterEnrollmentClient(transport: http), service: service,
            qualifiedRuntime: true, keychain: LocalClusterMissingKeychain(), requireSignature: {}, prepareBackgroundEnable: {}, approveEnvironment: { _ in },
            helperControlVersion: { 1 }, configuration: { _ in .production }, cookieReader: { _, _ in "personastack_session=fixture" }, openSettings: { settings += 1 })
        let view = WKWebView(); manager.register(view, appURL: DesktopEnvironmentConfiguration.production.appURL)
        let initial = try await manager.apply(command("state"), view: view)
        let scope = try #require(initial["scope"] as? String)
        let result = try await manager.apply(command("install", scope: scope), view: view)
        let native = try #require(result["native_status"] as? [String: Any])
        #expect(native["safe_reason"] as? String == "background_approval_required")
        #expect(native["action"] as? String == "open_settings")
        #expect(settings == 0)
        _ = try await manager.apply(command("open_settings", scope: scope), view: view)
        #expect(settings == 1)
        registration.status = .enabled
        let rechecked = try await manager.apply(command("state", scope: scope), view: view)
        #expect((rechecked["native_status"] as? [String: Any])?["safe_reason"] as? String != "background_approval_required")
        #expect(await transport.operations.allSatisfy { ["local_cluster_status", "local_cluster_runtime_status", "local_cluster_binding"].contains($0) })
    }
    @Test(arguments: [false, true])
    func deniedAndRevokedBackgroundApprovalRequireExplicitSettings(revoked: Bool) async throws {
        let http = LocalClusterPageHTTPFixture(), transport = LocalClusterInstalledControlFixture()
        let client = AgentBridgeControlClient(transport: transport)
        let registration = LocalClusterApprovalRegistration()
        registration.status = revoked ? .enabled : .requiresApproval
        let preferences = try #require(UserDefaults(suiteName: "LocalClusterRevocation." + UUID().uuidString))
        preferences.set(true, forKey: AgentBridgeService.disabledKey)
        let service = AgentBridgeService(registration: registration, client: client, preferences: preferences, requireSignature: {}, clearDisabledPreference: {})
        let keychain = LocalClusterMissingKeychain()
        var settings = 0
        let manager = LocalClusterSetupManager(client: client, hosted: LocalClusterEnrollmentClient(transport: http), service: service,
            qualifiedRuntime: true, keychain: keychain, requireSignature: {}, prepareBackgroundEnable: {}, approveEnvironment: { _ in },
            helperControlVersion: { 1 }, configuration: { _ in .production }, cookieReader: { _, _ in "personastack_session=fixture" }, openSettings: { settings += 1 })
        let view = WKWebView(); manager.register(view, appURL: DesktopEnvironmentConfiguration.production.appURL)
        let initial = try await manager.apply(command("state"), view: view)
        let scope = try #require(initial["scope"] as? String)
        // macOS projects a disabled previously registered item as requiresApproval.
        registration.status = .requiresApproval
        for _ in 0..<2 {
            let blocked = try await manager.apply(command("repair", scope: scope), view: view)
            #expect((blocked["native_status"] as? [String: Any])?["safe_reason"] as? String == "background_approval_required")
            #expect((blocked["native_status"] as? [String: Any])?["action"] as? String == "open_settings")
            _ = try await manager.apply(command("state", scope: scope), view: view)
            #expect(settings == 0)
        }
        _ = try await manager.apply(command("open_settings", scope: scope), view: view)
        #expect(settings == 1)
        registration.status = .enabled
        let recovered = try await manager.apply(command("state", scope: scope), view: view)
        #expect((recovered["native_status"] as? [String: Any])?["safe_reason"] as? String != "background_approval_required")
        #expect(settings == 1 && keychain.writeCount == 0)
        #expect(preferences.bool(forKey: AgentBridgeService.disabledKey))
        #expect(await transport.operations.allSatisfy { ["local_cluster_status", "local_cluster_runtime_status", "local_cluster_binding"].contains($0) })
        #expect(await http.calls == 7)
    }

    private func command(_ action: String, scope: String = "") throws -> LocalClusterPageCommand {
        try LocalClusterPageCommand.parse(["version": "1", "action": action, "scope": scope])
    }
}

@MainActor private final class LocalClusterFreshRegistration: AgentBridgeServiceRegistration {
    var status: SMAppService.Status = .notRegistered
    private(set) var registrations = 0
    func register() throws { registrations += 1; status = .enabled }
    func unregister() async throws { Issue.record("Unexpected unregister") }
}
private final class LocalClusterFreshKeychain: DesktopControlKeychainAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    private var writes = 0
    var writeCount: Int { lock.withLock { writes } }
    func read(service: String, account: String, interaction: DesktopControlKeychainInteraction) throws -> Data? { lock.withLock { value } }
    func write(_ data: Data, service: String, account: String, interaction: DesktopControlKeychainInteraction) throws { lock.withLock { value = data; writes += 1 } }
    func remove(service: String, account: String) throws { Issue.record("Unexpected credential removal") }
}
private actor LocalClusterFreshControl: AgentBridgeControlTransport {
    private(set) var operations: [String] = []
    let removed: Bool
    var task: [String: Any]?
    init(removed: Bool) { self.removed = removed }
    func exchange(_ request: Data) async throws -> Data {
        let object = try #require(JSONSerialization.jsonObject(with: request) as? [String: Any])
        let operation = try #require(object["operation"] as? String)
        let payload = try #require(object["payload"] as? [String: Any])
        operations.append(operation)
        let result: [String: Any]
        switch operation {
        case "status": result = ["connections": [], "local_cluster_control_version": 1]
        case "local_cluster_runtime_status":
            var value: [String: Any] = ["installed": false, "running": false, "kubernetes_available": false, "enabled": false, "installer_active": task != nil]
            if removed { value["safe_reason"] = "local_data_removed"; value["action"] = "none" }
            result = value
        case "local_cluster_binding": result = ["removed": removed]
        case "local_cluster_status": result = ["local_cluster": task ?? ["state": "no_task", "action": "none"]]
        case "local_cluster_start":
            #expect(!removed)
            task = ["attempt_id": "22222222-2222-4222-8222-222222222222", "scope": try #require(payload["scope"]), "operation": "install", "state": "running", "action": "none"]
            result = ["local_cluster": try #require(task)]
        default: Issue.record("Unexpected fresh setup operation: \(operation)"); throw AgentBridgeFailure.invalidRequest
        }
        return try JSONSerialization.data(withJSONObject: ["version": 1, "request_id": object["request_id"]!, "result": result])
    }
}

@Suite @MainActor struct LocalClusterFreshInstallationTests {
    @Test(arguments: [false, true]) func helperAbsenceKeepsExplicitSetupReachableWithoutPassiveRegistration(removed: Bool) async throws {
        let http = LocalClusterPageHTTPFixture(), control = LocalClusterFreshControl(removed: removed)
        let registration = LocalClusterFreshRegistration()
        let keychain = LocalClusterFreshKeychain()
        let client = AgentBridgeControlClient(transport: control)
        let preferences = try #require(UserDefaults(suiteName: "LocalClusterFresh." + UUID().uuidString))
        let service = AgentBridgeService(registration: registration, client: client, preferences: preferences, requireSignature: {}, clearDisabledPreference: {})
        let requirements = try AgentBridgeLocalClusterRequirements(cpus: 4, memoryBytes: 8_589_934_592, diskBytes: 68_719_476_736, initialDownloadBytes: 870_442_303, minimumHostMemoryBytes: 17_179_869_184)
        let manager = LocalClusterSetupManager(client: client, hosted: LocalClusterEnrollmentClient(transport: http), service: service,
            qualifiedRuntime: true, keychain: keychain, requireSignature: {}, prepareBackgroundEnable: {}, approveEnvironment: { _ in },
            helperControlVersion: {
                guard registration.status == .enabled else { throw AgentBridgeFailure.serviceUnavailable }
                return 1
            }, requirementsReader: { requirements }, confirmSetupBudget: { _ in true }, physicalMemory: { UInt64.max }, processorCount: { 128 }, configuration: { _ in .production }, cookieReader: { _, _ in "personastack_session=fixture" })
        let view = WKWebView(); manager.register(view, appURL: DesktopEnvironmentConfiguration.production.appURL)
        let initial = try await manager.apply(LocalClusterPageCommand.parse(["version": "1", "action": "state", "scope": ""]), view: view)
        let capability = try #require(initial["capability"] as? [String: Any])
        let lifecycle = try #require(initial["lifecycle"] as? [String: Any])
        #expect(capability["supported"] as? Bool == true)
        #expect(initial["helper_supported"] as? Bool == false)
        #expect(lifecycle["available_actions"] as? [String] == ["install"])
        #expect(registration.registrations == 0)
        #expect(await control.operations.isEmpty)
        #expect(keychain.writeCount == 0)
        let scope = try #require(initial["scope"] as? String)
        let result = try await manager.apply(LocalClusterPageCommand.parse(["version": "1", "action": "install", "scope": scope]), view: view)
        #expect(registration.registrations == 1)
        let operations = await control.operations
        if removed {
            let state = try #require(result["lifecycle"] as? [String: Any])
            #expect(state["local"] as? String == "removed")
            #expect(state["available_actions"] as? [String] == ["new_setup"])
            #expect(keychain.writeCount == 0)
            #expect(!operations.contains("local_cluster_start"))
            registration.status = .notRegistered
            let unavailable = try await manager.apply(LocalClusterPageCommand.parse(["version": "1", "action": "state", "scope": scope]), view: view)
            let retained = try #require(unavailable["lifecycle"] as? [String: Any])
            #expect(retained["available_actions"] as? [String] == ["new_setup"])
            #expect(registration.registrations == 1)
        } else {
            #expect(keychain.writeCount == 1)
            #expect(operations.contains("local_cluster_start"))
        }
    }
}

@Suite @MainActor struct LocalClusterSetupBudgetTests {
    private final class Observation {
        var shown: [AgentBridgeLocalClusterRequirements] = []
        var details: [AgentBridgeLocalClusterRequirements] = []
        var cookie = "personastack_session=fixture"
        var failure: AgentBridgeFailure?
    }
    private struct Rig {
        let manager: LocalClusterSetupManager
        let view: WKWebView
        let keychain: LocalClusterFreshKeychain
        let control: LocalClusterFreshControl
        let observation: Observation
    }
    private func requirements() throws -> AgentBridgeLocalClusterRequirements {
        try AgentBridgeLocalClusterRequirements(cpus: 6, memoryBytes: 3_221_225_472, diskBytes: 12_884_901_888,
            initialDownloadBytes: 12_345, minimumHostMemoryBytes: 6_442_450_944)
    }
    private func rig(requirements: AgentBridgeLocalClusterRequirements?, consent: Bool, readerFailure: AgentBridgeFailure? = nil, memory: UInt64 = UInt64.max, cpus: Int = 128, changeCookie: Bool = false) throws -> Rig {
        let observation = Observation(); observation.failure = readerFailure
        let http = LocalClusterPageHTTPFixture(), control = LocalClusterFreshControl(removed: false)
        let registration = LocalClusterFreshRegistration(); registration.status = .enabled
        let keychain = LocalClusterFreshKeychain()
        let client = AgentBridgeControlClient(transport: control)
        let preferences = try #require(UserDefaults(suiteName: "LocalClusterBudget." + UUID().uuidString))
        let service = AgentBridgeService(registration: registration, client: client, preferences: preferences, requireSignature: {}, clearDisabledPreference: {})
        let manager = LocalClusterSetupManager(client: client, hosted: LocalClusterEnrollmentClient(transport: http), service: service,
            qualifiedRuntime: true, keychain: keychain, requireSignature: {}, prepareBackgroundEnable: {}, approveEnvironment: { _ in },
            helperControlVersion: { 1 }, requirementsReader: { if let failure = observation.failure { throw failure }; guard let requirements else { throw AgentBridgeFailure.runtimeUnsupported }; return requirements },
            confirmSetupBudget: { actual in observation.shown.append(actual); if changeCookie { observation.cookie = "personastack_session=changed" }; return consent },
            showSetupBudgetDetails: { observation.details.append($0) }, physicalMemory: { memory }, processorCount: { cpus },
            configuration: { _ in .production }, cookieReader: { _, _ in observation.cookie })
        let view = WKWebView(); manager.register(view, appURL: DesktopEnvironmentConfiguration.production.appURL)
        return Rig(manager: manager, view: view, keychain: keychain, control: control, observation: observation)
    }
    private func install(_ rig: Rig) async throws -> [String: Any] {
        let first = try await rig.manager.apply(LocalClusterPageCommand.parse(["version": "1", "action": "state", "scope": ""]), view: rig.view)
        let scope = try #require(first["scope"] as? String)
        return try await rig.manager.apply(LocalClusterPageCommand.parse(["version": "1", "action": "install", "scope": scope]), view: rig.view)
    }
    @Test func cancelledConsentHasNoKeyVMOrCloudEnrollmentEffects() async throws {
        let budget = try requirements(), rig = try rig(requirements: requirements(), consent: false)
        let result = try await install(rig)
        #expect(rig.observation.shown == [budget])
        #expect(rig.keychain.writeCount == 0)
        #expect(await rig.control.operations.contains("local_cluster_start") == false)
        #expect((result["native_status"] as? [String: Any])?["state"] as? String == "no_task")
    }
    @Test func acceptedConsentUsesActualRuntimeRequirementsBeforeKeyAndStart() async throws {
        let budget = try requirements(), rig = try rig(requirements: requirements(), consent: true)
        _ = try await install(rig)
        #expect(rig.observation.shown == [budget])
        #expect(rig.keychain.writeCount == 1)
        #expect(await rig.control.operations.contains("local_cluster_start"))
    }
    @Test func unavailableRequirementsFailClosedWithoutConsentOrEffects() async throws {
        let rig = try rig(requirements: nil, consent: true)
        let result = try await install(rig)
        let native = try #require(result["native_status"] as? [String: Any])
        #expect(native["safe_reason"] as? String == "helper_update_required")
        #expect(native["action"] as? String == "update_app")
        #expect(rig.observation.shown.isEmpty)
        #expect(rig.keychain.writeCount == 0)
        #expect(await rig.control.operations.contains("local_cluster_start") == false)
    }
    @Test(arguments: [AgentBridgeFailure.serviceUnavailable, .operationTimeout, .runtimeUnsupported])
    func requirementsCanRecoverByReadOnlyStateWithoutSetupEffects(failure: AgentBridgeFailure) async throws {
        let rig = try rig(requirements: requirements(), consent: true, readerFailure: failure)
        let blocked = try await install(rig)
        let native = try #require(blocked["native_status"] as? [String: Any])
        #expect(native["safe_reason"] as? String == (failure == .runtimeUnsupported ? "helper_update_required" : "status_unavailable"))
        #expect(native["action"] as? String == (failure == .runtimeUnsupported ? "update_app" : "retry"))
        #expect(rig.observation.shown.isEmpty)
        #expect(rig.keychain.writeCount == 0)
        #expect(await rig.control.operations.contains("local_cluster_start") == false)
        rig.observation.failure = nil
        let scope = try #require(blocked["scope"] as? String)
        let refreshed = try await rig.manager.apply(LocalClusterPageCommand.parse(["version": "1", "action": "state", "scope": scope]), view: rig.view)
        #expect((refreshed["lifecycle"] as? [String: Any])?["available_actions"] as? [String] == ["install"])
        #expect(rig.observation.shown.isEmpty)
        #expect(rig.keychain.writeCount == 0)
        #expect(await rig.control.operations.contains("local_cluster_start") == false)
    }
    @Test(arguments: [false, true]) func knownInsufficientHostCannotOfferOrStartInstall(cpuTooSmall: Bool) async throws {
        let budget = try requirements()
        let rig = try rig(requirements: budget, consent: true, memory: cpuTooSmall ? UInt64.max : UInt64(budget.minimumHostMemoryBytes - 1), cpus: cpuTooSmall ? budget.cpus - 1 : 128)
        let result = try await install(rig)
        let native = try #require(result["native_status"] as? [String: Any])
        #expect(native["safe_reason"] as? String == "unsupported_host")
        #expect(native["action"] as? String == "details")
        #expect((result["lifecycle"] as? [String: Any])?["available_actions"] as? [String] == [])
        #expect(rig.observation.shown.isEmpty)
        #expect(rig.keychain.writeCount == 0)
        #expect(await rig.control.operations.contains("local_cluster_start") == false)
    }
    @Test func cookieChangeDuringConsentCannotAuthorizeSetupEffects() async throws {
        let rig = try rig(requirements: requirements(), consent: true, changeCookie: true)
        await #expect(throws: AgentBridgeFailure.scopeChanged) { _ = try await install(rig) }
        #expect(rig.keychain.writeCount == 0)
        #expect(await rig.control.operations.contains("local_cluster_start") == false)
    }
    @Test func disclosureUsesRuntimeBudgetAndExplainsBackgroundBehavior() throws {
        let copy = LocalClusterSetupManager.setupBudgetMessage(try requirements())
        #expect(copy.contains("Virtual CPUs: 6"))
        #expect(copy.contains("Allocated RAM: 3 GiB"))
        #expect(copy.contains("Sparse virtual disk maximum: 12 GiB"))
        #expect(copy.contains("Minimum physical RAM: 6 GiB"))
        #expect(copy.contains("Provider images require additional"))
        #expect(copy.contains("quit PersonaStack or sign out of the app"))
        #expect(copy.contains("awake, connected to the network, and logged in to macOS"))
        #expect(copy.contains("Stop in Agents on This Mac"))
        #expect(copy.contains("retain its files"))
    }
}

private actor LocalClusterOccupiedControl: AgentBridgeControlTransport {
    private(set) var operations: [String] = []
    private var owner: [String: String]
    let removed: Bool
    let taskOccupied: Bool
    init(foreignField: String, removed: Bool = false, taskOccupied: Bool = false) {
        owner = ["app_origin": "https://my.personastack.ai", "account_id": "user-a", "workspace_id": "ws-a"]
        owner[foreignField] = "private-existing-owner"
        self.removed = removed; self.taskOccupied = taskOccupied
    }
    func returnToOwningScope() {
        owner = ["app_origin": "https://my.personastack.ai", "account_id": "user-a", "workspace_id": "ws-a"]
    }
    func exchange(_ request: Data) async throws -> Data {
        let object = try #require(JSONSerialization.jsonObject(with: request) as? [String: Any])
        let operation = try #require(object["operation"] as? String)
        let payload = try #require(object["payload"] as? [String: Any])
        operations.append(operation)
        let result: [String: Any]
        switch operation {
        case "local_cluster_status":
            if taskOccupied { throw AgentBridgeFailure.runtimeOccupied }
            result = ["local_cluster": ["state": "no_task", "action": "none"]]
        case "local_cluster_runtime_status":
            var value: [String: Any] = ["installed": !removed, "running": !removed,
                "kubernetes_available": !removed, "enabled": !removed, "installer_active": false]
            if removed { value["safe_reason"] = "local_data_removed"; value["action"] = "none" }
            result = value
        case "local_cluster_binding":
            let scope = try #require(payload["scope"] as? [String: String])
            guard owner.allSatisfy({ scope[$0.key] == $0.value }) else { throw AgentBridgeFailure.runtimeOccupied }
            result = ["removed": removed]
        default:
            Issue.record("Occupied reads must not mutate helper state: \(operation)")
            throw AgentBridgeFailure.invalidRequest
        }
        return try JSONSerialization.data(withJSONObject: ["version": 1, "request_id": object["request_id"]!, "result": result])
    }
}
private final class LocalClusterOccupiedKeychain: DesktopControlKeychainAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private var writes = 0
    var readCount: Int { lock.withLock { reads } }
    var writeCount: Int { lock.withLock { writes } }
    func read(service: String, account: String, interaction: DesktopControlKeychainInteraction) throws -> Data? {
        lock.withLock { reads += 1 }
        return Data(repeating: 7, count: 32)
    }
    func write(_ data: Data, service: String, account: String, interaction: DesktopControlKeychainInteraction) throws {
        lock.withLock { writes += 1 }
        Issue.record("Occupied reads must not write a key or custody")
    }
    func remove(service: String, account: String) throws { Issue.record("Occupied reads must not remove credentials") }
}

@Suite @MainActor struct LocalClusterOccupiedStateTests {
    private func state(_ manager: LocalClusterSetupManager, _ view: WKWebView, scope: String = "") async throws -> [String: Any] {
        try await manager.apply(LocalClusterPageCommand.parse(["version": "1", "action": "state", "scope": scope]), view: view)
    }
    private func manager(_ control: LocalClusterOccupiedControl, keychain: LocalClusterOccupiedKeychain,
                         http: LocalClusterPageHTTPFixture) -> (LocalClusterSetupManager, WKWebView) {
        let manager = LocalClusterSetupManager(client: AgentBridgeControlClient(transport: control),
            hosted: LocalClusterEnrollmentClient(transport: http), qualifiedRuntime: true, keychain: keychain,
            requireSignature: {}, helperControlVersion: { 1 }, configuration: { _ in .production },
            cookieReader: { _, _ in "personastack_session=fixture" })
        let view = WKWebView(); manager.register(view, appURL: DesktopEnvironmentConfiguration.production.appURL)
        return (manager, view)
    }
    @Test(arguments: ["account_id", "workspace_id", "app_origin"])
    func occupiedBindingIsReadOnlyPrivateAndClearsOnOwningObservation(foreignField: String) async throws {
        let control = LocalClusterOccupiedControl(foreignField: foreignField), keychain = LocalClusterOccupiedKeychain()
        let http = LocalClusterPageHTTPFixture(), (manager, view) = manager(control, keychain: keychain, http: http)
        let occupied = try await state(manager, view)
        let native = try #require(occupied["native_status"] as? [String: Any])
        #expect(native["state"] as? String == "unavailable")
        #expect(native["safe_reason"] as? String == "runtime_occupied")
        #expect(native["action"] as? String == "none")
        #expect(occupied["api_readiness"] as? String == "unknown")
        #expect(occupied["cluster_id"] == nil)
        let lifecycle = try #require(occupied["lifecycle"] as? [String: Any])
        #expect(lifecycle["available_actions"] as? [String] == [])
        #expect(lifecycle["cloud"] as? String == "unknown")
        #expect(lifecycle["local"] as? String == "unknown")
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: occupied), as: UTF8.self)
        for privateField in ["private-existing-owner", "user-a", "ws-a", "https://my.personastack.ai", "installation_id", "integration_id", "setup_manifest"] {
            #expect(!encoded.contains(privateField))
        }
        #expect(keychain.readCount == 0 && keychain.writeCount == 0)
        #expect(await control.operations == ["local_cluster_status", "local_cluster_runtime_status", "local_cluster_binding"])
        #expect(await http.calls == 1)
        await control.returnToOwningScope()
        let refreshed = try await state(manager, view, scope: #require(occupied["scope"] as? String))
        #expect((refreshed["native_status"] as? [String: Any])?["safe_reason"] == nil)
        #expect((refreshed["lifecycle"] as? [String: Any])?["available_actions"] as? [String] == ["remove", "stop", "repair"])
        #expect(keychain.writeCount == 0)
        #expect(await http.calls == 2)
    }
    @Test func verifiedRemovedForeignBindingStillOffersOnlyExplicitNewSetup() async throws {
        let control = LocalClusterOccupiedControl(foreignField: "account_id", removed: true, taskOccupied: true)
        let keychain = LocalClusterOccupiedKeychain(), http = LocalClusterPageHTTPFixture()
        let (manager, view) = manager(control, keychain: keychain, http: http)
        let response = try await state(manager, view)
        let native = try #require(response["native_status"] as? [String: Any])
        #expect(native["safe_reason"] as? String == "local_data_removed")
        #expect(native["operation"] as? String == "remove")
        #expect(response["cluster_id"] == nil)
        #expect(response["api_readiness"] as? String == "unknown")
        #expect((response["lifecycle"] as? [String: Any])?["available_actions"] as? [String] == ["new_setup"])
        #expect(keychain.writeCount == 0)
        #expect(await control.operations == ["local_cluster_status", "local_cluster_runtime_status", "local_cluster_binding"])
        #expect(await http.calls == 1)
    }
    @Test func oldTaskOccupiedErrorDoesNotOverrideCurrentOwningBinding() async throws {
        let control = LocalClusterOccupiedControl(foreignField: "account_id", taskOccupied: true)
        await control.returnToOwningScope()
        let keychain = LocalClusterOccupiedKeychain(), http = LocalClusterPageHTTPFixture()
        let (manager, view) = manager(control, keychain: keychain, http: http)
        let response = try await state(manager, view)
        #expect((response["native_status"] as? [String: Any])?["safe_reason"] == nil)
        #expect((response["lifecycle"] as? [String: Any])?["available_actions"] as? [String] == ["remove", "stop", "repair"])
        #expect(keychain.writeCount == 0)
    }
}
