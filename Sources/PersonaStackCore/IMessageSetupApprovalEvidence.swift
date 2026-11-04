import Foundation

public enum IMessageSetupApprovalError: Error, Equatable, Sendable {
    case consentRequired, scopeChanged, selectionUnavailable, invalidEvidence
}

/// Created only by a trusted native final selection/capability confirmation.
/// It is deliberately not Codable and is distinct from metadata consent.
public struct IMessageSetupFinalConsent: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let consentID: UUID
    public let intent: IMessageRuntimeSetupIntent
    public let installationID: String
    public let environmentIdentity: String
    public let conversations: [IMessageGatewaySetupConversation]
    public let account: IMessageSetupAccount
    public let readEnabled: Bool
    public let sendEnabled: Bool
    public let confirmedAt: Date
    public let deadline: Date

    public init(consentID: UUID = UUID(), intent: IMessageRuntimeSetupIntent, installationID: String,
                environmentIdentity: String, conversations: [IMessageGatewaySetupConversation], account: IMessageSetupAccount,
                readEnabled: Bool, sendEnabled: Bool, selectionAndCapabilitiesConfirmed: Bool,
                confirmedAt: Date = Date(), deadline: Date) throws {
        guard selectionAndCapabilitiesConfirmed, readEnabled || sendEnabled else { throw IMessageSetupApprovalError.consentRequired }
        try IMessageGatewayWire.validate(IMessageGatewaySnapshot(installationID: installationID, revision: 1, setupScope: intent.scope))
        guard intent.scope.enabled, !environmentIdentity.isEmpty, environmentIdentity.utf8.count <= 6144,
              environmentIdentity == environmentIdentity.trimmingCharacters(in: .whitespacesAndNewlines),
              !environmentIdentity.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw IMessageSetupApprovalError.scopeChanged
        }
        let expiry = try IMessageGatewayWire.utcDate(intent.scope.expiresAt)
        let boundedDeadline = min(deadline, confirmedAt.addingTimeInterval(IMessageRuntime.commandLifetime), expiry)
        guard boundedDeadline > confirmedAt else { throw IMessageSetupProviderError.providerTimeout }
        try validateApprovalVerification(.init(conversations: conversations, liveAccount: .init(
            accountID: account.accountID, sourceGeneration: account.sourceGeneration, chatGUIDs: conversations.map(\.metadata.guid))))
        self.consentID = consentID; self.intent = intent; self.installationID = installationID
        self.environmentIdentity = environmentIdentity; self.conversations = conversations; self.account = account
        self.readEnabled = readEnabled; self.sendEnabled = sendEnabled; self.confirmedAt = confirmedAt; self.deadline = boundedDeadline
    }

    public var description: String { "IMessageSetupFinalConsent(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["consent": "<redacted>"]) }
}

/// Initial setup continuity only. This is never a receive activation cursor.
/// SQLite account hints and prior-anchor fields have no approval representation.
public struct IMessageSetupApprovalCheckpoint: Encodable, Equatable, Sendable {
    public struct Chat: Encodable, Equatable, Sendable {
        public let chatID: IMessageRowID
        public let guid: String
        public let service: String
        public let available: Bool
        public let tailRowID: IMessageRowID
        public let tailGUID: String
        public init(chatID: IMessageRowID, guid: String, service: String = "iMessage", available: Bool = true,
                    tailRowID: IMessageRowID, tailGUID: String) {
            self.chatID = chatID; self.guid = guid; self.service = service; self.available = available
            self.tailRowID = tailRowID; self.tailGUID = tailGUID
        }
        enum CodingKeys: String, CodingKey {
            case chatID = "chat_id", guid, service, available, tailRowID = "tail_rowid", tailGUID = "tail_guid"
        }
    }
    public let adapterRevision: Int
    public let sourceHighWater: IMessageRowID
    public let observedAt: String
    public let chats: [Chat]
    public init(adapterRevision: Int = 2, sourceHighWater: IMessageRowID, observedAt: String, chats: [Chat]) {
        self.adapterRevision = adapterRevision; self.sourceHighWater = sourceHighWater; self.observedAt = observedAt; self.chats = chats
    }
    public init(_ checkpoint: IMessageSourceCheckpoint) {
        self.init(adapterRevision: checkpoint.adapterRevision, sourceHighWater: checkpoint.sourceHighWater,
            observedAt: checkpoint.observedAt, chats: checkpoint.chats.map {
                Chat(chatID: $0.chatID, guid: $0.guid, service: $0.service, available: $0.available,
                     tailRowID: $0.tailRowID, tailGUID: $0.tailGUID)
            })
    }
    enum CodingKeys: String, CodingKey {
        case adapterRevision = "adapter_revision", sourceHighWater = "source_high_water", observedAt = "observed_at", chats
    }
}

/// Private native approval request material. Never project it into page replies,
/// logs or user-facing results. It contains no message body or machine proof.
public struct IMessageSetupApprovalEvidence: Encodable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let verification: IMessageGatewayVerificationResult
    public let checkpoint: IMessageSetupApprovalCheckpoint
    public let readEnabled: Bool
    public let sendEnabled: Bool

    public init(verification: IMessageGatewayVerificationResult, checkpoint: IMessageSetupApprovalCheckpoint,
                readEnabled: Bool, sendEnabled: Bool) throws {
        guard readEnabled || sendEnabled else { throw IMessageSetupApprovalError.consentRequired }
        try validateApprovalVerification(verification)
        guard checkpoint.adapterRevision == IMessageGatewayWire.providerAdapterRevision,
              checkpoint.chats.count == verification.conversations.count else { throw IMessageSetupApprovalError.invalidEvidence }
        _ = try IMessageGatewayWire.utcDate(checkpoint.observedAt)
        for (selected, chat) in zip(verification.conversations, checkpoint.chats) {
            guard chat.chatID == selected.metadata.id, chat.guid == selected.metadata.guid, chat.service == "iMessage", chat.available,
                  chat.tailRowID <= checkpoint.sourceHighWater, approvalText(chat.tailGUID),
                  (chat.tailRowID.value == 0) == chat.tailGUID.isEmpty else { throw IMessageSetupApprovalError.invalidEvidence }
        }
        self.verification = verification; self.checkpoint = checkpoint; self.readEnabled = readEnabled; self.sendEnabled = sendEnabled
    }

    public var description: String { "IMessageSetupApprovalEvidence(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["evidence": "<redacted>"]) }
    enum CodingKeys: String, CodingKey { case verification, checkpoint, readEnabled = "read_enabled", sendEnabled = "send_enabled" }
}

private func validateApprovalVerification(_ value: IMessageGatewayVerificationResult) throws {
    guard !value.conversations.isEmpty else { throw IMessageSetupApprovalError.invalidEvidence }
    guard value.conversations.allSatisfy({ $0.metadata.available }) else { throw IMessageSetupApprovalError.selectionUnavailable }
    try IMessageGatewayWire.validate(.verification(value))
    guard value.liveAccount != nil else { throw IMessageSetupApprovalError.invalidEvidence }
    for selected in value.conversations {
        let metadata = selected.metadata
        guard metadata.available else { throw IMessageSetupApprovalError.selectionUnavailable }
        guard approvalText(metadata.guid, nonempty: true), approvalText(metadata.name), !metadata.participants.isEmpty,
              metadata.participants.allSatisfy({ approvalText($0, nonempty: true) }) else { throw IMessageSetupApprovalError.invalidEvidence }
    }
}

private func approvalText(_ value: String, nonempty: Bool = false) -> Bool {
    value.utf8.count <= 256 && !value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) &&
    (!nonempty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
}
