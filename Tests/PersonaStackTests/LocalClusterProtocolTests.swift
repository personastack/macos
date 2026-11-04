import Foundation
import PersonaStackCore
import Testing

@Suite struct LocalClusterProtocolTests {
    private let scope = LocalClusterScope(appOrigin: "https://app.example", accountID: "user-a", workspaceID: "ws-a",
        documentID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)

    @Test func pageBoundaryAcceptsOnlyFiniteIntent() throws {
        for action in LocalClusterPageCommand.Action.allCases {
            _ = try LocalClusterPageCommand.parse(["version": "1", "action": action.rawValue, "scope": "native-scope"])
        }
        for extra in ["url", "manifest", "kubeconfig", "command", "path", "account_id", "workspace_id", "public_key", "sign_bytes", "attempt_id"] {
            #expect(throws: AgentBridgeFailure.invalidRequest) {
                _ = try LocalClusterPageCommand.parse(["version": "1", "action": "install", "scope": "scope", extra: "untrusted"])
            }
        }
        for action in ["prepare", "redeem", "apply", "sign", "shell", "erase"] {
            #expect(throws: AgentBridgeFailure.invalidRequest) { _ = try LocalClusterPageCommand.parse(["version": "1", "action": action, "scope": "scope"]) }
        }
        #expect(throws: AgentBridgeFailure.invalidRequest) { _ = try LocalClusterPageCommand.parse(["version": 1, "action": "state", "scope": ""]) }
        #expect(throws: AgentBridgeFailure.invalidRequest) { _ = try LocalClusterPageCommand.parse(["version": "1", "action": "install", "scope": ""]) }
    }

    @Test func sameOwnerCanObserveAfterReopenButForeignOwnerCannot() throws {
        let snapshot = try decodeSnapshot()
        let reopened = LocalClusterScope(appOrigin: scope.appOrigin, accountID: scope.accountID, workspaceID: scope.workspaceID, documentID: UUID())
        try snapshot.requireOwner(reopened)
        let foreign = LocalClusterScope(appOrigin: scope.appOrigin, accountID: "other-user", workspaceID: scope.workspaceID, documentID: UUID())
        #expect(throws: AgentBridgeFailure.scopeChanged) { try snapshot.requireOwner(foreign) }
        #expect(throws: AgentBridgeFailure.scopeChanged) { try snapshot.requireOwner(scope, attempt: UUID()) }
    }

    @Test func snapshotProjectionExcludesNativeAuthorityAndRawText() throws {
        let value = try decodeSnapshot(extra: ["safe_message": "/private/secret path", "credential": "token"]).pageValue
        #expect(value["scope"] == nil)
        #expect(value["safe_message"] == nil)
        #expect(value["credential"] == nil)
        #expect(value["state"] as? String == "installed")
        #expect(value["operation"] as? String == "install")
    }

    @Test func noTaskNeverClaimsInstallation() throws {
        let snapshot = try JSONDecoder().decode(LocalClusterSnapshot.self, from: Data(#"{"state":"no_task","action":"none"}"#.utf8))
        try snapshot.requireOwner(scope)
        #expect(snapshot.attemptID == nil)
        #expect(snapshot.pageValue["state"] as? String == "no_task")
        #expect(throws: AgentBridgeFailure.scopeChanged) { try snapshot.requireOwner(scope, attempt: UUID()) }
    }

    @Test func malformedSnapshotFailsClosed() throws {
        #expect(throws: (any Error).self) { _ = try decodeSnapshot(extra: ["state": "ready"]) }
        #expect(throws: (any Error).self) { _ = try decodeSnapshot(extra: ["safe_reason": "raw_error"]) }
        let negative = try decodeSnapshot(extra: ["progress": ["stage": "downloading", "completed_bytes": -1, "total_bytes": 20]])
        #expect(throws: AgentBridgeFailure.invalidRequest) { try negative.requireOwner(scope) }
    }

    @Test func remediationVocabularyKeepsUpdatesAndDataReviewSeparateFromRetry() throws {
        for (reason, action) in [("component_unverified", "update_app"), ("local_data_unavailable", "details"), ("status_unavailable", "retry")] {
            let snapshot = try decodeSnapshot(extra: ["state": "failed", "safe_reason": reason, "action": action])
            #expect(snapshot.pageValue["safe_reason"] as? String == reason)
            #expect(snapshot.pageValue["action"] as? String == action)
        }
    }

    @Test func installationKeyCreationRequiresConfirmedAbsentIdleRuntime() throws {
        func runtime(_ fields: [String: Any]) throws -> LocalClusterRuntimeStatus {
            var value: [String: Any] = ["installed": false, "running": false, "kubernetes_available": false, "enabled": false, "installer_active": false]
            value.merge(fields) { _, new in new }
            return try JSONDecoder().decode(LocalClusterRuntimeStatus.self, from: JSONSerialization.data(withJSONObject: value))
        }
        let absent = try runtime([:])
        try absent.requireIdleKnownState()
        #expect(absent.permitsInstallationKeyCreation)
        let removed = try runtime(["safe_reason": "local_data_removed"])
        #expect(removed.verifiedRemoved)
        #expect(!removed.permitsInstallationKeyCreation)
        let uncertainRemoval = try runtime(["safe_reason": "local_data_removed", "running": true])
        #expect(!uncertainRemoval.verifiedRemoved)
        let stoppedIntent = try runtime(["installed": true, "running": true, "kubernetes_available": true, "enabled": false])
        #expect(!stoppedIntent.isRunningReady)
        for fields: [String: Any] in [["installed": true], ["installed": true, "running": true, "kubernetes_available": true]] {
            let retained = try runtime(fields)
            try retained.requireIdleKnownState()
            #expect(!retained.permitsInstallationKeyCreation)
        }
        for fields: [String: Any] in [["installer_active": true], ["running": true], ["kubernetes_available": true], ["safe_reason": "local_data_unavailable"], ["safe_reason": "status_unavailable"]] {
            let unknown = try runtime(fields)
            #expect(!unknown.permitsInstallationKeyCreation)
            #expect(throws: (any Error).self) { try unknown.requireIdleKnownState() }
        }
    }

    @Test func proofMatchesProducerTwelveLineContract() throws {
        let receipt = try decodeReceipt()
        let proof = try receipt.proof(scope: scope, publicKey: publicKey, installation: "fingerprint", name: "This Mac", now: Date(timeIntervalSince1970: 100))
        let expected = ["personastack:kubernetes-desktop-setup:v1", "setup-a", "user-a", "ws-a", "https://app.example",
            scope.documentID, publicKey, "create", "", "0", "This Mac", "200"].joined(separator: "\n")
        #expect(String(data: proof, encoding: .utf8) == expected)
        #expect(proof.last != 10)
    }

    @Test func createProofSignsTheIssuedCanonicalAvailableName() throws {
        let receipt = try decodeReceipt(extra: ["name": "This Mac (2)"])
        let proof = try receipt.proof(scope: scope, publicKey: publicKey, installation: "fingerprint", name: "This Mac", now: Date(timeIntervalSince1970: 100))
        let expected = ["personastack:kubernetes-desktop-setup:v1", "setup-a", "user-a", "ws-a", "https://app.example",
            scope.documentID, publicKey, "create", "", "0", "This Mac (2)", "200"].joined(separator: "\n")
        #expect(String(data: proof, encoding: .utf8) == expected)
        #expect(proof.last != 10)
    }
    @Test func chosenReceiptNameMustBePresentAndValidBeforeSigning() throws {
        for name in ["", " This Mac", "This Mac ", "This\nMac", "This\rMac", "This\0Mac", String(repeating: "a", count: 121), String(repeating: "é", count: 61)] {
            let receipt = try decodeReceipt(extra: ["name": name])
            #expect(throws: (any Error).self) { _ = try receipt.proof(scope: scope, publicKey: publicKey, installation: "fingerprint", name: "This Mac", now: Date(timeIntervalSince1970: 100)) }
        }
        #expect(throws: (any Error).self) { _ = try decodeReceipt(extra: ["name": NSNull()]) }
        let receipt = try decodeReceipt()
        let fields: [String: Any] = ["setup_id": receipt.setupID, "expires_at": receipt.expiresAt, "user_id": receipt.userID, "workspace_id": receipt.workspaceID,
            "app_origin": receipt.appOrigin, "document_id": receipt.documentID, "installation_public_key": receipt.installationPublicKey,
            "installation_id": receipt.installationID, "operation": receipt.operation]
        #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(LocalClusterSetupReceipt.self, from: JSONSerialization.data(withJSONObject: fields)) }
    }

    @Test func rotationProofPinsExistingTargetAndVersion() throws {
        let receipt = try decodeReceipt(extra: ["operation": "rotate", "integration_id": "cluster-a", "expected_config_version": 9])
        let proof = try receipt.proof(scope: scope, publicKey: publicKey, installation: "fingerprint", name: "This Mac", operation: "rotate", integrationID: "cluster-a", configVersion: 9, now: Date(timeIntervalSince1970: 100))
        #expect(String(data: proof, encoding: .utf8)?.contains("\nrotate\ncluster-a\n9\nThis Mac\n") == true)
        #expect(throws: AgentBridgeFailure.scopeChanged) { _ = try receipt.proof(scope: scope, publicKey: publicKey, installation: "fingerprint", name: "This Mac", operation: "rotate", integrationID: "cluster-a", configVersion: 10, now: Date(timeIntervalSince1970: 100)) }
        #expect(throws: AgentBridgeFailure.scopeChanged) { _ = try receipt.proof(scope: scope, publicKey: publicKey, installation: "fingerprint", name: "This Mac (2)", operation: "rotate", integrationID: "cluster-a", configVersion: 9, now: Date(timeIntervalSince1970: 100)) }
        #expect(throws: AgentBridgeFailure.scopeChanged) { _ = try receipt.proof(scope: scope, publicKey: publicKey, installation: "fingerprint", name: "This Mac", now: Date(timeIntervalSince1970: 100)) }
    }

    @Test func staleOrForeignReceiptsCannotBeSigned() throws {
        for fields: [String: Any] in [["workspace_id": "other"], ["user_id": "other"], ["document_id": UUID().uuidString],
                                    ["app_origin": "https://other.example"], ["installation_id": "other"], ["operation": "rotate"],
                                    ["setup_id": "injected\nfield"]] {
            let receipt = try decodeReceipt(extra: fields)
            #expect(throws: (any Error).self) { _ = try receipt.proof(scope: scope, publicKey: publicKey, installation: "fingerprint", name: "This Mac", now: Date(timeIntervalSince1970: 100)) }
        }
        let receipt = try decodeReceipt()
        #expect(throws: AgentBridgeFailure.scopeChanged) { _ = try receipt.proof(scope: scope, publicKey: publicKey, installation: "fingerprint", name: "This Mac", now: Date(timeIntervalSince1970: 201)) }
        #expect(throws: AgentBridgeFailure.scopeChanged) { _ = try receipt.proof(scope: scope, publicKey: publicKey, installation: "fingerprint", name: "This Mac", now: Date(timeIntervalSince1970: -101)) }
    }

    @Test func canonicalReadbackSelectsExactInstallationAndRejectsDuplicates() throws {
        let cluster: [String: Any] = ["cluster_id": "cluster-a", "name": "This Mac", "management": ["kind": "macos_app", "installation_id": "own"], "status": "active", "config_version": 1, "connection_state": "connected", "agent_connected": true]
        var object: [String: Any] = ["user_id": "user-a", "workspace_id": "ws-a", "app_origin": scope.appOrigin, "clusters": [cluster]]
        var owner = try JSONDecoder().decode(LocalClusterAuthenticatedScope.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(try owner.ownedCluster(installationID: "own")?.clusterID == "cluster-a")
        #expect(try owner.ownedCluster(installationID: "foreign") == nil)
        #expect(try owner.ownedCluster(installationID: "own")?.capabilitiesReady == nil)
        object["clusters"] = [cluster, cluster]
        owner = try JSONDecoder().decode(LocalClusterAuthenticatedScope.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: AgentBridgeFailure.scopeChanged) { _ = try owner.ownedCluster(installationID: "own") }
    }

    private var publicKey: String { Data(repeating: 7, count: 32).base64EncodedString() }
    private func decodeReceipt(extra: [String: Any] = [:]) throws -> LocalClusterSetupReceipt {
        var fields: [String: Any] = ["setup_id": "setup-a", "expires_at": "1970-01-01T00:03:20Z", "user_id": "user-a", "workspace_id": "ws-a",
            "app_origin": scope.appOrigin, "document_id": scope.documentID, "installation_public_key": publicKey,
            "installation_id": "fingerprint", "operation": "create", "name": "This Mac"]
        fields.merge(extra) { _, new in new }
        return try JSONDecoder().decode(LocalClusterSetupReceipt.self, from: JSONSerialization.data(withJSONObject: fields))
    }
    private func decodeSnapshot(extra: [String: Any] = [:]) throws -> LocalClusterSnapshot {
        let nativeScope = try JSONSerialization.jsonObject(with: JSONEncoder().encode(scope))
        var fields: [String: Any] = ["attempt_id": "22222222-2222-4222-8222-222222222222", "scope": nativeScope,
            "state": "installed", "operation": "install", "action": "none", "progress": ["stage": "completed", "completed_bytes": 10, "total_bytes": 10]]
        fields.merge(extra) { _, new in new }
        return try JSONDecoder().decode(LocalClusterSnapshot.self, from: JSONSerialization.data(withJSONObject: fields))
    }
}
