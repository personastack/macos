import Foundation
import PersonaStackCore
import Testing

@Suite struct LocalClusterLifecycleTests {
    private let fingerprint = String(repeating: "a", count: 64)
    @Test func bindingAndOldIdentityGuardsRejectRecreatingRemovedTargets() throws {
        let old = try LocalClusterTargetBinding(integrationID: "cluster-old", installationID: fingerprint)
        let status = try JSONDecoder().decode(LocalClusterBindingStatus.self, from: JSONSerialization.data(withJSONObject: [
            "removed": false, "previous_removed_binding": ["integration_id": old.integrationID, "installation_id": old.installationID]]))
        try status.requireConsistent()
        #expect(throws: AgentBridgeFailure.credentialUnavailable) { try status.requireFreshIdentity(old.installationID) }
        let reusedID = try LocalClusterTargetBinding(integrationID: old.integrationID, installationID: String(repeating: "b", count: 64))
        #expect(throws: AgentBridgeFailure.scopeChanged) { try status.requireFreshTarget(reusedID) }
        let fresh = try LocalClusterTargetBinding(integrationID: "cluster-new", installationID: String(repeating: "b", count: 64))
        try status.requireFreshTarget(fresh)
        for invalid in ["", "../path", "id with space", "id\nvalue"] {
            #expect(throws: AgentBridgeFailure.invalidRequest) { _ = try LocalClusterTargetBinding(integrationID: invalid, installationID: fingerprint) }
        }
    }
    @Test func lifecycleProjectionKeepsCloudAndLocalOutcomesIndependent() {
        var lifecycle = LocalClusterLifecycle()
        lifecycle.cloud = .retirementPending
        lifecycle.local = .removed
        lifecycle.failure = .retirementUnconfirmed
        lifecycle.availableActions = ["new_setup"]
        let page = lifecycle.pageValue
        #expect(page["cloud"] as? String == "retirement_pending")
        #expect(page["local"] as? String == "removed")
        #expect(page["failure"] as? String == "retirement_unconfirmed")
        #expect(page["binding"] == nil)
        #expect(page["integration_id"] == nil)
        #expect(page["installation_id"] == nil)
    }
    @Test func statusAndRetirementReadbackRequireExactBinding() throws {
        let binding = try LocalClusterTargetBinding(integrationID: "cluster-own", installationID: fingerprint)
        let changed = try JSONDecoder().decode(LocalClusterStatusChange.self, from: JSONSerialization.data(withJSONObject: [
            "cluster_id": "cluster-own", "installation_id": fingerprint, "status": "disabled", "config_version": 8]))
        try changed.require(binding: binding, status: "disabled", previousVersion: 7)
        #expect(throws: AgentBridgeFailure.scopeChanged) { try changed.require(binding: binding, status: "disabled", previousVersion: 8) }
        #expect(throws: AgentBridgeFailure.scopeChanged) { try changed.require(binding: binding, status: "active", previousVersion: 7) }
        let pending = try JSONDecoder().decode(LocalClusterRetirement.self, from: JSONSerialization.data(withJSONObject: [
            "cluster_id": "cluster-own", "installation_id": fingerprint, "retirement_state": "retiring"]))
        try pending.require(binding: binding)
        #expect(pending.state == .retiring)
        let other = try LocalClusterTargetBinding(integrationID: "cluster-foreign", installationID: fingerprint)
        #expect(throws: AgentBridgeFailure.scopeChanged) { try pending.require(binding: other) }
    }
}
