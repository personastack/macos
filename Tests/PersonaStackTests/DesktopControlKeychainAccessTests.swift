import Foundation
import Security
import Testing
@testable import PersonaStack

private final class KeychainSecurityFixture: DesktopControlKeychainSecurity, @unchecked Sendable {
    var allowed = true
    var getStatus = errSecSuccess
    var setStatuses: [OSStatus] = []
    var readStatus = errSecSuccess
    var updateStatus = errSecSuccess
    var addStatus = errSecSuccess
    var deleteStatus = errSecSuccess
    var data: Data? = Data([1, 2, 3])
    var events: [String] = []
    var queries: [[String: Any]] = []
    var attributes: [[String: Any]] = []
    var firstReadEntered: DispatchSemaphore?
    var continueFirstRead: DispatchSemaphore?
    var laterReadEntered: DispatchSemaphore?

    func interactionAllowed() -> (OSStatus, Bool) {
        events.append("get")
        return (getStatus, allowed)
    }

    func setInteractionAllowed(_ allowed: Bool) -> OSStatus {
        events.append("set:\(allowed)")
        let status = setStatuses.isEmpty ? errSecSuccess : setStatuses.removeFirst()
        if status == errSecSuccess { self.allowed = allowed }
        return status
    }

    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) {
        events.append("read:\(allowed)")
        queries.append(query)
        if queries.count == 1, let firstReadEntered, let continueFirstRead {
            firstReadEntered.signal()
            guard continueFirstRead.wait(timeout: .now() + 3) == .success else {
                return (errSecNotAvailable, nil)
            }
        } else { laterReadEntered?.signal() }
        return (readStatus, data)
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        events.append("update:\(allowed)")
        queries.append(query)
        self.attributes.append(attributes)
        return updateStatus
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        events.append("add:\(allowed)")
        self.attributes.append(attributes)
        return addStatus
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        events.append("delete:\(allowed)")
        queries.append(query)
        return deleteStatus
    }
}

@Test(arguments: [false, true])
func passiveKeychainReadSuppressesLegacyUIAndRestoresPriorPolicy(previous: Bool) throws {
    let security = KeychainSecurityFixture()
    security.allowed = previous
    let keychain = SystemDesktopControlKeychainAccess(security: security)

    #expect(try keychain.read(service: "fixture.service", account: "fixture.account") == Data([1, 2, 3]))

    #expect(security.events == ["get", "set:false", "read:false", "set:\(previous)"])
    #expect(security.allowed == previous)
    let query = try #require(security.queries.first)
    #expect(Set(query.keys) == Set([kSecClass, kSecAttrService, kSecAttrAccount, kSecReturnData, kSecMatchLimit].map { $0 as String }))
    #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
    #expect(query[kSecAttrService as String] as? String == "fixture.service")
    #expect(query[kSecAttrAccount as String] as? String == "fixture.account")
    #expect(query[kSecReturnData as String] as? Bool == true)
    #expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
}

@Test(arguments: [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled])
func deniedKeychainReadReturnsRecoveryErrorWithoutTreatingCredentialAsMissing(status: OSStatus) throws {
    let security = KeychainSecurityFixture()
    security.readStatus = status
    let keychain = SystemDesktopControlKeychainAccess(security: security)
    #expect(throws: DesktopControlEnrollmentError.credentialAccessRequired) {
        try keychain.read(service: "fixture", account: "installation")
    }
    #expect(security.events == ["get", "set:false", "read:false", "set:true"])
    #expect(DesktopControlEnrollmentError.credentialAccessRequired.localizedDescription.contains("Retry Remote Control"))
}

@Test func missingAndMalformedKeychainResultsRemainDistinct() throws {
    let security = KeychainSecurityFixture()
    let keychain = SystemDesktopControlKeychainAccess(security: security)
    security.readStatus = errSecItemNotFound
    #expect(try keychain.read(service: "fixture", account: "installation") == nil)
    security.readStatus = errSecSuccess
    security.data = nil
    #expect(throws: DesktopControlEnrollmentError.credentialStoreUnavailable) {
        try keychain.read(service: "fixture", account: "installation")
    }
    #expect(security.allowed)
}

@Test func explicitKeychainReadAllowsAuthorizationOnlyInsideOperation() throws {
    let security = KeychainSecurityFixture()
    security.allowed = false
    let keychain = SystemDesktopControlKeychainAccess(security: security)
    _ = try keychain.read(service: "fixture", account: "installation", interaction: .allowed)
    #expect(security.events == ["get", "set:true", "read:true", "set:false"])
    #expect(!security.allowed)
}

@Test func keychainPolicyFailuresDoNotReadSecretAndRestoreAfterFailedSet() throws {
    let security = KeychainSecurityFixture()
    let keychain = SystemDesktopControlKeychainAccess(security: security)
    security.getStatus = errSecNotAvailable
    #expect(throws: DesktopControlEnrollmentError.credentialStoreUnavailable) {
        try keychain.read(service: "fixture", account: "installation")
    }
    #expect(security.events == ["get"])
    security.events = []
    security.getStatus = errSecSuccess
    security.setStatuses = [errSecNotAvailable, errSecSuccess]
    #expect(throws: DesktopControlEnrollmentError.credentialStoreUnavailable) {
        try keychain.read(service: "fixture", account: "installation")
    }
    #expect(security.events == ["get", "set:false", "set:true"])
    #expect(security.queries.isEmpty)
}

@Test func keychainPolicyRestoreFailureDoesNotReturnCredential() throws {
    let security = KeychainSecurityFixture()
    security.setStatuses = [errSecSuccess, errSecNotAvailable]
    let keychain = SystemDesktopControlKeychainAccess(security: security)
    #expect(throws: DesktopControlEnrollmentError.credentialStoreUnavailable) {
        try keychain.read(service: "fixture", account: "installation")
    }
    #expect(security.events == ["get", "set:false", "read:false", "set:true"])
}

@Test func passiveKeychainWritesAndDeletesUseTheSameGateAndKeepDefaultAppACL() throws {
    let security = KeychainSecurityFixture()
    security.updateStatus = errSecItemNotFound
    let keychain = SystemDesktopControlKeychainAccess(security: security)
    try keychain.write(Data([5]), service: "fixture", account: "installation")
    #expect(security.events == ["get", "set:false", "update:false", "add:false", "set:true"])
    let item = try #require(security.attributes.last)
    #expect(item[kSecAttrAccess as String] == nil)
    #expect(item[kSecAttrAccessGroup as String] == nil)
    #expect(item[kSecUseDataProtectionKeychain as String] == nil)
    #expect(item[kSecValueData as String] as? Data == Data([5]))
    #expect(item[kSecAttrService as String] as? String == "fixture")
    #expect(item[kSecAttrAccount as String] as? String == "installation")
    security.events = []
    security.deleteStatus = errSecItemNotFound
    try keychain.remove(service: "fixture", account: "installation")
    #expect(security.events == ["get", "set:false", "delete:false", "set:true"])
}

@Test func deniedKeychainUpdateNeverRecreatesOrDeletesIdentity() throws {
    let security = KeychainSecurityFixture()
    security.updateStatus = errSecInteractionNotAllowed
    let keychain = SystemDesktopControlKeychainAccess(security: security)
    #expect(throws: DesktopControlEnrollmentError.credentialAccessRequired) {
        try keychain.write(Data([5]), service: "fixture", account: "installation")
    }
    #expect(security.events == ["get", "set:false", "update:false", "set:true"])
}

@Test func independentKeychainStoresCannotShareAnInteractiveAuthorizationWindow() async throws {
    let security = KeychainSecurityFixture()
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let laterEntered = DispatchSemaphore(value: 0)
    let passiveAttempted = DispatchSemaphore(value: 0)
    security.firstReadEntered = entered
    security.continueFirstRead = release
    security.laterReadEntered = laterEntered
    let interactive = SystemDesktopControlKeychainAccess(security: security)
    let passive = SystemDesktopControlKeychainAccess(security: security)
    let authorizing = Task.detached {
        try interactive.read(service: "fixture", account: "installation", interaction: .allowed)
    }
    #expect(entered.wait(timeout: .now() + 2) == .success)
    let reading = Task.detached {
        passiveAttempted.signal()
        return try passive.read(service: "fixture", account: "installation")
    }
    #expect(passiveAttempted.wait(timeout: .now() + 2) == .success)
    // The second store cannot enter Security while the first is displaying UI.
    #expect(laterEntered.wait(timeout: .now() + .milliseconds(100)) == .timedOut)
    release.signal()
    _ = try await authorizing.value
    _ = try await reading.value
    #expect(security.events == ["get", "set:true", "read:true", "set:true",
                                "get", "set:false", "read:false", "set:true"])
    #expect(security.allowed)
}
