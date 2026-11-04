import Foundation
import PersonaStackCore
import Testing

private let pendingReference = String(repeating: "A", count: 43)
private let pendingExpiry = "2030-01-02T03:04:05.123456789Z"

private func pendingFixture(reference: String = pendingReference, user: String = "natural-user",
                            workspace: String = "workspace", environment: String = "app|gateway|mcp",
                            expiry: String = pendingExpiry, proof: Data = Data(repeating: 0x42, count: 32)) throws -> IMessagePendingEnrollment {
    try IMessagePendingEnrollment(setupReference: reference, naturalUserID: user, workspaceID: workspace,
        environmentIdentity: environment, expiresAt: expiry, credentialBytes: proof)
}

@Test func iMessagePendingEnrollmentPreservesCanonicalProofAndOriginalExpiryAcrossRoundTrip() throws {
    let pending = try pendingFixture()
    let data = try JSONEncoder().encode(pending)
    let restored = try JSONDecoder().decode(IMessagePendingEnrollment.self, from: data)
    #expect(restored == pending)
    #expect(restored.credentialBytes == Data(repeating: 0x42, count: 32))
    #expect(restored.machineCredential == "QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI")
    #expect(restored.expiresAt == pendingExpiry)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(object.keys) == ["version", "setup_reference", "natural_user_id", "workspace_id",
        "environment_identity", "expires_at", "machine_credential"])
    #expect(object["version"] as? Int == 1)
}

@Test(arguments: ["", String(repeating: "A", count: 42), String(repeating: "A", count: 44),
                  String(repeating: "A", count: 42) + "B", String(repeating: "A", count: 42) + "=",
                  String(repeating: "+", count: 43), String(repeating: "é", count: 43)])
func iMessagePendingEnrollmentRejectsMalformedSetupReferences(reference: String) {
    #expect(throws: IMessagePendingEnrollmentError.invalidRecord) { try pendingFixture(reference: reference) }
}

@Test(arguments: ["", " user", "user ", "user\nname", "user\u{0}name", String(repeating: "a", count: 257)])
func iMessagePendingEnrollmentRejectsMalformedOwnerIdentity(value: String) {
    #expect(throws: IMessagePendingEnrollmentError.invalidRecord) { try pendingFixture(user: value) }
    #expect(throws: IMessagePendingEnrollmentError.invalidRecord) { try pendingFixture(workspace: value) }
}

@Test(arguments: ["", "app|gateway|mcp\n", String(repeating: "a", count: 6145)])
func iMessagePendingEnrollmentRejectsMalformedEnvironment(value: String) {
    #expect(throws: IMessagePendingEnrollmentError.invalidRecord) { try pendingFixture(environment: value) }
}

@Test(arguments: ["2030-01-02", "2030-01-02T03:04:05+00:00", "2030-01-02T03:04:05.1234567890Z",
                  "2030-02-30T03:04:05Z", "2030-13-02T03:04:05Z", "2030-01-02T24:04:05Z", "invalid"])
func iMessagePendingEnrollmentRejectsMalformedExpiry(value: String) {
    #expect(throws: IMessagePendingEnrollmentError.invalidRecord) { try pendingFixture(expiry: value) }
}

@Test func iMessagePendingEnrollmentRequiresExactJourneyAndOwnerScope() throws {
    let pending = try pendingFixture()
    try pending.requireJourney(setupReference: pendingReference, naturalUserID: "natural-user",
        workspaceID: "workspace", environmentIdentity: "app|gateway|mcp", expiresAt: pendingExpiry)
    #expect(throws: IMessagePendingEnrollmentError.scopeMismatch) { try pending.requireEnvironment("another-environment") }
    let otherReference = Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
    for fields in [(otherReference, "natural-user", "workspace", pendingExpiry),
                   (pendingReference, "other-user", "workspace", pendingExpiry),
                   (pendingReference, "natural-user", "other-workspace", pendingExpiry),
                   (pendingReference, "natural-user", "workspace", "2030-01-02T03:04:06Z")] {
        #expect(throws: IMessagePendingEnrollmentError.conflictingJourney) {
            try pending.requireJourney(setupReference: fields.0, naturalUserID: fields.1, workspaceID: fields.2,
                environmentIdentity: "app|gateway|mcp", expiresAt: fields.3)
        }
    }
}

@Test func iMessagePendingEnrollmentExpiryDoesNotDestroyRecoveryProof() throws {
    let pending = try pendingFixture()
    try pending.requireUsable(now: pending.expiry.addingTimeInterval(-1))
    #expect(throws: IMessagePendingEnrollmentError.expired) { try pending.requireUsable(now: pending.expiry) }
    #expect(throws: IMessagePendingEnrollmentError.expired) { try pending.requireUsable(now: pending.expiry.addingTimeInterval(1)) }
    let recovered = try JSONDecoder().decode(IMessagePendingEnrollment.self, from: JSONEncoder().encode(pending))
    #expect(recovered == pending)
    #expect(try pendingFixture(proof: Data(repeating: 0x43, count: 32)) != pending)
    #expect(throws: IMessagePendingEnrollmentError.invalidRecord) { try pendingFixture(proof: Data(count: 31)) }
}

@Test func iMessagePendingEnrollmentRejectsAlteredPersistenceSchemaAndNoncanonicalProof() throws {
    let data = try JSONEncoder().encode(pendingFixture())
    let original = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let mutations: [(String, Any?)] = [("version", 2), ("version", nil), ("session", "must-never-persist"),
        ("machine_credential", String(repeating: "A", count: 42) + "B"),
        ("machine_credential", String(repeating: "A", count: 43) + "="),
        ("machine_credential", NSNull()), ("setup_reference", 7)]
    for (key, value) in mutations {
        var object = original
        object[key] = value
        let encoded = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(IMessagePendingEnrollment.self, from: encoded) }
    }
}

@Test func iMessagePendingEnrollmentDescriptionsAndReflectionRedactCustodyValues() throws {
    let pending = try pendingFixture()
    var reflected = ""
    dump(pending, to: &reflected)
    for text in [String(describing: pending), String(reflecting: pending), reflected] {
        #expect(!text.contains(pending.machineCredential))
        #expect(!text.contains(pending.setupReference))
        #expect(!text.contains(pending.naturalUserID))
        #expect(!text.contains(pending.workspaceID))
        #expect(!text.contains(pending.environmentIdentity))
        #expect(text.contains("<redacted>"))
    }
}
