import CryptoKit
import Foundation

/// Key material stays in native code. The app's existing Keychain owner stores it.
public struct LocalClusterInstallationKey {
    private let key: Curve25519.Signing.PrivateKey
    public init(rawRepresentation: Data) throws { key = try Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation) }
    public init() { key = Curve25519.Signing.PrivateKey() }
    public var rawRepresentation: Data { key.rawRepresentation }
    public var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }
    public var installationID: String { SHA256.hash(data: key.publicKey.rawRepresentation).map { String(format: "%02x", $0) }.joined() }
    public func sign(_ data: Data) throws -> Data { try key.signature(for: data) }
}

public struct LocalClusterCredentialCustody: Codable, Sendable {
    public let scope: LocalClusterScope
    public let clusterID: String
    public let manifest: String
    public init(scope: LocalClusterScope, enrollment: LocalClusterEnrollment) {
        self.scope = scope; clusterID = enrollment.clusterID; manifest = enrollment.setupManifest
    }
}
