import Foundation
import PersonaStackCore
import Testing

@Suite struct AgentBridgeLocalRuntimeProtocolTests {
    @Test(arguments: ["local_cluster_start", "local_cluster_status", "local_cluster_cancel", "local_cluster_apply",
                      "local_cluster_runtime_status", "local_cluster_runtime_stop", "local_cluster_runtime_resume",
                      "local_cluster_binding", "local_cluster_remove", "local_cluster_new_setup"])
    func boundedNativeOperationsAreEncodable(_ operation: String) throws {
        let request = try AgentBridgeRequest(operation: operation, payload: [:])
        let envelope = try #require(JSONSerialization.jsonObject(with: request.encoded()) as? [String: Any])
        #expect(envelope["operation"] as? String == operation)
        #expect(envelope["version"] as? Int == 1)
    }

    @Test(arguments: ["execute", "local_cluster_command", "local_cluster_delete", "local_cluster_runtime_reset"])
    func arbitraryAndDestructiveCommandsRemainRejected(_ operation: String) {
        #expect(throws: AgentBridgeFailure.invalidRequest) { try AgentBridgeRequest(operation: operation, payload: [:]) }
    }

    @Test(arguments: [AgentBridgeFailure.runtimeOccupied, .attemptChanged, .localRuntimeActive, .enrollmentUncertain,
                      .busy, .runtimeUnsupported, .credentialUnavailable])
    func finiteFailuresDiscardHelperMessage(_ failure: AgentBridgeFailure) throws {
        let id = UUID()
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "request_id": id.uuidString,
            "error": ["code": failure.rawValue, "message": "untrusted diagnostic fixture-secret"]])
        #expect(throws: failure) { try AgentBridgeResponse.decode(AgentBridgeAcknowledgement.self, data: data, requestID: id) }
    }

    @Test func unknownHelperFailureKeepsExistingSafeFallback() throws {
        let id = UUID()
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "request_id": id.uuidString,
            "error": ["code": "future_failure", "message": "fixture-secret"]])
        #expect(throws: AgentBridgeFailure.serviceUnavailable) {
            try AgentBridgeResponse.decode(AgentBridgeAcknowledgement.self, data: data, requestID: id)
        }
    }

    @Test func malformedJSONReturnsFiniteInvalidRequest() {
        #expect(throws: AgentBridgeFailure.invalidRequest) {
            try AgentBridgeResponse.decode(AgentBridgeAcknowledgement.self, data: Data("{bad json".utf8), requestID: UUID())
        }
    }

    @Test func runtimeLivenessFieldsCannotDefaultToStopped() {
        for json in [#"{"installed":true,"running":false,"kubernetes_available":false,"enabled":true}"#,
                     #"{"installed":true,"running":0,"kubernetes_available":false,"enabled":true,"installer_active":false}"#] {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(AgentBridgeLocalRuntimeSnapshot.self, from: Data(json.utf8))
            }
        }
    }

    @Test func olderExternalStopAcknowledgementRemainsCompatible() throws {
        let result = try JSONDecoder().decode(AgentBridgeAcknowledgement.self, from: Data(#"{"disabled":true}"#.utf8))
        #expect(result.disabled == true)
        #expect(result.keepService == nil)
    }
    @Test func publishedHelperWithoutCapabilityHasNoKnownLocalConsumer() throws {
        let legacy = try JSONDecoder().decode(AgentBridgeConnections.self, from: Data(#"{"connections":[]}"#.utf8))
        #expect(legacy.localClusterControlVersion == nil)
        #expect(!AgentBridgeLocalRuntimeSnapshot.legacyNoLocalConsumer.preventsReplacement)
        #expect(!AgentBridgeLocalRuntimeSnapshot.legacyNoLocalConsumer.kubernetesAvailable)
    }

    @Test func supportedLocalControlCapabilityIsExplicit() throws {
        let current = try JSONDecoder().decode(AgentBridgeConnections.self,
            from: Data(#"{"connections":[],"local_cluster_control_version":1}"#.utf8))
        #expect(current.localClusterControlVersion == 1)
    }

    @Test(arguments: ["null", "0", "2", "-1", "true", "\"1\"", "{}"])
    func malformedOrUnsupportedAdvertisedCapabilityRequiresAnUpdate(_ value: String) {
        let json = "{\"connections\":[],\"local_cluster_control_version\":\(value)}"
        #expect(throws: AgentBridgeFailure.runtimeUnsupported) {
            try JSONDecoder().decode(AgentBridgeConnections.self, from: Data(json.utf8))
        }
        #expect(throws: AgentBridgeFailure.runtimeUnsupported) {
            try JSONDecoder().decode(AgentBridgeLocalClusterControlCapability.self, from: Data(json.utf8))
        }
    }

    @Test func verifiedRemovedDataDoesNotBlockHelperReplacement() throws {
        let json = #"{"installed":false,"running":false,"kubernetes_available":false,"enabled":false,"installer_active":false,"safe_reason":"local_data_removed"}"#
        let removed = try JSONDecoder().decode(AgentBridgeLocalRuntimeSnapshot.self, from: Data(json.utf8))
        #expect(!removed.preventsReplacement)
        #expect(!removed.keepsService)
        let contradictory = json.replacingOccurrences(of: "\"installed\":false", with: "\"installed\":true")
        let unknown = try JSONDecoder().decode(AgentBridgeLocalRuntimeSnapshot.self, from: Data(contradictory.utf8))
        #expect(unknown.preventsReplacement)
    }

    @Test func unavailableExternalInventoryNeverDecodesAsAnEmptyConnectionList() {
        let status = #"{"local_cluster_control_version":1,"external_error":{"code":"credential_unavailable","message":"External runtime credentials are unavailable. Restore credential access and try again."}}"#
        #expect(throws: AgentBridgeFailure.credentialUnavailable) {
            try JSONDecoder().decode(AgentBridgeConnections.self, from: Data(status.utf8))
        }
    }

    @Test func localCapabilitySurvivesExternalInventoryFailure() throws {
        let status = #"{"local_cluster_control_version":1,"external_error":{"code":"credential_unavailable","message":"fixture-secret"}}"#
        let local = try JSONDecoder().decode(AgentBridgeLocalClusterControlCapability.self, from: Data(status.utf8))
        #expect(local.localClusterControlVersion == 1)
        let unrelatedMalformedInventory = #"{"local_cluster_control_version":1,"connections":"not a connection list","external_error":null}"#
        let independent = try JSONDecoder().decode(AgentBridgeLocalClusterControlCapability.self, from: Data(unrelatedMalformedInventory.utf8))
        #expect(independent.localClusterControlVersion == 1)
    }

    @Test(arguments: ["null", "{}", #"{"code":"future_error","message":"fixture-secret"}"#,
                      #"{"code":"credential_unavailable","message":false}"#])
    func malformedExternalInventoryErrorsFailClosed(_ error: String) {
        let status = "{\"local_cluster_control_version\":1,\"external_error\":\(error)}"
        #expect(throws: AgentBridgeFailure.invalidRequest) {
            try JSONDecoder().decode(AgentBridgeConnections.self, from: Data(status.utf8))
        }
    }

    @Test func successfulExternalStatusRetainsItsEncodingContract() throws {
        let data = Data(#"{"connections":[],"local_cluster_control_version":1}"#.utf8)
        let status = try JSONDecoder().decode(AgentBridgeConnections.self, from: data)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as? [String: Any])
        #expect(Set(encoded.keys) == ["connections", "local_cluster_control_version"])
        #expect(encoded["local_cluster_control_version"] as? Int == 1)
    }

}
