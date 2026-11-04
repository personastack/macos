import Foundation

/// The page can request an action. Native code supplies every authority field.
public struct LocalClusterPageCommand: Sendable {
    public enum Action: String, CaseIterable, Sendable { case state, install, cancel, `continue`, start, stop, details, repair, disconnect, reconnect, remove
        case newSetup = "new_setup"
        case openSettings = "open_settings", openUpdates = "open_updates"
    }
    public let action: Action
    public let scope: String
    public static func parse(_ body: Any) throws -> Self {
        guard let value = body as? [String: Any], Set(value.keys) == ["version", "action", "scope"],
              value["version"] as? String == "1", let raw = value["action"] as? String,
              let action = Action(rawValue: raw), let scope = value["scope"] as? String,
              scope.utf8.count <= 128, action == .state || !scope.isEmpty else {
            throw AgentBridgeFailure.invalidRequest
        }
        return Self(action: action, scope: scope)
    }
}

public struct LocalClusterScope: Codable, Equatable, Sendable {
    public let appOrigin: String
    public let accountID: String
    public let workspaceID: String
    public let documentID: String
    public init(appOrigin: String, accountID: String, workspaceID: String, documentID: UUID) {
        self.appOrigin = appOrigin; self.accountID = accountID; self.workspaceID = workspaceID
        self.documentID = documentID.uuidString.lowercased()
    }
    public func sameOwner(_ other: Self) -> Bool {
        appOrigin == other.appOrigin && accountID == other.accountID && workspaceID == other.workspaceID
    }
    enum CodingKeys: String, CodingKey {
        case appOrigin = "app_origin", accountID = "account_id", workspaceID = "workspace_id", documentID = "document_id"
    }
    public var controlValue: AgentBridgeValue {
        .object(["app_origin": .string(appOrigin), "account_id": .string(accountID),
                 "workspace_id": .string(workspaceID), "document_id": .string(documentID)])
    }
}

public struct LocalClusterSnapshot: Decodable, Sendable {
    public enum State: String, Decodable, Sendable { case noTask = "no_task", running, cancelling, installed, completed, failed, cancelled }
    public enum Stage: String, Decodable, Sendable { case queued, downloading, verifying, extracting, starting, checking, completed }
    public enum Action: String, Decodable, Sendable { case none, retry, details, openSettings = "open_settings", updateApp = "update_app" }
    public enum Reason: String, Decodable, Sendable {
        case setupFailed = "setup_failed", artifactUnavailable = "artifact_unavailable", integrityFailed = "integrity_failed"
        case permissionRequired = "permission_required", resourceUnavailable = "resource_unavailable", unsupportedHost = "unsupported_host"
        case stopFailed = "stop_failed", stateChanged = "state_changed"
        case componentUnverified = "component_unverified", localDataUnavailable = "local_data_unavailable", statusUnavailable = "status_unavailable"
        case localDataRemoved = "local_data_removed", helperUpdateRequired = "helper_update_required"
    }
    public struct Progress: Decodable, Sendable { public let stage: Stage; public let completedBytes: Int64; public let totalBytes: Int64
        enum CodingKeys: String, CodingKey { case stage, completedBytes = "completed_bytes", totalBytes = "total_bytes" }
    }
    public enum Operation: String, Decodable, Sendable { case install, resume, stop, apply, remove
        case newSetup = "new_setup"
    }
    public let operation: Operation?
    public let attemptID: UUID?
    public let scope: LocalClusterScope?
    public let state: State
    public let progress: Progress?
    public let reason: Reason?
    public let action: Action
    public let updatedAt: String?
    enum CodingKeys: String, CodingKey {
        case attemptID = "attempt_id", operation, scope, state, progress, reason = "safe_reason", action, updatedAt = "updated_at"
    }
    public func requireOwner(_ expected: LocalClusterScope, attempt: UUID? = nil) throws {
        if state == .noTask {
            guard attempt == nil, attemptID == nil else { throw AgentBridgeFailure.scopeChanged }
            return
        }
        guard let scope, scope.sameOwner(expected), let attemptID,
              attempt == nil || attempt == attemptID else { throw AgentBridgeFailure.scopeChanged }
        if let progress {
            guard progress.completedBytes >= 0, progress.totalBytes >= 0,
                  progress.totalBytes == 0 || progress.completedBytes <= progress.totalBytes else { throw AgentBridgeFailure.invalidRequest }
        }
    }
    /// Never serialize the native scope or arbitrary helper text to JavaScript.
    public var pageValue: [String: Any] {
        var value: [String: Any] = ["state": state.rawValue, "action": action.rawValue]
        if let operation { value["operation"] = operation.rawValue }
        if let attemptID { value["attempt_id"] = attemptID.uuidString.lowercased() }
        if let progress { value["progress"] = ["stage": progress.stage.rawValue, "completed_bytes": progress.completedBytes, "total_bytes": progress.totalBytes] }
        if let reason { value["safe_reason"] = reason.rawValue }
        if let updatedAt, updatedAt.utf8.count <= 64 { value["updated_at"] = updatedAt }
        return value
    }
}
public struct LocalClusterControlResult: Decodable, Sendable { public let localCluster: LocalClusterSnapshot
    enum CodingKeys: String, CodingKey { case localCluster = "local_cluster" }
}
public struct LocalClusterRuntimeStatus: Decodable, Sendable {
    public let installed: Bool
    public let running: Bool
    public let kubernetesAvailable: Bool
    public let enabled: Bool
    public let installerActive: Bool
    public let reason: LocalClusterSnapshot.Reason?
    public let action: LocalClusterSnapshot.Action?
    public var isRunningReady: Bool {
        installed && running && kubernetesAvailable && enabled && !installerActive && reason == nil
    }
    public var verifiedRemoved: Bool {
        reason == .localDataRemoved && !installed && !running && !kubernetesAvailable && !enabled && !installerActive
    }
    public var permitsInstallationKeyCreation: Bool {
        !installed && !running && !kubernetesAvailable && !installerActive && reason == nil
    }
    public func requireIdleKnownState() throws {
        guard !installerActive else { throw AgentBridgeFailure.busy }
        guard reason == nil, installed || (!running && !kubernetesAvailable), !kubernetesAvailable || running else {
            throw AgentBridgeFailure.runtimeUnsupported
        }
    }
    enum CodingKeys: String, CodingKey { case installed, running, kubernetesAvailable = "kubernetes_available", enabled, installerActive = "installer_active", reason = "safe_reason", action }
}

public struct LocalClusterAuthenticatedScope: Decodable, Equatable, Sendable {
    public struct Cluster: Decodable, Equatable, Sendable {
        public struct Management: Decodable, Equatable, Sendable {
            public let kind: String
            public let installationID: String?
            enum CodingKeys: String, CodingKey { case kind, installationID = "installation_id" }
        }
        public let clusterID: String
        public let name: String
        public let management: Management
        public let connectionState: String
        public let status: String
        public let configVersion: Int64
        public let agentConnected: Bool
        public let capabilitiesReady: Bool?
        enum CodingKeys: String, CodingKey {
            case clusterID = "cluster_id", name, management, status, configVersion = "config_version", connectionState = "connection_state", agentConnected = "agent_connected", capabilitiesReady = "agent_capabilities_ready"
        }
    }
    public let userID: String
    public let workspaceID: String
    public let appOrigin: String
    public let clusters: [Cluster]
    enum CodingKeys: String, CodingKey { case userID = "user_id", workspaceID = "workspace_id", appOrigin = "app_origin", clusters }
    public func ownedCluster(installationID: String) throws -> Cluster? {
        let owned = clusters.filter { $0.management.kind == "macos_app" && $0.management.installationID == installationID }
        guard owned.count <= 1 else { throw AgentBridgeFailure.scopeChanged }
        return owned.first
    }
    public func cluster(binding: LocalClusterTargetBinding) throws -> Cluster? {
        let matching = clusters.filter { $0.clusterID == binding.integrationID }
        guard matching.count <= 1 else { throw AgentBridgeFailure.scopeChanged }
        guard let cluster = matching.first else { return nil }
        guard cluster.management.kind == "macos_app", cluster.management.installationID == binding.installationID else { throw AgentBridgeFailure.scopeChanged }
        return cluster
    }
    public func requireSameOwner(_ other: Self) throws {
        guard userID == other.userID, workspaceID == other.workspaceID, appOrigin == other.appOrigin else { throw AgentBridgeFailure.scopeChanged }
    }
}
public struct LocalClusterSetupReceipt: Decodable, Sendable {
    public let setupID: String
    public let expiresAt: String
    public let userID: String
    public let workspaceID: String
    public let appOrigin: String
    public let documentID: String
    public let installationPublicKey: String
    public let installationID: String
    public let operation: String
    public let name: String
    public let integrationID: String?
    public let expectedConfigVersion: Int64?
    enum CodingKeys: String, CodingKey {
        case setupID = "setup_id", expiresAt = "expires_at", userID = "user_id", workspaceID = "workspace_id", appOrigin = "app_origin"
        case documentID = "document_id", installationPublicKey = "installation_public_key", installationID = "installation_id"
        case operation, name, integrationID = "integration_id", expectedConfigVersion = "expected_config_version"
    }
    public func proof(scope: LocalClusterScope, publicKey: String, installation: String, name expectedName: String, operation expectedOperation: String = "create", integrationID expectedIntegration: String? = nil, configVersion: Int64? = nil, now: Date = Date()) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiry = formatter.date(from: expiresAt) ?? ISO8601DateFormatter().date(from: expiresAt)
        guard matches(scope: scope, publicKey: publicKey, installation: installation, name: expectedName),
              matches(operation: expectedOperation, integration: expectedIntegration, configVersion: configVersion),
              !name.isEmpty, name.utf8.count <= 120, name.trimmingCharacters(in: .whitespacesAndNewlines) == name,
              let expiry, expiry > now, expiry.timeIntervalSince(now) <= 300,
              !setupID.isEmpty, setupID.utf8.count <= 256, Data(base64Encoded: publicKey)?.count == 32 else { throw AgentBridgeFailure.scopeChanged }
        let fields = ["personastack:kubernetes-desktop-setup:v1", setupID, userID, workspaceID, appOrigin,
                      documentID, publicKey, operation, integrationID ?? "", String(expectedConfigVersion ?? 0), name, String(Int64(expiry.timeIntervalSince1970))]
        guard fields.allSatisfy({ !$0.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) }) else { throw AgentBridgeFailure.invalidRequest }
        return Data(fields.joined(separator: "\n").utf8)
    }
    // Create signs the API's canonical available name. Rotation retains its exact target name.
    private func matches(scope: LocalClusterScope, publicKey: String, installation: String, name expectedName: String) -> Bool {
        userID == scope.accountID && workspaceID == scope.workspaceID && appOrigin == scope.appOrigin &&
            documentID == scope.documentID && installationPublicKey == publicKey && installationID == installation &&
            (operation == "create" || name == expectedName)
    }
    private func matches(operation expected: String, integration: String?, configVersion: Int64?) -> Bool {
        guard operation == expected, integrationID == integration, (expectedConfigVersion ?? 0) == (configVersion ?? 0) else { return false }
        switch operation {
        case "create": return integrationID == nil && configVersion == nil
        case "rotate": return integrationID != nil && (configVersion ?? 0) > 0
        default: return false
        }
    }
}
public struct LocalClusterEnrollment: Decodable, Sendable {
    public let clusterID: String
    public let setupManifest: String
    enum CodingKeys: String, CodingKey { case clusterID = "cluster_id", setupManifest = "setup_manifest" }
}
