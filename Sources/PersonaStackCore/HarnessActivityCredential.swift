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
    private static let collectionAccount = "all-connections"
    private static let mutationLock = NSLock()

    private struct Collection: Codable {
        var credentials: [String: HarnessActivityCredential] = [:]
    }

    public init() {}
    private func query(_ connectionID: String) throws -> [String: Any] {
        guard UUID(uuidString: connectionID) != nil else { throw LocalSessionError.invalidRequest }
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                kSecAttrAccount as String: connectionID.lowercased(), kSecAttrSynchronizable as String: false]
    }

    private func collectionQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.collectionAccount, kSecAttrSynchronizable as String: false]
    }

    private func loadCollection() throws -> Collection? {
        var query = collectionQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let collection = try? JSONDecoder().decode(Collection.self, from: data) else {
            throw LocalSessionError.unsafeFiles
        }
        return collection
    }

    public func store(_ credential: HarnessActivityCredential, helperURL: URL) throws {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }

        let account = credential.connectionID.lowercased()
        guard UUID(uuidString: account) != nil else { throw LocalSessionError.invalidRequest }
        let existingCollection = try loadCollection()
        var collection = existingCollection ?? Collection()
        collection.credentials[account] = credential
        let data = try JSONEncoder().encode(collection)

        if existingCollection != nil {
            let update: [String: Any] = [kSecValueData as String: data]
            guard SecItemUpdate(collectionQuery() as CFDictionary, update as CFDictionary) == errSecSuccess else { throw LocalSessionError.unsafeFiles }
            return
        }

        var helper: SecTrustedApplication?
        var desktop: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(helperURL.path, &helper) == errSecSuccess,
              SecTrustedApplicationCreateFromPath(nil, &desktop) == errSecSuccess,
              let helper, let desktop else { throw LocalSessionError.unsafeFiles }
        var access: SecAccess?
        guard SecAccessCreate("PersonaStack harness activity" as CFString, [desktop, helper] as CFArray, &access) == errSecSuccess, let access else { throw LocalSessionError.unsafeFiles }

        var attributes = collectionQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrAccess as String] = access
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Keep the original trusted-app ACL. Replacing it on every persona
            // configure causes macOS to prompt for Keychain permission again.
            let update: [String: Any] = [kSecValueData as String: data]
            guard SecItemUpdate(collectionQuery() as CFDictionary, update as CFDictionary) == errSecSuccess else { throw LocalSessionError.unsafeFiles }
        } else if status != errSecSuccess { throw LocalSessionError.unsafeFiles }
    }

    public func read(_ connectionID: String) throws -> HarnessActivityCredential {
        guard UUID(uuidString: connectionID) != nil else { throw LocalSessionError.invalidRequest }
        let account = connectionID.lowercased()
        if let collection = try loadCollection(), let credential = collection.credentials[account],
           credential.connectionID.lowercased() == account {
            return credential
        }

        // Keep reading credentials written by earlier app versions until each
        // connection is reconfigured or removed.
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
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }

        guard UUID(uuidString: connectionID) != nil else { throw LocalSessionError.invalidRequest }
        let account = connectionID.lowercased()
        if var collection = try loadCollection(), collection.credentials.removeValue(forKey: account) != nil {
            let update: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(collection)]
            guard SecItemUpdate(collectionQuery() as CFDictionary, update as CFDictionary) == errSecSuccess else { throw LocalSessionError.unsafeFiles }
        }

        // Remove the legacy per-connection item too, if this installation has one.
        let status = SecItemDelete(try query(connectionID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LocalSessionError.unsafeFiles }
    }
}
