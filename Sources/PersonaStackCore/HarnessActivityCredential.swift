import Foundation
import Security

public struct HarnessActivityCredential: Codable, Sendable {
    public let connectionID: String
    public let activityToken: String
    public let appURL: URL
    public let harness: LocalSessionHarness
    public let routingEnabled: Bool
    public init(bundle: LocalSessionBundle, appURL: URL) {
        self.init(connectionID: bundle.connectionID, activityToken: bundle.activityToken,
                  appURL: appURL, harness: bundle.harness, routingEnabled: true)
    }
    public init(connectionID: String, activityToken: String, appURL: URL, harness: LocalSessionHarness, routingEnabled: Bool) {
        self.connectionID = connectionID; self.activityToken = activityToken; self.appURL = appURL
        self.harness = harness; self.routingEnabled = routingEnabled
    }
}

/// Activity credentials never enter plugin files, command arguments, or connection listings.
public struct HarnessActivityKeychain: Sendable {
    private static let service = "ai.personastack.desktop.harness-activity"
    public init() {}
    private func query(_ connectionID: String) throws -> [String: Any] {
        guard UUID(uuidString: connectionID) != nil else { throw LocalSessionError.invalidRequest }
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                kSecAttrAccount as String: connectionID.lowercased(), kSecAttrSynchronizable as String: false]
    }
    public func store(_ credential: HarnessActivityCredential, helperURL: URL) throws {
        var attributes = try query(credential.connectionID)
        attributes[kSecValueData as String] = try JSONEncoder().encode(credential)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var helper: SecTrustedApplication?
        var desktop: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(helperURL.path, &helper) == errSecSuccess,
              SecTrustedApplicationCreateFromPath(nil, &desktop) == errSecSuccess,
              let helper, let desktop else { throw LocalSessionError.unsafeFiles }
        var access: SecAccess?
        guard SecAccessCreate("PersonaStack harness activity" as CFString, [desktop, helper] as CFArray, &access) == errSecSuccess, let access else { throw LocalSessionError.unsafeFiles }
        attributes[kSecAttrAccess as String] = access
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update: [String: Any] = [kSecValueData as String: attributes[kSecValueData as String]!, kSecAttrAccess as String: access]
            guard SecItemUpdate(try query(credential.connectionID) as CFDictionary, update as CFDictionary) == errSecSuccess else { throw LocalSessionError.unsafeFiles }
        } else if status != errSecSuccess { throw LocalSessionError.unsafeFiles }
    }
    public func read(_ connectionID: String) throws -> HarnessActivityCredential {
        var attributes = try query(connectionID)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        attributes[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let credential = try? JSONDecoder().decode(HarnessActivityCredential.self, from: data),
              credential.connectionID.lowercased() == connectionID.lowercased() else { throw LocalSessionError.unsafeFiles }
        return credential
    }
    public func remove(_ connectionID: String) throws {
        let status = SecItemDelete(try query(connectionID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LocalSessionError.unsafeFiles }
    }
}
