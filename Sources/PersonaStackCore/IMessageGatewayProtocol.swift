import Foundation

public enum IMessageGatewayWireError: Error, Equatable, Sendable {
    case invalidFrame, frameTooLarge, resultTooLarge, correlationMismatch
}

public enum IMessageGatewayOperation: String, Codable, Sendable {
    case prerequisites = "imessage_prerequisites"
    case setupConversations = "imessage_setup_conversations"
    case verifyConversations = "imessage_verify_conversations"
}

public struct IMessageGatewaySetupScope: Codable, Equatable, Sendable {
    public let setupReferenceSHA256: String
    public let generation: Int64
    public let workspaceID: String
    public let userID: String
    public let expiresAt: String
    public let enabled: Bool
    public init(setupReferenceSHA256: String, generation: Int64, workspaceID: String, userID: String, expiresAt: String, enabled: Bool) {
        self.setupReferenceSHA256 = setupReferenceSHA256; self.generation = generation
        self.workspaceID = workspaceID; self.userID = userID; self.expiresAt = expiresAt; self.enabled = enabled
    }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self)
        setupReferenceSHA256 = try c.decode(String.self, forKey: .setupReferenceSHA256)
        generation = try c.decode(Int64.self, forKey: .generation)
        workspaceID = try c.decode(String.self, forKey: .workspaceID)
        userID = try c.decode(String.self, forKey: .userID)
        expiresAt = try c.decode(String.self, forKey: .expiresAt)
        enabled = try c.decode(Bool.self, forKey: .enabled)
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case setupReferenceSHA256 = "setup_reference_sha256", generation, workspaceID = "workspace_id"
        case userID = "user_id", expiresAt = "expires_at", enabled
    }
}

/// This unreleased wire admits setup metadata only. Config authority has no
/// native representation until its separate execution owner is implemented.
public struct IMessageGatewaySnapshot: Codable, Equatable, Sendable {
    public let installationID: String
    public let revision: Int64
    public let setupScope: IMessageGatewaySetupScope?
    public init(installationID: String, revision: Int64, setupScope: IMessageGatewaySetupScope? = nil) {
        self.installationID = installationID; self.revision = revision; self.setupScope = setupScope
    }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self, optional: [.setupScope])
        installationID = try c.decode(String.self, forKey: .installationID)
        revision = try c.decode(Int64.self, forKey: .revision)
        let configs = try c.nestedUnkeyedContainer(forKey: .configs)
        guard configs.isAtEnd else { throw IMessageGatewayWireError.invalidFrame }
        setupScope = try c.decodeIfPresent(IMessageGatewaySetupScope.self, forKey: .setupScope)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(installationID, forKey: .installationID); try c.encode(revision, forKey: .revision)
        _ = c.nestedUnkeyedContainer(forKey: .configs)
        try c.encodeIfPresent(setupScope, forKey: .setupScope)
    }
    enum CodingKeys: String, CodingKey, CaseIterable { case installationID = "installation_id", revision, configs, setupScope = "setup_scope" }
}

public struct IMessageGatewaySnapshotAck: Codable, Equatable, Sendable {
    public let revision: Int64
    public init(revision: Int64) { self.revision = revision }
    public init(from decoder: Decoder) throws { revision = try gatewayContainer(decoder, CodingKeys.self).decode(Int64.self, forKey: .revision) }
    enum CodingKeys: String, CodingKey, CaseIterable { case revision }
}

public struct IMessageGatewayTarget: Codable, Equatable, Sendable {
    public let installationID: String
    public let workspaceID: String
    public let snapshotRevision: Int64
    public init(installationID: String, workspaceID: String, snapshotRevision: Int64) {
        self.installationID = installationID; self.workspaceID = workspaceID; self.snapshotRevision = snapshotRevision
    }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self, optional: [.configID, .configVersion, .accountGeneration, .sourceGeneration])
        installationID = try c.decode(String.self, forKey: .installationID)
        workspaceID = try c.decode(String.self, forKey: .workspaceID)
        snapshotRevision = try c.decode(Int64.self, forKey: .snapshotRevision)
        // Go accepts explicitly supplied zero optional fields. They confer no
        // setup authority and canonical re-encoding omits them.
        guard try c.decodeIfPresent(String.self, forKey: .configID) ?? "" == "",
              try c.decodeIfPresent(Int64.self, forKey: .configVersion) ?? 0 == 0,
              try c.decodeIfPresent(String.self, forKey: .accountGeneration) ?? "" == "",
              try c.decodeIfPresent(String.self, forKey: .sourceGeneration) ?? "" == "" else { throw IMessageGatewayWireError.invalidFrame }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(installationID, forKey: .installationID); try c.encode(workspaceID, forKey: .workspaceID)
        try c.encode(snapshotRevision, forKey: .snapshotRevision)
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case installationID = "installation_id", workspaceID = "workspace_id", snapshotRevision = "snapshot_revision"
        case configID = "config_id", configVersion = "config_version", accountGeneration = "account_generation", sourceGeneration = "source_generation"
    }
}

public struct IMessageGatewaySetupCaller: Codable, Equatable, Sendable {
    public let userID: String
    public let setupReference: String
    public let setupGeneration: Int64
    public init(userID: String, setupReference: String, setupGeneration: Int64) {
        self.userID = userID; self.setupReference = setupReference; self.setupGeneration = setupGeneration
    }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self)
        userID = try c.decode(String.self, forKey: .userID); setupReference = try c.decode(String.self, forKey: .setupReference)
        setupGeneration = try c.decode(Int64.self, forKey: .setupGeneration)
    }
    enum CodingKeys: String, CodingKey, CaseIterable { case userID = "user_id", setupReference = "setup_reference", setupGeneration = "setup_generation" }
}

public struct IMessageGatewayCaller: Codable, Equatable, Sendable {
    public let setupSession: IMessageGatewaySetupCaller
    public init(setupSession: IMessageGatewaySetupCaller) { self.setupSession = setupSession }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self)
        guard try c.decode(String.self, forKey: .kind) == "setup_session" else { throw IMessageGatewayWireError.invalidFrame }
        setupSession = try c.decode(IMessageGatewaySetupCaller.self, forKey: .setupSession)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("setup_session", forKey: .kind); try c.encode(setupSession, forKey: .setupSession)
    }
    enum CodingKeys: String, CodingKey, CaseIterable { case kind, setupSession = "setup_session" }
}

public struct IMessageGatewaySetupConversationsInput: Codable, Equatable, Sendable {
    public let query: String
    public let snapshotToken: String?
    public let pageToken: String?
    public let limit: Int
    public init(query: String = "", snapshotToken: String? = nil, pageToken: String? = nil, limit: Int = 50) {
        self.query = query; self.snapshotToken = gatewayNonempty(snapshotToken); self.pageToken = gatewayNonempty(pageToken); self.limit = limit
    }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self, optional: [.snapshotToken, .pageToken])
        query = try c.decode(String.self, forKey: .query); limit = try c.decode(Int.self, forKey: .limit)
        snapshotToken = gatewayNonempty(try c.decodeIfPresent(String.self, forKey: .snapshotToken))
        pageToken = gatewayNonempty(try c.decodeIfPresent(String.self, forKey: .pageToken))
    }
    enum CodingKeys: String, CodingKey, CaseIterable { case query, snapshotToken = "snapshot_token", pageToken = "page_token", limit }
}

public struct IMessageGatewayVerifyConversationsInput: Codable, Equatable, Sendable {
    public let conversationIDs: [String]
    public init(conversationIDs: [String]) { self.conversationIDs = conversationIDs }
    public init(from decoder: Decoder) throws { conversationIDs = try gatewayContainer(decoder, CodingKeys.self).decode([String].self, forKey: .conversationIDs) }
    enum CodingKeys: String, CodingKey, CaseIterable { case conversationIDs = "conversation_ids" }
}

public enum IMessageGatewayCommandInput: Codable, Equatable, Sendable {
    case prerequisites
    case setupConversations(IMessageGatewaySetupConversationsInput)
    case verifyConversations(IMessageGatewayVerifyConversationsInput)
    public var operation: IMessageGatewayOperation {
        switch self { case .prerequisites: .prerequisites; case .setupConversations: .setupConversations; case .verifyConversations: .verifyConversations }
    }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self, optional: Set(CodingKeys.allCases))
        guard c.allKeys.count == 1, let key = c.allKeys.first else { throw IMessageGatewayWireError.invalidFrame }
        switch key {
        case .prerequisites: _ = try gatewayContainer(c.superDecoder(forKey: key), IMessageGatewayEmptyKeys.self); self = .prerequisites
        case .setupConversations: self = .setupConversations(try c.decode(IMessageGatewaySetupConversationsInput.self, forKey: key))
        case .verifyConversations: self = .verifyConversations(try c.decode(IMessageGatewayVerifyConversationsInput.self, forKey: key))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .prerequisites: _ = c.nestedContainer(keyedBy: IMessageGatewayEmptyKeys.self, forKey: .prerequisites)
        case .setupConversations(let input): try c.encode(input, forKey: .setupConversations)
        case .verifyConversations(let input): try c.encode(input, forKey: .verifyConversations)
        }
    }
    enum CodingKeys: String, CodingKey, CaseIterable { case prerequisites, setupConversations = "setup_conversations", verifyConversations = "verify_conversations" }
}

public struct IMessageGatewayCommand: Codable, Equatable, Sendable {
    public let requestID: String
    public let authorizationID: String
    public let deadlineAt: String
    public let target: IMessageGatewayTarget
    public let caller: IMessageGatewayCaller
    public let operation: IMessageGatewayOperation
    public let input: IMessageGatewayCommandInput
    public init(requestID: String, authorizationID: String, deadlineAt: String, target: IMessageGatewayTarget,
                caller: IMessageGatewayCaller, input: IMessageGatewayCommandInput) {
        self.requestID = requestID; self.authorizationID = authorizationID; self.deadlineAt = deadlineAt
        self.target = target; self.caller = caller; self.input = input; self.operation = input.operation
    }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self, optional: [.sendAttemptID])
        requestID = try c.decode(String.self, forKey: .requestID); authorizationID = try c.decode(String.self, forKey: .authorizationID)
        deadlineAt = try c.decode(String.self, forKey: .deadlineAt); target = try c.decode(IMessageGatewayTarget.self, forKey: .target)
        caller = try c.decode(IMessageGatewayCaller.self, forKey: .caller); operation = try c.decode(IMessageGatewayOperation.self, forKey: .operation)
        input = try c.decode(IMessageGatewayCommandInput.self, forKey: .input)
        guard try c.decodeIfPresent(String.self, forKey: .sendAttemptID) ?? "" == "" else { throw IMessageGatewayWireError.invalidFrame }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(requestID, forKey: .requestID); try c.encode(authorizationID, forKey: .authorizationID)
        try c.encode(deadlineAt, forKey: .deadlineAt); try c.encode(target, forKey: .target)
        try c.encode(caller, forKey: .caller); try c.encode(operation, forKey: .operation); try c.encode(input, forKey: .input)
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case requestID = "request_id", authorizationID = "authorization_id", sendAttemptID = "send_attempt_id"
        case deadlineAt = "deadline_at", target, caller, operation, input
    }
}

public struct IMessageGatewayPrerequisitesResult: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let adapterRevision: Int
    public let databaseReady: Bool
    public init(protocolVersion: Int = 1, adapterRevision: Int = 2, databaseReady: Bool) {
        self.protocolVersion = protocolVersion; self.adapterRevision = adapterRevision; self.databaseReady = databaseReady
    }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self)
        protocolVersion = try c.decode(Int.self, forKey: .protocolVersion); adapterRevision = try c.decode(Int.self, forKey: .adapterRevision)
        databaseReady = try c.decode(Bool.self, forKey: .databaseReady)
    }
    enum CodingKeys: String, CodingKey, CaseIterable { case protocolVersion = "protocol_version", adapterRevision = "adapter_revision", databaseReady = "database_ready" }
}

public struct IMessageGatewaySetupConversation: Codable, Equatable, Sendable {
    public let conversationID: String
    public let metadata: IMessageConversation
    public init(conversationID: String, metadata: IMessageConversation) { self.conversationID = conversationID; self.metadata = metadata }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self)
        conversationID = try c.decode(String.self, forKey: .conversationID)
        let nested = try c.superDecoder(forKey: .metadata)
        _ = try gatewayContainer(nested, IMessageConversation.CodingKeys.self, optional: [.accountID, .accountLogin])
        metadata = try IMessageConversation(from: nested)
    }
    enum CodingKeys: String, CodingKey, CaseIterable { case conversationID = "conversation_id", metadata }
}

public struct IMessageGatewayConversationsPageResult: Codable, Equatable, Sendable {
    public let snapshotToken: String
    public let nextPageToken: String?
    public let conversations: [IMessageGatewaySetupConversation]
    public let nextChatRowID: IMessageRowID
    public let upperChatRowID: IMessageRowID
    public let hasMore: Bool
    public let stopReason: IMessagePageStopReason
    public init(snapshotToken: String, nextPageToken: String? = nil, conversations: [IMessageGatewaySetupConversation],
                nextChatRowID: IMessageRowID, upperChatRowID: IMessageRowID, hasMore: Bool, stopReason: IMessagePageStopReason) {
        self.snapshotToken = snapshotToken; self.nextPageToken = gatewayNonempty(nextPageToken); self.conversations = conversations
        self.nextChatRowID = nextChatRowID; self.upperChatRowID = upperChatRowID; self.hasMore = hasMore; self.stopReason = stopReason
    }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self, optional: [.nextPageToken])
        snapshotToken = try c.decode(String.self, forKey: .snapshotToken)
        nextPageToken = gatewayNonempty(try c.decodeIfPresent(String.self, forKey: .nextPageToken))
        conversations = try c.decode([IMessageGatewaySetupConversation].self, forKey: .conversations)
        nextChatRowID = try c.decode(IMessageRowID.self, forKey: .nextChatRowID); upperChatRowID = try c.decode(IMessageRowID.self, forKey: .upperChatRowID)
        hasMore = try c.decode(Bool.self, forKey: .hasMore); stopReason = try c.decode(IMessagePageStopReason.self, forKey: .stopReason)
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case snapshotToken = "snapshot_token", nextPageToken = "next_page_token", conversations
        case nextChatRowID = "next_chat_rowid", upperChatRowID = "upper_chat_rowid", hasMore = "has_more", stopReason = "stop_reason"
    }
}

public struct IMessageGatewayLiveAccountEvidence: Codable, Equatable, Sendable {
    public let accountID: String
    public let sourceGeneration: String
    public let chatGUIDs: [String]
    public init(accountID: String, sourceGeneration: String, chatGUIDs: [String]) {
        self.accountID = accountID; self.sourceGeneration = sourceGeneration; self.chatGUIDs = chatGUIDs
    }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self)
        accountID = try c.decode(String.self, forKey: .accountID); sourceGeneration = try c.decode(String.self, forKey: .sourceGeneration)
        chatGUIDs = try c.decode([String].self, forKey: .chatGUIDs)
    }
    enum CodingKeys: String, CodingKey, CaseIterable { case accountID = "account_id", sourceGeneration = "source_generation", chatGUIDs = "chat_guids" }
}

public struct IMessageGatewayVerificationResult: Codable, Equatable, Sendable {
    public let conversations: [IMessageGatewaySetupConversation]
    public let liveAccount: IMessageGatewayLiveAccountEvidence?
    public init(conversations: [IMessageGatewaySetupConversation], liveAccount: IMessageGatewayLiveAccountEvidence? = nil) {
        self.conversations = conversations; self.liveAccount = liveAccount
    }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self, optional: [.liveAccount])
        conversations = try c.decode([IMessageGatewaySetupConversation].self, forKey: .conversations)
        liveAccount = try c.decodeIfPresent(IMessageGatewayLiveAccountEvidence.self, forKey: .liveAccount)
    }
    enum CodingKeys: String, CodingKey, CaseIterable { case conversations, liveAccount = "live_account" }
}

public enum IMessageGatewaySetupResult: Codable, Equatable, Sendable {
    case prerequisites(IMessageGatewayPrerequisitesResult)
    case conversationsPage(IMessageGatewayConversationsPageResult)
    case verification(IMessageGatewayVerificationResult)
    public var operation: IMessageGatewayOperation {
        switch self { case .prerequisites: .prerequisites; case .conversationsPage: .setupConversations; case .verification: .verifyConversations }
    }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self, optional: Set(CodingKeys.allCases))
        guard c.allKeys.count == 1, let key = c.allKeys.first else { throw IMessageGatewayWireError.invalidFrame }
        switch key {
        case .prerequisites: self = .prerequisites(try c.decode(IMessageGatewayPrerequisitesResult.self, forKey: key))
        case .conversationsPage: self = .conversationsPage(try c.decode(IMessageGatewayConversationsPageResult.self, forKey: key))
        case .verification: self = .verification(try c.decode(IMessageGatewayVerificationResult.self, forKey: key))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .prerequisites(let value): try c.encode(value, forKey: .prerequisites)
        case .conversationsPage(let value): try c.encode(value, forKey: .conversationsPage)
        case .verification(let value): try c.encode(value, forKey: .verification)
        }
    }
    enum CodingKeys: String, CodingKey, CaseIterable { case prerequisites, conversationsPage = "conversations_page", verification }
}

public enum IMessageGatewayFailureCode: String, Codable, Sendable {
    case invalidArguments = "invalid_arguments", integrationUnassigned = "integration_unassigned", capabilityDisabled = "capability_disabled"
    case scopeDenied = "scope_denied", configConflict = "config_conflict", macOffline = "mac_offline", macPaused = "mac_paused"
    case permissionRequired = "permission_required", backgroundDisabled = "background_disabled", messagesUnavailable = "messages_unavailable"
    case accountChanged = "account_changed", dependencyInvalid = "dependency_invalid", catchupGap = "catchup_gap", payloadTooLarge = "payload_too_large"
    case providerTimeout = "provider_timeout", busy, rateLimited = "rate_limited", outcomeUnknown = "outcome_unknown"
    case requestConflict = "request_conflict", requestInProgress = "request_in_progress", statusUnavailable = "status_unavailable"
}

public struct IMessageGatewayFailure: Codable, Equatable, Sendable {
    public let code: IMessageGatewayFailureCode
    public let message: String
    public let retrySafe: Bool
    public init(code: IMessageGatewayFailureCode, message: String, retrySafe: Bool = true) {
        self.code = code; self.message = message; self.retrySafe = retrySafe
    }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self, optional: [.clientRequestID])
        code = try c.decode(IMessageGatewayFailureCode.self, forKey: .code); message = try c.decode(String.self, forKey: .message)
        retrySafe = try c.decode(Bool.self, forKey: .retrySafe)
        guard try c.decodeIfPresent(String.self, forKey: .clientRequestID) ?? "" == "" else { throw IMessageGatewayWireError.invalidFrame }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(code, forKey: .code); try c.encode(message, forKey: .message); try c.encode(retrySafe, forKey: .retrySafe)
    }
    enum CodingKeys: String, CodingKey, CaseIterable { case code, message, retrySafe = "retry_safe", clientRequestID = "client_request_id" }
}

public enum IMessageGatewayPayload: Codable, Equatable, Sendable {
    case snapshot(IMessageGatewaySnapshot)
    case snapshotAck(IMessageGatewaySnapshotAck)
    case command(IMessageGatewayCommand)
    case result(IMessageGatewaySetupResult)
    case failure(IMessageGatewayFailure)
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self, optional: Set(CodingKeys.allCases))
        guard c.allKeys.count == 1, let key = c.allKeys.first else { throw IMessageGatewayWireError.invalidFrame }
        switch key {
        case .snapshot: self = .snapshot(try c.decode(IMessageGatewaySnapshot.self, forKey: key))
        case .snapshotAck: self = .snapshotAck(try c.decode(IMessageGatewaySnapshotAck.self, forKey: key))
        case .command: self = .command(try c.decode(IMessageGatewayCommand.self, forKey: key))
        case .result: self = .result(try c.decode(IMessageGatewaySetupResult.self, forKey: key))
        case .failure: self = .failure(try c.decode(IMessageGatewayFailure.self, forKey: key))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .snapshot(let value): try c.encode(value, forKey: .snapshot)
        case .snapshotAck(let value): try c.encode(value, forKey: .snapshotAck)
        case .command(let value): try c.encode(value, forKey: .command)
        case .result(let value): try c.encode(value, forKey: .result)
        case .failure(let value): try c.encode(value, forKey: .failure)
        }
    }
    enum CodingKeys: String, CodingKey, CaseIterable { case snapshot, snapshotAck = "snapshot_ack", command, result, failure }
}

extension IMessageConversation: Encodable {
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(guid, forKey: .guid); try c.encode(name, forKey: .name)
        try c.encode(service, forKey: .service); try c.encode(isGroup, forKey: .isGroup); try c.encode(available, forKey: .available)
        try c.encode(participants, forKey: .participants); try c.encodeIfPresent(accountID, forKey: .accountID); try c.encodeIfPresent(accountLogin, forKey: .accountLogin)
    }
}

extension IMessageConversation.CodingKeys: CaseIterable {
    static var allCases: [Self] { [.id, .guid, .name, .service, .isGroup, .available, .participants, .accountID, .accountLogin] }
}

internal struct IMessageGatewayEmptyKeys: CodingKey, CaseIterable, Hashable {
    static let allCases: [Self] = []
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { return nil }
    init?(intValue: Int) { return nil }
}
internal func gatewayNonempty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
