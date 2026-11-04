import Foundation
import PersonaStackCore
import Testing

@Suite struct LocalClusterRequirementsTests {
    private let fields: [String: Int64] = ["cpus": 6, "memory_bytes": 3_221_225_472, "disk_bytes": 12_884_901_888,
        "initial_download_bytes": 12_345, "minimum_host_memory_bytes": 6_442_450_944]
    private func data(_ requirements: Any, version: Int = 1, external: Bool = false) throws -> Data {
        var object: [String: Any] = ["local_cluster_control_version": version, "local_cluster_requirements": requirements]
        if external { object["external_error"] = ["code": "credential_unavailable", "message": "fixture"] }
        else { object["connections"] = [] as [String] }
        return try JSONSerialization.data(withJSONObject: object)
    }
    @Test func budgetReadUsesTypedRuntimeNumbersEvenWhenExternalInventoryFails() throws {
        for external in [false, true] {
            let value = try JSONDecoder().decode(AgentBridgeLocalClusterRequirementsStatus.self, from: data(fields, external: external))
            let requirements = try #require(value.localClusterRequirements)
            #expect(requirements.cpus == 6)
            #expect(requirements.memoryBytes == fields["memory_bytes"])
            #expect(requirements.diskBytes == fields["disk_bytes"])
            #expect(requirements.initialDownloadBytes == 12_345)
            #expect(requirements.minimumHostMemoryBytes == fields["minimum_host_memory_bytes"])
        }
    }
    @Test func malformedRequirementsCannotPoisonEmergencyVersionOnlyRead() throws {
        for invalid: Any in [NSNull(), ["cpus": true], ["cpus": 0], "arbitrary helper text"] {
            let bytes = try data(invalid)
            let capability = try JSONDecoder().decode(AgentBridgeLocalClusterControlCapability.self, from: bytes)
            #expect(capability.localClusterControlVersion == 1)
            #expect(throws: AgentBridgeFailure.runtimeUnsupported) { _ = try JSONDecoder().decode(AgentBridgeLocalClusterRequirementsStatus.self, from: bytes) }
        }
    }
    @Test func setupRejectsInvalidAndUnrepresentableBudgetsWithoutFallback() throws {
        for key in fields.keys {
            for invalid: Any in [0, -1, true, "8 GiB", 1.5, NSNull(), UInt64.max] {
                var value: [String: Any] = fields.mapValues { $0 as Any }
                value[key] = invalid
                #expect(throws: AgentBridgeFailure.runtimeUnsupported) { _ = try JSONDecoder().decode(AgentBridgeLocalClusterRequirementsStatus.self, from: data(value)) }
            }
            var missing = fields; missing.removeValue(forKey: key)
            #expect(throws: AgentBridgeFailure.runtimeUnsupported) { _ = try JSONDecoder().decode(AgentBridgeLocalClusterRequirementsStatus.self, from: data(missing)) }
        }
    }
    @Test func missingRequirementsStayExplicitAndHostChecksUseProvidedPolicy() throws {
        let missing = try JSONDecoder().decode(AgentBridgeLocalClusterRequirementsStatus.self, from: Data(#"{"connections":[],"local_cluster_control_version":1}"#.utf8))
        #expect(missing.localClusterRequirements == nil)
        let requirements = try #require(JSONDecoder().decode(AgentBridgeLocalClusterRequirementsStatus.self, from: data(fields)).localClusterRequirements)
        #expect(requirements.supportsHost(physicalMemoryBytes: UInt64(requirements.minimumHostMemoryBytes), activeProcessorCount: 6))
        #expect(!requirements.supportsHost(physicalMemoryBytes: UInt64(requirements.minimumHostMemoryBytes - 1), activeProcessorCount: 6))
        #expect(!requirements.supportsHost(physicalMemoryBytes: UInt64.max, activeProcessorCount: 5))
    }
}
