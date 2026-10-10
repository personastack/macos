import Foundation
import PersonaStackCore
import Testing
@testable import PersonaStack

actor AgentBridgeTargetFixture: AgentBridgeHostedTransport {
    var inventoryGeneration = 7
    var runtimeKind = "hermes"
    var inventoryPending = false
    var staleFirstSave = false
    var wrongWorkspace = false
    var selectedOtherProfile = false
    var inventoryAlwaysEmpty = false
    private var selected = false
    private(set) var operations: [String] = []
    private(set) var saves: [Int] = []
    func configure(pending: Bool = false, stale: Bool = false, foreign: Bool = false, otherProfile: Bool = false, empty: Bool = false, runtime: String = "hermes") {
        runtimeKind = runtime
        inventoryPending = pending; staleFirstSave = stale; wrongWorkspace = foreign; selectedOtherProfile = otherProfile; inventoryAlwaysEmpty = empty
    }
    func isSelected() -> Bool { selected }
    private func selection() -> [String: Any] {
        ["account_candidate_id": "rt_account_a", "profile_candidate_id": selectedOtherProfile ? "rt_profile_other" : "rt_profile_a",
         "runtime_kind": runtimeKind, "selection_revision": 1, "validated_generation": inventoryGeneration, "state": "target_selected"]
    }
    func request(_ request: URLRequest) throws -> (Data, Int) {
        let method = request.httpMethod ?? "GET", path = request.url!.path
        operations.append(method + " " + path)
        #expect(request.url?.host == "my.personastack.ai")
        #expect(request.value(forHTTPHeaderField: "Cookie") == "personastack_session=fixture")
        #expect(!request.httpShouldHandleCookies)
        if method == "POST" {
            #expect(path == "/user/personas/external-runtime/target-selection")
            #expect(request.value(forHTTPHeaderField: "X-CSRF-Token") == "csrf-fixture")
            #expect(request.value(forHTTPHeaderField: "Origin") == "https://my.personastack.ai")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            #expect(Set(body.keys) == ["persona_id", "inventory_generation", "account_candidate_id", "profile_candidate_id"])
            #expect(body["persona_id"] as? String == "persona-a")
            #expect(body["account_candidate_id"] as? String == "rt_account_a")
            #expect(body["profile_candidate_id"] as? String == "rt_profile_a")
            let generation = try #require(body["inventory_generation"] as? Int)
            saves.append(generation)
            guard generation == inventoryGeneration else { throw AgentBridgeFailure.scopeChanged }
            if staleFirstSave { staleFirstSave = false; inventoryGeneration += 1; return (Data("{}".utf8), 409) }
            selected = true
            return (try JSONSerialization.data(withJSONObject: selection()), 200)
        }
        #expect(method == "GET" && path == "/user/personas/external-runtime")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.first(where: { $0.name == "persona_id" })?.value == "persona-a")
        var body: [String: Any] = ["workspace_id": wrongWorkspace ? "ws_22222222222222222222222222222222" : "ws_11111111111111111111111111111111",
            "persona_id": "persona-a", "connection_id": "conn-a", "connection_generation": 7, "client_kind": "macos_app",
            "readiness_status": selected ? "wakeable" : "target_selection_required", "run_lane_status": "idle"]
        if inventoryAlwaysEmpty { body["target_inventory"] = ["inventory_generation": inventoryGeneration] }
        else if inventoryPending {
            inventoryPending = false
            body["target_inventory"] = ["accounts": [["candidate_id": "rt_account_a"]]]
        }
        else {
            body["target_inventory"] = ["inventory_generation": inventoryGeneration, "accounts": [["candidate_id": "rt_account_a",
                "profiles": [["candidate_id": "rt_profile_a", "runtime_kind": runtimeKind]]]]]
        }
        body["target_selection"] = selected || selectedOtherProfile ? selection() : ["state": "target_selection_required"]
        return (try JSONSerialization.data(withJSONObject: body), 200)
    }
}

@Suite @MainActor struct AgentBridgeTargetSelectionTests {
    private let target = AgentBridgePreparedTarget(workspace: "ws_11111111111111111111111111111111", persona: "persona-a",
        account: "rt_account_a", profile: "rt_profile_a", runtime: .hermes)
    private let binding = AgentBridgeBindingKey(environmentID: "https://my.personastack.ai", connectionID: "conn-a")

    @Test func producerOmittedInventorySlicesAndUnselectedIdentityAreSafe() throws {
        for json in ["{}", "{\"inventory_generation\":7}", "{\"inventory_generation\":7,\"accounts\":[{\"candidate_id\":\"rt_account_a\"}]}"] {
            let inventory = try JSONDecoder().decode(AgentBridgeTargetInventory.self, from: Data(json.utf8))
            #expect(!inventory.matches(target))
        }
        let selection = try JSONDecoder().decode(AgentBridgeTargetSelection.self,
            from: Data("{\"state\":\"target_selection_required\"}".utf8))
        #expect(selection.isUnselected)
        #expect(!selection.isSelected(target, generation: 7))
        let invalid = try JSONDecoder().decode(AgentBridgeTargetSelection.self,
            from: Data("{\"state\":\"target_selected\"}".utf8))
        #expect(!invalid.isUnselected)
        #expect(!invalid.isSelected(target, generation: 7))
    }

    @Test func pendingInventorySelectionAndAuthoritativeReadbackUsePreparedIdentity() async throws {
        let fixture = AgentBridgeTargetFixture(); await fixture.configure(pending: true)
        let authority = AgentBridgeTargetSelectionAuthority(hosted: AgentBridgeHostedAuthority(transport: fixture), wait: {})
        try await authority.ensureSelected(configuration: .production, cookies: "personastack_session=fixture", csrf: "csrf-fixture",
            binding: binding, target: target, validate: {})
        #expect(await fixture.operations == ["GET /user/personas/external-runtime", "GET /user/personas/external-runtime",
            "POST /user/personas/external-runtime/target-selection", "GET /user/personas/external-runtime"])
        #expect(await fixture.saves == [7])
        #expect(await fixture.isSelected())
        // A retry uses authoritative selection without repeating either pairing or selection.
        try await authority.ensureSelected(configuration: .production, cookies: "personastack_session=fixture", csrf: "csrf-fixture",
            binding: binding, target: target, validate: {})
        #expect(await fixture.saves == [7])
    }

    @Test func staleInventoryRetryUsesFreshGenerationWithoutChangingPreparedProfile() async throws {
        let fixture = AgentBridgeTargetFixture(); await fixture.configure(stale: true)
        let authority = AgentBridgeTargetSelectionAuthority(hosted: AgentBridgeHostedAuthority(transport: fixture), wait: {})
        await #expect(throws: AgentBridgeFailure.scopeChanged) {
            try await authority.ensureSelected(configuration: .production, cookies: "personastack_session=fixture", csrf: "csrf-fixture",
                binding: binding, target: target, validate: {})
        }
        #expect(!(await fixture.isSelected()))
        try await authority.ensureSelected(configuration: .production, cookies: "personastack_session=fixture", csrf: "csrf-fixture",
            binding: binding, target: target, validate: {})
        #expect(await fixture.saves == [7, 8])
        #expect(await fixture.isSelected())
    }

    @Test func omittedEmptyInventoryNeverAuthorizesSelectionWrite() async {
        let fixture = AgentBridgeTargetFixture(); await fixture.configure(empty: true)
        let authority = AgentBridgeTargetSelectionAuthority(hosted: AgentBridgeHostedAuthority(transport: fixture), wait: {})
        await #expect(throws: AgentBridgeFailure.runtimeConflict) {
            try await authority.ensureSelected(configuration: .production, cookies: "personastack_session=fixture", csrf: "csrf-fixture",
                binding: binding, target: target, validate: {})
        }
        #expect(await fixture.saves.isEmpty)
        #expect(await fixture.operations.count == 120)
    }

    @Test func changedOwnerOrSelectedProfileHasZeroSelectionWrites() async {
        for foreign in [true, false] {
            let fixture = AgentBridgeTargetFixture(); await fixture.configure(foreign: foreign, otherProfile: !foreign)
            let authority = AgentBridgeTargetSelectionAuthority(hosted: AgentBridgeHostedAuthority(transport: fixture), wait: {})
            await #expect(throws: AgentBridgeFailure.scopeChanged) {
                try await authority.ensureSelected(configuration: .production, cookies: "personastack_session=fixture", csrf: "csrf-fixture",
                    binding: binding, target: target, validate: {})
            }
            #expect(await fixture.saves.isEmpty)
        }
    }

    @Test func changedDocumentAfterInventoryReadHasZeroSelectionWrites() async {
        let fixture = AgentBridgeTargetFixture()
        let authority = AgentBridgeTargetSelectionAuthority(hosted: AgentBridgeHostedAuthority(transport: fixture), wait: {})
        var reads = 0
        await #expect(throws: AgentBridgeFailure.scopeChanged) {
            try await authority.ensureSelected(configuration: .production, cookies: "personastack_session=fixture", csrf: "csrf-fixture",
                binding: binding, target: target, validate: { reads += 1; if reads == 2 { throw AgentBridgeFailure.scopeChanged } })
        }
        #expect(await fixture.saves.isEmpty)
    }
}
