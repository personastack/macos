import Foundation
import PersonaStackCore

struct AgentBridgePreparedTarget: Sendable {
    let workspace: String
    let persona: String
    let account: String
    let profile: String
    let runtime: AgentBridgeRuntime
}
struct AgentBridgeTargetInventory: Decodable, Sendable {
    struct Account: Decodable, Sendable {
        let candidate_id: String?
        let profiles: [Profile]
        private enum CodingKeys: String, CodingKey { case candidate_id, profiles }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            candidate_id = try values.decodeIfPresent(String.self, forKey: .candidate_id)
            profiles = try values.decodeIfPresent([Profile].self, forKey: .profiles) ?? []
        }
    }
    struct Profile: Decodable, Sendable { let candidate_id: String?; let runtime_kind: String? }
    let inventory_generation: Int?
    let accounts: [Account]
    private enum CodingKeys: String, CodingKey { case inventory_generation, accounts }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        inventory_generation = try values.decodeIfPresent(Int.self, forKey: .inventory_generation)
        accounts = try values.decodeIfPresent([Account].self, forKey: .accounts) ?? []
    }
    func matches(_ target: AgentBridgePreparedTarget) -> Bool {
        guard let generation = inventory_generation, generation > 0 else { return false }
        return accounts.contains { account in
            account.candidate_id == target.account && account.profiles.contains { $0.candidate_id == target.profile && $0.runtime_kind == target.runtime.rawValue }
        }
    }
}
struct AgentBridgeTargetSelection: Decodable, Sendable {
    let account_candidate_id: String?
    let profile_candidate_id: String?
    let runtime_kind: String?
    let selection_revision: Int?
    let validated_generation: Int?
    let state: String?
    var isUnselected: Bool {
        state == "target_selection_required" && (account_candidate_id ?? "").isEmpty &&
            (profile_candidate_id ?? "").isEmpty && (runtime_kind ?? "").isEmpty
    }
    func matches(_ target: AgentBridgePreparedTarget) -> Bool {
        account_candidate_id == target.account && profile_candidate_id == target.profile && runtime_kind == target.runtime.rawValue
    }
    func isSelected(_ target: AgentBridgePreparedTarget, generation: Int?) -> Bool {
        guard let generation, generation > 0, let revision = selection_revision, revision > 0 else { return false }
        return matches(target) && validated_generation == generation && state == "target_selected"
    }
}

/// Selects only the opaque profile authorized by native preparation. It never guesses an account.
@MainActor
struct AgentBridgeTargetSelectionAuthority {
    let hosted: AgentBridgeHostedAuthority
    var wait: @MainActor () async throws -> Void = { try await Task.sleep(for: .milliseconds(250)) }

    func ensureSelected(configuration: DesktopEnvironmentConfiguration, cookies: String, csrf: String,
                        binding: AgentBridgeBindingKey, target: AgentBridgePreparedTarget,
                        validate: @MainActor @Sendable () async throws -> Void) async throws {
        guard !csrf.isEmpty, csrf.utf8.count <= 512, !csrf.contains(where: { $0.isWhitespace }) else { throw AgentBridgeFailure.invalidRequest }
        for _ in 0..<120 {
            try await validate()
            let current = try await hosted.read(configuration: configuration, cookies: cookies, persona: target.persona)
            guard let generation = current.connectionGeneration else { throw AgentBridgeFailure.scopeChanged }
            try current.require(workspace: target.workspace, persona: target.persona, connection: binding.connectionID, generation: generation)
            try await validate()
            guard let inventory = current.targetInventory, inventory.matches(target), let inventoryGeneration = inventory.inventory_generation else { try await wait(); continue }
            if let selected = current.targetSelection {
                // A fresh user-selected different target is not a setup retry.
                guard selected.isUnselected || selected.matches(target) else { throw AgentBridgeFailure.scopeChanged }
                if selected.isSelected(target, generation: inventory.inventory_generation) { return }
            }
            let selection = try await save(configuration: configuration, cookies: cookies, csrf: csrf, target: target,
                                           inventoryGeneration: inventoryGeneration)
            guard selection.isSelected(target, generation: inventory.inventory_generation) else { throw AgentBridgeFailure.scopeChanged }
            try await validate()
            let after = try await hosted.read(configuration: configuration, cookies: cookies, persona: target.persona)
            try after.require(workspace: target.workspace, persona: target.persona, connection: binding.connectionID, generation: generation)
            try await validate()
            guard after.targetInventory?.matches(target) == true, let actualGeneration = after.targetInventory?.inventory_generation,
                  after.targetSelection?.isSelected(target, generation: actualGeneration) == true else { throw AgentBridgeFailure.scopeChanged }
            return
        }
        throw AgentBridgeFailure.runtimeConflict
    }

    private func save(configuration: DesktopEnvironmentConfiguration, cookies: String, csrf: String,
                      target: AgentBridgePreparedTarget, inventoryGeneration: Int) async throws -> AgentBridgeTargetSelection {
        var request = URLRequest(url: configuration.appURL.appendingPathComponent("user/personas/external-runtime/target-selection"))
        request.httpMethod = "POST"; request.httpShouldHandleCookies = false
        request.setValue(cookies, forHTTPHeaderField: "Cookie")
        request.setValue(configuration.appOrigin, forHTTPHeaderField: "Origin")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(csrf, forHTTPHeaderField: "X-CSRF-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["persona_id": target.persona,
            "inventory_generation": inventoryGeneration, "account_candidate_id": target.account, "profile_candidate_id": target.profile])
        let (data, status) = try await hosted.transport.request(request)
        guard status == 200 else { throw AgentBridgeFailure.scopeChanged }
        return try JSONDecoder().decode(AgentBridgeTargetSelection.self, from: data)
    }
}
