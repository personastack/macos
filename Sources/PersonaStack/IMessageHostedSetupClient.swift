import Foundation
import CryptoKit
import PersonaStackCore

/// Only finite failures cross this boundary. HTTP bodies and transport errors stay private.
enum IMessageHostedSetupError: Error, Equatable, LocalizedError, Sendable {
    case invalidRequest, invalidResponse, authenticationRequired, scopeChanged, rateLimited, serviceUnavailable
    var errorDescription: String? {
        switch self {
        case .invalidRequest: "This Messages setup request is invalid."
        case .invalidResponse: "The Messages setup response could not be verified."
        case .authenticationRequired: "Sign in to continue Messages setup."
        case .scopeChanged: "The account, workspace or server changed. Reopen Messages setup."
        case .rateLimited: "Messages setup is busy. Try again shortly."
        case .serviceUnavailable: "Messages setup is unavailable. Try again."
        }
    }
}

struct IMessageHostedNativeScope: Decodable, Equatable, Sendable {
    let naturalUserID: String
    let workspaceID: String
    let appOrigin: String
    init(from decoder: Decoder) throws {
        let c = try hostedContainer(decoder, Keys.self)
        naturalUserID = try c.decode(String.self, forKey: .naturalUserID)
        workspaceID = try c.decode(String.self, forKey: .workspaceID)
        appOrigin = try c.decode(String.self, forKey: .appOrigin)
        guard hostedID(naturalUserID), hostedID(workspaceID), appOrigin.utf8.count <= 2048,
              let parts = URLComponents(string: appOrigin), parts.scheme.map({ ["http", "https"].contains($0) }) == true,
              parts.host?.isEmpty == false, parts.user == nil, parts.password == nil,
              parts.path.isEmpty, parts.query == nil, parts.fragment == nil else { throw IMessageHostedSetupError.invalidResponse }
    }
    private enum Keys: String, CodingKey, CaseIterable {
        case naturalUserID = "natural_user_id", workspaceID = "workspace_id", appOrigin = "app_origin"
    }
}

struct IMessageHostedJourneyLocator: Codable, Equatable, Sendable {
    let setupReference: String
    let generation: Int64
    init(setupReference: String, generation: Int64) throws {
        guard hostedCanonical32(setupReference), generation > 0 else { throw IMessageHostedSetupError.invalidRequest }
        self.setupReference = setupReference; self.generation = generation
    }
    init(from decoder: Decoder) throws {
        let c = try hostedContainer(decoder, CodingKeys.self)
        try self.init(setupReference: c.decode(String.self, forKey: .setupReference), generation: c.decode(Int64.self, forKey: .generation))
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case setupReference = "setup_reference", generation }
}

struct IMessageHostedJourney: Decodable, Equatable, Sendable {
    let setupReference: String
    let generation: Int64
    let expiresAt: String
    let macVerified: Bool
    let integrationConfigID: String?
    var locator: IMessageHostedJourneyLocator { try! .init(setupReference: setupReference, generation: generation) }
    init(from decoder: Decoder) throws {
        let c = try hostedContainer(decoder, Keys.self, optional: [.integrationConfigID])
        setupReference = try c.decode(String.self, forKey: .setupReference)
        generation = try c.decode(Int64.self, forKey: .generation)
        expiresAt = try c.decode(String.self, forKey: .expiresAt)
        macVerified = try c.decode(Bool.self, forKey: .macVerified)
        integrationConfigID = hostedNonempty(try c.decodeIfPresent(String.self, forKey: .integrationConfigID))
        guard hostedCanonical32(setupReference), generation > 0,
              integrationConfigID.map({ macVerified && hostedID($0) }) ?? true else { throw IMessageHostedSetupError.invalidResponse }
        _ = try IMessageGatewayWire.utcDate(expiresAt)
    }
    private enum Keys: String, CodingKey, CaseIterable {
        case setupReference = "setup_reference", generation, expiresAt = "expires_at", macVerified = "mac_verified"
        case integrationConfigID = "integration_config_id"
    }
}

enum IMessageHostedEnrollmentMode: Equatable, Sendable { case enroll, attach(installationID: String) }

struct IMessageHostedEnrollmentTicket: Decodable, Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    let enrollmentTicket: String
    let expiresAt: String
    var description: String { "IMessageHostedEnrollmentTicket(<redacted>)" }
    var customMirror: Mirror { Mirror(self, children: ["value": "<redacted>"]) }
    init(from decoder: Decoder) throws {
        let c = try hostedContainer(decoder, Keys.self)
        enrollmentTicket = try c.decode(String.self, forKey: .enrollmentTicket)
        expiresAt = try c.decode(String.self, forKey: .expiresAt)
        guard hostedCanonical32(enrollmentTicket) else { throw IMessageHostedSetupError.invalidResponse }
        _ = try IMessageGatewayWire.utcDate(expiresAt)
    }
    private enum Keys: String, CodingKey, CaseIterable { case enrollmentTicket = "enrollment_ticket", expiresAt = "expires_at" }
}

struct IMessageHostedMetadataRequest: Encodable, Sendable, CustomStringConvertible, CustomReflectable {
    let locator: IMessageHostedJourneyLocator
    let enrollmentTicket: String
    let input: IMessageGatewayCommandInput
    var operation: IMessageGatewayOperation { input.operation }
    var description: String { "IMessageHostedMetadataRequest(<redacted>)" }
    var customMirror: Mirror { Mirror(self, children: ["value": "<redacted>"]) }
    init(locator: IMessageHostedJourneyLocator, enrollmentTicket: String, input: IMessageGatewayCommandInput) throws {
        guard hostedCanonical32(enrollmentTicket) else { throw IMessageHostedSetupError.invalidRequest }
        switch input {
        case .prerequisites: break
        case .setupConversations(let page):
            guard page.query.unicodeScalars.count <= 128, !hostedHasControls(page.query), (1...50).contains(page.limit),
                  page.snapshotToken.map(hostedOpaqueID) ?? true, page.pageToken.map(hostedOpaqueID) ?? true,
                  page.pageToken == nil || page.snapshotToken != nil else { throw IMessageHostedSetupError.invalidRequest }
        case .verifyConversations(let selection):
            guard (1...32).contains(selection.conversationIDs.count), Set(selection.conversationIDs).count == selection.conversationIDs.count,
                  selection.conversationIDs.allSatisfy(hostedOpaqueID) else { throw IMessageHostedSetupError.invalidRequest }
        }
        self.locator = locator; self.enrollmentTicket = enrollmentTicket; self.input = input
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(locator.setupReference, forKey: .setupReference); try c.encode(locator.generation, forKey: .generation)
        try c.encode(enrollmentTicket, forKey: .enrollmentTicket); try c.encode(operation, forKey: .operation)
        try c.encode(input, forKey: .input)
    }
    private enum Keys: String, CodingKey { case setupReference = "setup_reference", generation, enrollmentTicket = "enrollment_ticket", operation, input }
}

struct IMessageHostedConversation: Decodable, Equatable, Sendable {
    let conversationID: String
    let label: String
    let isGroup: Bool
    let participantCount: Int
    let available: Bool
    init(from decoder: Decoder) throws {
        let c = try hostedContainer(decoder, Keys.self)
        conversationID = try c.decode(String.self, forKey: .conversationID); label = try c.decode(String.self, forKey: .label)
        isGroup = try c.decode(Bool.self, forKey: .isGroup); participantCount = try c.decode(Int.self, forKey: .participantCount)
        available = try c.decode(Bool.self, forKey: .available)
        guard hostedOpaqueID(conversationID), label.utf8.count <= 256, (0...100).contains(participantCount) else {
            throw IMessageHostedSetupError.invalidResponse
        }
    }
    private enum Keys: String, CodingKey, CaseIterable {
        case conversationID = "conversation_id", label, isGroup = "is_group", participantCount = "participant_count", available
    }
}

struct IMessageHostedConversationsPage: Decodable, Equatable, Sendable {
    let snapshotToken: String
    let nextPageToken: String?
    let conversations: [IMessageHostedConversation]
    let hasMore: Bool
    let stopReason: IMessagePageStopReason
    init(from decoder: Decoder) throws {
        let c = try hostedContainer(decoder, Keys.self, optional: [.nextPageToken])
        snapshotToken = try c.decode(String.self, forKey: .snapshotToken)
        nextPageToken = hostedNonempty(try c.decodeIfPresent(String.self, forKey: .nextPageToken))
        conversations = try c.decode([IMessageHostedConversation].self, forKey: .conversations)
        hasMore = try c.decode(Bool.self, forKey: .hasMore); stopReason = try c.decode(IMessagePageStopReason.self, forKey: .stopReason)
        guard hostedOpaqueID(snapshotToken), nextPageToken.map(hostedOpaqueID) ?? true,
              hasMore == (nextPageToken != nil), hostedOptionsValid(conversations, maximum: 50),
              stopReason != .caughtUp || !hasMore else { throw IMessageHostedSetupError.invalidResponse }
    }
    private enum Keys: String, CodingKey, CaseIterable {
        case snapshotToken = "snapshot_token", nextPageToken = "next_page_token", conversations, hasMore = "has_more", stopReason = "stop_reason"
    }
}

struct IMessageHostedVerification: Decodable, Equatable, Sendable {
    let conversations: [IMessageHostedConversation]
    let verified: Bool
    init(from decoder: Decoder) throws {
        let c = try hostedContainer(decoder, Keys.self)
        conversations = try c.decode([IMessageHostedConversation].self, forKey: .conversations)
        verified = try c.decode(Bool.self, forKey: .verified)
        guard !conversations.isEmpty, hostedOptionsValid(conversations, maximum: 32),
              !verified || conversations.allSatisfy(\.available) else { throw IMessageHostedSetupError.invalidResponse }
    }
    private enum Keys: String, CodingKey, CaseIterable { case conversations, verified }
}

enum IMessageHostedMetadataResult: Decodable, Equatable, Sendable {
    case prerequisites(databaseReady: Bool)
    case conversationsPage(IMessageHostedConversationsPage)
    case verification(IMessageHostedVerification)
    var operation: IMessageGatewayOperation {
        switch self { case .prerequisites: .prerequisites; case .conversationsPage: .setupConversations; case .verification: .verifyConversations }
    }
    init(from decoder: Decoder) throws {
        let c = try hostedContainer(decoder, Keys.self, optional: Set(Keys.allCases))
        guard c.allKeys.count == 1, let key = c.allKeys.first else { throw IMessageHostedSetupError.invalidResponse }
        switch key {
        case .prerequisites:
            let value = try hostedContainer(c.superDecoder(forKey: key), PrerequisitesKeys.self)
            self = .prerequisites(databaseReady: try value.decode(Bool.self, forKey: .databaseReady))
        case .conversationsPage: self = .conversationsPage(try c.decode(IMessageHostedConversationsPage.self, forKey: key))
        case .verification: self = .verification(try c.decode(IMessageHostedVerification.self, forKey: key))
        }
    }
    private enum Keys: String, CodingKey, CaseIterable { case prerequisites, conversationsPage = "conversations_page", verification }
    private enum PrerequisitesKeys: String, CodingKey, CaseIterable { case databaseReady = "database_ready" }
}

struct IMessageHostedMetadataResponse: Decodable, Equatable, Sendable {
    let setupReference: String
    let generation: Int64
    let operation: IMessageGatewayOperation
    let result: IMessageHostedMetadataResult?
    let reasonCode: IMessageGatewayFailureCode?
    init(from decoder: Decoder) throws {
        let c = try hostedContainer(decoder, Keys.self, optional: [.result, .reasonCode])
        setupReference = try c.decode(String.self, forKey: .setupReference); generation = try c.decode(Int64.self, forKey: .generation)
        operation = try c.decode(IMessageGatewayOperation.self, forKey: .operation)
        result = try c.decodeIfPresent(IMessageHostedMetadataResult.self, forKey: .result)
        let reason = hostedNonempty(try c.decodeIfPresent(String.self, forKey: .reasonCode))
        reasonCode = reason.flatMap(IMessageGatewayFailureCode.init(rawValue:))
        guard hostedCanonical32(setupReference), generation > 0 else { throw IMessageHostedSetupError.invalidResponse }
        if let reason {
            guard reasonCode != nil, result == nil, Self.failures.contains(reason) else { throw IMessageHostedSetupError.invalidResponse }
        } else {
            guard result?.operation == operation else { throw IMessageHostedSetupError.invalidResponse }
        }
    }
    func requireMatch(_ request: IMessageHostedMetadataRequest) throws {
        guard setupReference == request.locator.setupReference, generation == request.locator.generation,
              operation == request.operation else { throw IMessageHostedSetupError.invalidResponse }
        switch (request.input, result) {
        case (.setupConversations(let input), .conversationsPage(let page)):
            guard page.conversations.count <= input.limit, input.snapshotToken.map({ $0 == page.snapshotToken }) ?? true,
                  !page.hasMore || page.nextPageToken != input.pageToken else { throw IMessageHostedSetupError.invalidResponse }
        case (.verifyConversations(let input), .verification(let verification)):
            guard verification.conversations.map(\.conversationID) == input.conversationIDs else { throw IMessageHostedSetupError.invalidResponse }
        default: break
        }
    }
    private static let failures: Set<String> = ["invalid_arguments", "capability_disabled", "scope_denied", "mac_offline", "mac_paused",
        "permission_required", "background_disabled", "messages_unavailable", "account_changed", "dependency_invalid",
        "payload_too_large", "provider_timeout", "busy", "rate_limited"]
    private enum Keys: String, CodingKey, CaseIterable { case setupReference = "setup_reference", generation, operation, result, reasonCode = "reason_code" }
}

/// Native-only hosted operations. The coordinator owns document and consent fences.
struct IMessageHostedSetupClient: Sendable {
    typealias ValidateScope = @MainActor @Sendable () async throws -> Void
    typealias ValidateFinalConsent = @MainActor @Sendable (IMessageSetupFinalConsent) async throws -> Void
    private let transport: any AgentBridgeHostedTransport
    init(transport: any AgentBridgeHostedTransport = AgentBridgeURLTransport()) { self.transport = transport }

    func displayContext(configuration: DesktopEnvironmentConfiguration, cookies: String,
                        expectedScope: IMessageHostedNativeScope, validateScope: ValidateScope) async throws -> IMessageHostedDisplayContext {
        let scope = try await currentScope(configuration, cookies: cookies, expected: expectedScope, validateScope: validateScope)
        let data = try await perform(configuration: configuration, cookies: cookies, path: "/user/mobile/bootstrap",
            method: "GET", status: 200, maximum: 65536, validateScope: validateScope)
        let context: IMessageHostedDisplayContext = try decode(data, maximum: 65536)
        guard context.naturalUserID == scope.naturalUserID, context.workspaceID == scope.workspaceID else {
            throw IMessageHostedSetupError.scopeChanged
        }
        return context
    }

    func approve(consent: IMessageSetupFinalConsent, evidence: IMessageSetupApprovalEvidence,
                 installation: DesktopControlInstallation, journey: IMessageHostedJourney, ticket: IMessageHostedEnrollmentTicket,
                 mode: IMessageHostedEnrollmentMode, macName: String, accountLabel: String,
                 configuration: DesktopEnvironmentConfiguration, now: Date = Date(),
                 validateCurrent: ValidateFinalConsent) async throws -> IMessageHostedApprovalReceipt {
        try validateApproval(consent, evidence: evidence, installation: installation, ticket: ticket,
            macName: macName, accountLabel: accountLabel, configuration: configuration, now: now)
        let digest = Data(SHA256.hash(data: Data(journey.setupReference.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let journeyExpiry = try IMessageGatewayWire.utcDate(journey.expiresAt)
        let ticketExpiry = try IMessageGatewayWire.utcDate(ticket.expiresAt)
        guard consent.intent.scope.setupReferenceSHA256 == digest, consent.intent.scope.generation == journey.generation,
              consent.intent.scope.expiresAt == journey.expiresAt, ticketExpiry <= journeyExpiry else {
            throw IMessageHostedSetupError.scopeChanged
        }
        if case .attach(let installationID) = mode, installationID != installation.installationID { throw IMessageHostedSetupError.scopeChanged }
        let request = HostedApprovalRequest(consent: consent, evidence: evidence, ticket: ticket.enrollmentTicket,
            setupReference: journey.setupReference, operation: mode == .enroll ? "enroll" : "attach", macName: macName, accountLabel: accountLabel)
        let data = try await approvalRequest(try JSONEncoder().encode(request), installation: installation,
            configuration: configuration, consent: consent, now: now, validateCurrent: validateCurrent)
        let response: HostedApprovalResponse = try decode(data, maximum: 4096)
        let expiry = try IMessageGatewayWire.utcDate(response.expiresAt)
        guard expiry > now, expiry <= journeyExpiry else { throw IMessageHostedSetupError.invalidResponse }
        return .init(value: response.setupReceipt, expiresAt: response.expiresAt, consent: consent, macName: macName)
    }

    func createConfiguration(receipt: IMessageHostedApprovalReceipt, consent: IMessageSetupFinalConsent,
                             configuration: DesktopEnvironmentConfiguration, cookies: String, csrf: String,
                             expectedScope: IMessageHostedNativeScope, now: Date = Date(),
                             validateCurrent: @escaping ValidateFinalConsent) async throws -> String {
        guard receipt.consent == consent, consent.environmentIdentity == configuration.preferenceIdentity,
              consent.intent.scope.userID == expectedScope.naturalUserID, consent.intent.scope.workspaceID == expectedScope.workspaceID,
              consent.deadline > now, try IMessageGatewayWire.utcDate(receipt.expiresAt) > now else {
            throw IMessageHostedSetupError.scopeChanged
        }
        let fence: ValidateScope = { try await validateCurrent(consent) }
        let scope = try await currentScope(configuration, cookies: cookies, expected: expectedScope, validateScope: fence)
        let body = try JSONEncoder().encode(HostedCreateRequest(setupReceipt: receipt.value, name: receipt.macName,
            conversationIDs: consent.conversations.map(\.conversationID), readEnabled: consent.readEnabled, sendEnabled: consent.sendEnabled))
        let data = try await perform(configuration: configuration, cookies: cookies, path: "/user/imessage/configs", method: "POST",
            body: body, workspace: scope.workspaceID, csrf: csrf, status: 201, validateScope: fence)
        let result: HostedCreatedResponse = try decode(data, maximum: 4096)
        return result.integrationConfigID
    }

    private func validateApproval(_ consent: IMessageSetupFinalConsent, evidence: IMessageSetupApprovalEvidence,
                                  installation: DesktopControlInstallation, ticket: IMessageHostedEnrollmentTicket,
                                  macName: String, accountLabel: String, configuration: DesktopEnvironmentConfiguration, now: Date) throws {
        try installation.requireEnvironment(configuration.appPageURL, configuration: configuration)
        guard consent.installationID == installation.installationID, consent.environmentIdentity == configuration.preferenceIdentity,
              consent.deadline > now, try IMessageGatewayWire.utcDate(ticket.expiresAt) > now,
              hostedDisplayLabel(macName), hostedDisplayLabel(accountLabel),
              evidence.readEnabled == consent.readEnabled, evidence.sendEnabled == consent.sendEnabled,
              evidence.verification.conversations == consent.conversations,
              evidence.verification.liveAccount == .init(accountID: consent.account.accountID,
                sourceGeneration: consent.account.sourceGeneration, chatGUIDs: consent.conversations.map(\.metadata.guid)) else {
            throw IMessageHostedSetupError.invalidRequest
        }
    }

    private func approvalRequest(_ body: Data, installation: DesktopControlInstallation,
                                 configuration: DesktopEnvironmentConfiguration, consent: IMessageSetupFinalConsent,
                                 now: Date, validateCurrent: ValidateFinalConsent) async throws -> Data {
        guard body.count <= IMessageGatewayWire.maximumResultBytes else {
            throw IMessageHostedSetupError.invalidRequest
        }
        let bearer: String
        do { bearer = try IMessageMachineSetupClient.canonicalProof(installation.machineCredential) }
        catch { throw IMessageHostedSetupError.invalidRequest }
        var parts = URLComponents(url: configuration.appURL, resolvingAgainstBaseURL: false)!
        parts.path = "/user/imessage/approve"; parts.query = nil; parts.fragment = nil
        var request = URLRequest(url: parts.url!, cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: min(10, consent.deadline.timeIntervalSince(now)))
        request.httpMethod = "POST"; request.httpBody = body; request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("macos-imessage-v1", forHTTPHeaderField: "X-PersonaStack-Native-Client")
        request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        try Task.checkCancellation(); try await validateCurrent(consent); try Task.checkCancellation()
        let data: Data, status: Int
        do { (data, status) = try await transport.request(request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw IMessageHostedSetupError.serviceUnavailable }
        try Task.checkCancellation(); try await validateCurrent(consent); try Task.checkCancellation()
        guard data.count <= 4096 else { throw IMessageHostedSetupError.invalidResponse }
        guard status == 201 else { throw Self.statusError(status) }
        return data
    }

    func nativeScope(configuration: DesktopEnvironmentConfiguration, cookies: String,
                     validateScope: ValidateScope) async throws -> IMessageHostedNativeScope {
        let data = try await perform(configuration: configuration, cookies: cookies, path: "/user/imessage/native-scope",
            method: "GET", status: 200, validateScope: validateScope)
        let scope: IMessageHostedNativeScope = try decode(data, maximum: 4096)
        guard scope.appOrigin == configuration.appOrigin else { throw IMessageHostedSetupError.scopeChanged }
        return scope
    }

    func createJourney(configuration: DesktopEnvironmentConfiguration, cookies: String, csrf: String,
                       expectedScope: IMessageHostedNativeScope, validateScope: ValidateScope) async throws -> IMessageHostedJourney {
        let scope = try await currentScope(configuration, cookies: cookies, expected: expectedScope, validateScope: validateScope)
        let data = try await perform(configuration: configuration, cookies: cookies, path: "/user/imessage/setup", method: "POST",
            body: Data("{}".utf8), workspace: scope.workspaceID, csrf: csrf, status: 201, validateScope: validateScope)
        let journey: IMessageHostedJourney = try decode(data, maximum: 4096)
        guard journey.generation == 1, !journey.macVerified, journey.integrationConfigID == nil else { throw IMessageHostedSetupError.invalidResponse }
        return journey
    }

    func readJourney(_ locator: IMessageHostedJourneyLocator, configuration: DesktopEnvironmentConfiguration, cookies: String,
                     expectedScope: IMessageHostedNativeScope, validateScope: ValidateScope) async throws -> IMessageHostedJourney {
        let scope = try await currentScope(configuration, cookies: cookies, expected: expectedScope, validateScope: validateScope)
        let query = [URLQueryItem(name: "setup_reference", value: locator.setupReference), URLQueryItem(name: "generation", value: String(locator.generation))]
        let data = try await perform(configuration: configuration, cookies: cookies, path: "/user/imessage/setup", method: "GET",
            query: query, workspace: scope.workspaceID, status: 200, validateScope: validateScope)
        let journey: IMessageHostedJourney = try decode(data, maximum: 4096)
        guard journey.setupReference == locator.setupReference, journey.generation >= locator.generation else { throw IMessageHostedSetupError.invalidResponse }
        return journey
    }

    func reauthorizeJourney(_ locator: IMessageHostedJourneyLocator, configuration: DesktopEnvironmentConfiguration, cookies: String, csrf: String,
                            expectedScope: IMessageHostedNativeScope, validateScope: ValidateScope) async throws -> IMessageHostedJourney {
        let scope = try await currentScope(configuration, cookies: cookies, expected: expectedScope, validateScope: validateScope)
        let data = try await perform(configuration: configuration, cookies: cookies, path: "/user/imessage/setup/reauthorize", method: "POST",
            body: try JSONEncoder().encode(locator), workspace: scope.workspaceID, csrf: csrf, status: 200, validateScope: validateScope)
        let journey: IMessageHostedJourney = try decode(data, maximum: 4096)
        guard journey.setupReference == locator.setupReference,
              journey.generation == locator.generation || journey.generation - locator.generation == 1 else { throw IMessageHostedSetupError.invalidResponse }
        return journey
    }

    func cancelJourney(_ locator: IMessageHostedJourneyLocator, configuration: DesktopEnvironmentConfiguration, cookies: String, csrf: String,
                       expectedScope: IMessageHostedNativeScope, validateScope: ValidateScope) async throws {
        let scope = try await currentScope(configuration, cookies: cookies, expected: expectedScope, validateScope: validateScope)
        let data = try await perform(configuration: configuration, cookies: cookies, path: "/user/imessage/setup/cancel", method: "POST",
            body: try JSONEncoder().encode(locator), workspace: scope.workspaceID, csrf: csrf, status: 204, validateScope: validateScope)
        guard data.isEmpty else { throw IMessageHostedSetupError.invalidResponse }
    }

    func enrollmentTicket(_ locator: IMessageHostedJourneyLocator, mode: IMessageHostedEnrollmentMode, credentialSHA256: String,
                          configuration: DesktopEnvironmentConfiguration, cookies: String, csrf: String,
                          expectedScope: IMessageHostedNativeScope, validateScope: ValidateScope) async throws -> IMessageHostedEnrollmentTicket {
        guard hostedCanonical32(credentialSHA256) else { throw IMessageHostedSetupError.invalidRequest }
        let request: EnrollmentRequest
        switch mode {
        case .enroll:
            request = .init(setupReference: locator.setupReference, generation: locator.generation,
                operation: .enroll, credentialSHA256: credentialSHA256, installationID: nil)
        case .attach(let installationID):
            guard hostedID(installationID) else { throw IMessageHostedSetupError.invalidRequest }
            request = .init(setupReference: locator.setupReference, generation: locator.generation,
                operation: .attach, credentialSHA256: credentialSHA256, installationID: installationID)
        }
        let body = try JSONEncoder().encode(request)
        let scope = try await currentScope(configuration, cookies: cookies, expected: expectedScope, validateScope: validateScope)
        let data = try await perform(configuration: configuration, cookies: cookies, path: "/user/imessage/enrollment-ticket", method: "POST",
            body: body, workspace: scope.workspaceID, csrf: csrf, status: 201, validateScope: validateScope)
        return try decode(data, maximum: 4096)
    }

    func executeMetadata(_ request: IMessageHostedMetadataRequest, configuration: DesktopEnvironmentConfiguration, cookies: String, csrf: String,
                         expectedScope: IMessageHostedNativeScope, validateScope: ValidateScope) async throws -> IMessageHostedMetadataResponse {
        let scope = try await currentScope(configuration, cookies: cookies, expected: expectedScope, validateScope: validateScope)
        let data = try await perform(configuration: configuration, cookies: cookies, path: "/user/imessage/setup/metadata", method: "POST",
            body: try JSONEncoder().encode(request), workspace: scope.workspaceID, csrf: csrf, status: 200, maximum: 65536,
            validateScope: validateScope)
        let response: IMessageHostedMetadataResponse = try decode(data, maximum: 65536)
        try response.requireMatch(request)
        return response
    }

    private func currentScope(_ configuration: DesktopEnvironmentConfiguration, cookies: String, expected: IMessageHostedNativeScope,
                              validateScope: ValidateScope) async throws -> IMessageHostedNativeScope {
        let current = try await nativeScope(configuration: configuration, cookies: cookies, validateScope: validateScope)
        guard current == expected else { throw IMessageHostedSetupError.scopeChanged }
        return current
    }

    private func perform(configuration: DesktopEnvironmentConfiguration, cookies: String, path: String, method: String,
                         query: [URLQueryItem]? = nil, body: Data? = nil, workspace: String? = nil, csrf: String? = nil,
                         status: Int, maximum: Int = 4096, validateScope: ValidateScope) async throws -> Data {
        try validateRequest(configuration: configuration, cookies: cookies, path: path, method: method,
            body: body, workspace: workspace, csrf: csrf)
        try Task.checkCancellation(); try await validateScope()
        try Task.checkCancellation()
        var parts = URLComponents(url: configuration.appURL, resolvingAgainstBaseURL: false)!
        parts.path = path; parts.queryItems = query
        var request = URLRequest(url: parts.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = method; request.httpBody = body; request.httpShouldHandleCookies = false
        request.setValue(cookies, forHTTPHeaderField: "Cookie"); request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("macos-imessage-v1", forHTTPHeaderField: "X-PersonaStack-Native-Client")
        if let workspace { request.setValue(workspace, forHTTPHeaderField: "X-PersonaStack-Workspace-ID") }
        if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue(csrf, forHTTPHeaderField: "X-CSRF-Token")
        }
        let data: Data, code: Int
        do { (data, code) = try await transport.request(request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw IMessageHostedSetupError.serviceUnavailable }
        try Task.checkCancellation(); try await validateScope()
        try Task.checkCancellation()
        guard data.count <= maximum else { throw IMessageHostedSetupError.invalidResponse }
        guard code == status else { throw Self.statusError(code) }
        return data
    }

    private func validateRequest(configuration: DesktopEnvironmentConfiguration, cookies: String, path: String, method: String,
                                 body: Data?, workspace: String?, csrf: String?) throws {
        let canonical = try? DesktopEnvironmentConfiguration(appURL: configuration.appURL.absoluteString,
            gatewayURL: configuration.gatewayURL.absoluteString, mcpURL: configuration.mcpURL.absoluteString)
        guard canonical == configuration, !cookies.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              cookies.utf8.count <= 16384, !hostedHasControls(cookies), (body?.count ?? 0) <= (path.hasSuffix("/metadata") ? 16384 : 4096) else {
            throw IMessageHostedSetupError.invalidRequest
        }
        if method == "POST" {
            guard let csrf, !csrf.isEmpty, csrf.utf8.count <= 512, !csrf.contains(where: \.isWhitespace), !hostedHasControls(csrf),
                  workspace.map(hostedID) == true else { throw IMessageHostedSetupError.invalidRequest }
        }
    }

    private static func statusError(_ code: Int) -> IMessageHostedSetupError {
        switch code {
        case 401: .authenticationRequired
        case 403, 404, 409: .scopeChanged
        case 429: .rateLimited
        default: .serviceUnavailable
        }
    }

    private func decode<T: Decodable>(_ data: Data, maximum: Int) throws -> T {
        do { try IMessageJSONDocument.validate(data: data, maximumBytes: maximum); return try JSONDecoder().decode(T.self, from: data) }
        catch { throw IMessageHostedSetupError.invalidResponse }
    }

    private struct EnrollmentRequest: Encodable {
        enum Operation: String, Encodable { case enroll, attach }
        let setupReference: String
        let generation: Int64
        let operation: Operation
        let credentialSHA256: String
        let installationID: String?
        private enum CodingKeys: String, CodingKey {
            case setupReference = "setup_reference", generation, operation, credentialSHA256 = "credential_sha256", installationID = "installation_id"
        }
    }
}

/// Display only. The separate native-scope response remains authority.
struct IMessageHostedDisplayContext: Decodable, Equatable, Sendable {
    let naturalUserID: String
    let workspaceID: String
    let workspaceName: String

    init(from decoder: Decoder) throws {
        let c = try hostedContainer(decoder, Keys.self, optional: [.organization])
        let natural = try c.decode(Identity.self, forKey: .naturalUser)
        let effective = try c.decode(User.self, forKey: .effectiveUser)
        let workspaces = try c.decode([Workspace].self, forKey: .workspaces)
        let activeWorkspaceID = try c.decode(String.self, forKey: .activeWorkspaceID)
        let authenticated = try c.decode(Bool.self, forKey: .authenticated)
        let impersonation = try c.decode(Bool.self, forKey: .impersonationActive)
        let noWorkspace = try c.decode(Bool.self, forKey: .noAccessibleWorkspace)
        guard authenticated, !impersonation, !noWorkspace, natural.id == effective.id,
              workspaces.count <= 256, Set(workspaces.map(\.id)).count == workspaces.count,
              let selected = workspaces.first(where: { $0.id == activeWorkspaceID }) else { throw IMessageHostedSetupError.scopeChanged }
        _ = try c.decode(String.self, forKey: .sessionExpiresAt)
        _ = try c.decode(String.self, forKey: .csrfToken)
        if c.contains(.organization) { _ = try c.decode(Organization.self, forKey: .organization) }
        naturalUserID = natural.id; workspaceID = activeWorkspaceID; workspaceName = selected.displayName
    }
    private enum Keys: String, CodingKey, CaseIterable {
        case authenticated, naturalUser = "natural_user", effectiveUser = "effective_user", organization
        case impersonationActive = "impersonation_active", sessionExpiresAt = "session_expires_at"
        case workspaces, activeWorkspaceID = "active_workspace_id", noAccessibleWorkspace = "no_accessible_workspace", csrfToken = "csrf_token"
    }
    private struct Identity: Decodable {
        let id: String
        init(from decoder: Decoder) throws {
            let c = try hostedContainer(decoder, Keys.self)
            id = try c.decode(String.self, forKey: .id)
            guard hostedID(id) else { throw IMessageHostedSetupError.invalidResponse }
            _ = try c.decode(String.self, forKey: .role)
        }
        enum Keys: String, CodingKey, CaseIterable { case id, role }
    }
    private struct User: Decodable {
        let id: String
        init(from decoder: Decoder) throws {
            let c = try hostedContainer(decoder, Keys.self)
            id = try c.decode(String.self, forKey: .id)
            guard hostedID(id) else { throw IMessageHostedSetupError.invalidResponse }
            for key in Keys.allCases where key != .id { _ = try c.decode(String.self, forKey: key) }
        }
        enum Keys: String, CodingKey, CaseIterable { case id, role, displayName = "display_name", email, avatarURL = "avatar_url", timeZone = "time_zone" }
    }
    private struct Workspace: Decodable {
        let id: String
        let displayName: String
        init(from decoder: Decoder) throws {
            let c = try hostedContainer(decoder, Keys.self)
            id = try c.decode(String.self, forKey: .id); displayName = try c.decode(String.self, forKey: .displayName)
            guard hostedID(id), !displayName.isEmpty, displayName.utf8.count <= 1024, !hostedHasControls(displayName) else {
                throw IMessageHostedSetupError.invalidResponse
            }
            for key in [Keys.status, .organizationID, .organizationName] { _ = try c.decode(String.self, forKey: key) }
            _ = try c.decode(Bool.self, forKey: .personal); _ = try c.decode(Bool.self, forKey: .workspaceAdmin)
        }
        enum Keys: String, CodingKey, CaseIterable {
            case id, displayName = "display_name", status, organizationID = "organization_id", organizationName = "organization_name"
            case personal, workspaceAdmin = "workspace_admin"
        }
    }
    private struct Organization: Decodable {
        init(from decoder: Decoder) throws {
            let c = try hostedContainer(decoder, Keys.self)
            guard hostedID(try c.decode(String.self, forKey: .id)) else { throw IMessageHostedSetupError.invalidResponse }
            _ = try c.decode(String.self, forKey: .displayName)
            _ = try c.decode(Bool.self, forKey: .canManageSettings)
        }
        enum Keys: String, CodingKey, CaseIterable { case id, displayName = "display_name", canManageSettings = "can_manage_settings" }
    }
}

struct IMessageHostedApprovalReceipt: Sendable, CustomStringConvertible, CustomReflectable {
    fileprivate let value: String
    let expiresAt: String
    fileprivate let consent: IMessageSetupFinalConsent
    fileprivate let macName: String
    var description: String { "IMessageHostedApprovalReceipt(<redacted>)" }
    var customMirror: Mirror { Mirror(self, children: ["receipt": "<redacted>"]) }
}

private struct HostedApprovalRequest: Encodable {
    let consent: IMessageSetupFinalConsent
    let evidence: IMessageSetupApprovalEvidence
    let ticket: String
    let setupReference: String
    let operation: String
    let macName: String
    let accountLabel: String
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(ticket, forKey: .enrollmentTicket); try c.encode(operation, forKey: .operation)
        try c.encode(setupReference, forKey: .setupReference)
        try c.encode(macName, forKey: .macName); try c.encode(accountLabel, forKey: .accountLabel)
        try c.encode(consent.intent.scope.generation, forKey: .generation); try c.encode(consent.installationID, forKey: .installationID)
        try c.encode(evidence.verification, forKey: .verification); try c.encode(evidence.checkpoint, forKey: .checkpoint)
        try c.encode(evidence.readEnabled, forKey: .readEnabled); try c.encode(evidence.sendEnabled, forKey: .sendEnabled)
    }
    enum Keys: String, CodingKey {
        case enrollmentTicket = "enrollment_ticket", operation, setupReference = "setup_reference", generation, installationID = "installation_id"
        case macName = "mac_name", accountLabel = "account_label", verification, checkpoint, readEnabled = "read_enabled", sendEnabled = "send_enabled"
    }
}
private struct HostedApprovalResponse: Decodable {
    let setupReceipt: String
    let expiresAt: String
    init(from decoder: Decoder) throws {
        let c = try hostedContainer(decoder, Keys.self)
        setupReceipt = try c.decode(String.self, forKey: .setupReceipt); expiresAt = try c.decode(String.self, forKey: .expiresAt)
        guard hostedCanonical32(setupReceipt) else { throw IMessageHostedSetupError.invalidResponse }
        _ = try IMessageGatewayWire.utcDate(expiresAt)
    }
    enum Keys: String, CodingKey, CaseIterable { case setupReceipt = "setup_receipt", expiresAt = "expires_at" }
}
private struct HostedCreateRequest: Encodable {
    let setupReceipt: String
    let name: String
    let conversationIDs: [String]
    let readEnabled: Bool
    let sendEnabled: Bool
    enum CodingKeys: String, CodingKey { case setupReceipt = "setup_receipt", name, conversationIDs = "conversation_ids", readEnabled = "read_enabled", sendEnabled = "send_enabled" }
}
private struct HostedCreatedResponse: Decodable {
    let integrationConfigID: String
    init(from decoder: Decoder) throws {
        let c = try hostedContainer(decoder, Keys.self); integrationConfigID = try c.decode(String.self, forKey: .integrationConfigID)
        guard hostedID(integrationConfigID) else { throw IMessageHostedSetupError.invalidResponse }
    }
    enum Keys: String, CodingKey, CaseIterable { case integrationConfigID = "integration_config_id" }
}
private func hostedDisplayLabel(_ value: String) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 256 && !hostedHasControls(value) }
private struct HostedAnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func hostedContainer<K: CodingKey & CaseIterable & Hashable>(_ decoder: Decoder, _ keys: K.Type,
                                                                  optional: Set<K> = []) throws -> KeyedDecodingContainer<K> {
    let all = try decoder.container(keyedBy: HostedAnyKey.self)
    let seen = Set(all.allKeys.map(\.stringValue)), allowed = Set(K.allCases.map(\.stringValue))
    guard seen.isSubset(of: allowed), allowed.subtracting(optional.map(\.stringValue)).isSubset(of: seen) else {
        throw IMessageHostedSetupError.invalidResponse
    }
    for key in all.allKeys { guard try !all.decodeNil(forKey: key) else { throw IMessageHostedSetupError.invalidResponse } }
    return try decoder.container(keyedBy: keys)
}
private func hostedHasControls(_ value: String) -> Bool { value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) }
private func hostedID(_ value: String) -> Bool {
    !value.isEmpty && value.unicodeScalars.count <= 256 && value.trimmingCharacters(in: .whitespacesAndNewlines) == value && !hostedHasControls(value)
}
private func hostedOpaqueID(_ value: String) -> Bool { value.utf8.count <= 256 && hostedID(value) }
private func hostedNonempty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
private func hostedCanonical32(_ value: String) -> Bool {
    guard value.utf8.count == 43,
          let data = Data(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="), data.count == 32 else { return false }
    return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "") == value
}
private func hostedOptionsValid(_ values: [IMessageHostedConversation], maximum: Int) -> Bool {
    values.count <= maximum && Set(values.map(\.conversationID)).count == values.count
}
