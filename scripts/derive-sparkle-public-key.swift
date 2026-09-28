import CryptoKit
import Foundation

let encoded = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)?
    .trimmingCharacters(in: .whitespacesAndNewlines)
guard let encoded, let secret = Data(base64Encoded: encoded) else {
    fatalError("Sparkle private key is not valid base64")
}

let publicKey: Data
switch secret.count {
case 32:
    publicKey = try Curve25519.Signing.PrivateKey(rawRepresentation: secret).publicKey.rawRepresentation
case 96:
    publicKey = secret.suffix(32)
default:
    fatalError("Sparkle private key must decode to 32 or 96 bytes")
}

print(publicKey.base64EncodedString())
