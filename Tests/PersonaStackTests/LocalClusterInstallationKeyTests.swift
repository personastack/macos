import CryptoKit
import Foundation
import PersonaStackCore
import Testing

@Suite struct LocalClusterInstallationKeyTests {
    @Test func restoredInstallationKeepsPublicIdentityAndProofVerification() throws {
        let original = try LocalClusterInstallationKey(rawRepresentation: Data(repeating: 7, count: 32))
        let restored = try LocalClusterInstallationKey(rawRepresentation: original.rawRepresentation)
        #expect(restored.publicKey == original.publicKey)
        #expect(restored.installationID == original.installationID)
        #expect(restored.installationID.count == 64)
        let challenge = Data("bounded-native-proof".utf8)
        let signature = try restored.sign(challenge)
        let verifier = try Curve25519.Signing.PublicKey(rawRepresentation: #require(Data(base64Encoded: restored.publicKey)))
        #expect(signature.count == 64)
        #expect(verifier.isValidSignature(signature, for: challenge))
        #expect(!verifier.isValidSignature(signature, for: Data("other-proof".utf8)))
    }
    @Test func canonicalAllocatedNameIsCoveredByTheActualEd25519Proof() throws {
        let key = try LocalClusterInstallationKey(rawRepresentation: Data(repeating: 7, count: 32))
        let scope = try LocalClusterScope(appOrigin: "https://app.example", accountID: "user-a", workspaceID: "ws-a",
            documentID: #require(UUID(uuidString: "11111111-1111-4111-8111-111111111111")))
        let fields: [String: Any] = ["setup_id": "setup-a", "expires_at": "1970-01-01T00:03:20Z", "user_id": scope.accountID,
            "workspace_id": scope.workspaceID, "app_origin": scope.appOrigin, "document_id": scope.documentID,
            "installation_public_key": key.publicKey, "installation_id": key.installationID, "operation": "create", "name": "This Mac (2)"]
        let receipt = try JSONDecoder().decode(LocalClusterSetupReceipt.self, from: JSONSerialization.data(withJSONObject: fields))
        let proof = try receipt.proof(scope: scope, publicKey: key.publicKey, installation: key.installationID,
            name: "This Mac", now: Date(timeIntervalSince1970: 100))
        let signature = try key.sign(proof)
        let verifier = try Curve25519.Signing.PublicKey(rawRepresentation: #require(Data(base64Encoded: key.publicKey)))
        #expect(verifier.isValidSignature(signature, for: proof))
        let preferred = try #require(String(data: proof, encoding: .utf8)).replacingOccurrences(of: "\nThis Mac (2)\n", with: "\nThis Mac\n")
        #expect(Data(preferred.utf8) != proof)
        #expect(!verifier.isValidSignature(signature, for: Data(preferred.utf8)))
    }
    @Test func corruptKeyDoesNotCreateReplacementIdentity() {
        #expect(throws: (any Error).self) { _ = try LocalClusterInstallationKey(rawRepresentation: Data(repeating: 7, count: 31)) }
    }
}
