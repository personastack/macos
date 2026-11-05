import Foundation

/// Private configured wire models. They establish structure, never current grants.
public enum IMessageGatewayHumanAction: String, Codable, Sendable { case check; case testSend = "test_send" }
public enum IMessageGatewayAttachmentKind: String, Codable, Sendable { case image, video, audio, file, unknown }
public enum IMessageGatewayNativeState: String, Codable, Sendable {
    case connected, reconnecting, offline, paused, disabled
    case needsAttention = "needs_attention"
}

public struct IMessageGatewayConversationBinding: Codable, Equatable, Sendable {
    public let conversationID: String
    public let nativeChatID: IMessageRowID
    public let nativeChatGUID: String
    public init(conversationID: String, nativeChatID: IMessageRowID, nativeChatGUID: String) {
        self.conversationID = conversationID
        self.nativeChatID = nativeChatID
        self.nativeChatGUID = nativeChatGUID
    }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self)
        conversationID = try c.decode(String.self, forKey: .conversationID)
        nativeChatID = try c.decode(IMessageRowID.self, forKey: .nativeChatID)
        nativeChatGUID = try c.decode(String.self, forKey: .nativeChatGUID)
        try IMessageConfiguredGatewayValidation.validate(self)
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case conversationID = "conversation_id"
        case nativeChatID = "native_chat_id"
        case nativeChatGUID = "native_chat_guid"
    }
}

public struct IMessageGatewayConfigScope: Codable, Equatable, Sendable {
    public let configID: String
    public let workspaceID: String
    public let configVersion: Int64
    public let accountGeneration: String
    public let sourceGeneration: String
    public let accountID: String
    public let conversationIDs: [String]
    public let conversationBindings: [IMessageGatewayConversationBinding]
    public let readEnabled: Bool
    public let sendEnabled: Bool
    public let paused: Bool
    public let revokedThrough: Int64
    public init(configID: String, workspaceID: String, configVersion: Int64, accountGeneration: String, sourceGeneration: String, accountID: String, conversationIDs: [String], conversationBindings: [IMessageGatewayConversationBinding], readEnabled: Bool, sendEnabled: Bool, paused: Bool = false, revokedThrough: Int64 = 0) {
        self.configID = configID
        self.workspaceID = workspaceID
        self.configVersion = configVersion
        self.accountGeneration = accountGeneration
        self.sourceGeneration = sourceGeneration
        self.accountID = accountID
        self.conversationIDs = conversationIDs
        self.conversationBindings = conversationBindings
        self.readEnabled = readEnabled
        self.sendEnabled = sendEnabled
        self.paused = paused
        self.revokedThrough = revokedThrough
    }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self)
        configID = try c.decode(String.self, forKey: .configID)
        workspaceID = try c.decode(String.self, forKey: .workspaceID)
        configVersion = try c.decode(Int64.self, forKey: .configVersion)
        accountGeneration = try c.decode(String.self, forKey: .accountGeneration)
        sourceGeneration = try c.decode(String.self, forKey: .sourceGeneration)
        accountID = try c.decode(String.self, forKey: .accountID)
        conversationIDs = try c.decode([String].self, forKey: .conversationIDs)
        conversationBindings = try c.decode([IMessageGatewayConversationBinding].self, forKey: .conversationBindings)
        readEnabled = try c.decode(Bool.self, forKey: .readEnabled)
        sendEnabled = try c.decode(Bool.self, forKey: .sendEnabled)
        paused = try c.decode(Bool.self, forKey: .paused)
        revokedThrough = try c.decode(Int64.self, forKey: .revokedThrough)
        try IMessageConfiguredGatewayValidation.validate(self)
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case configID = "config_id"
        case workspaceID = "workspace_id"
        case configVersion = "config_version"
        case accountGeneration = "account_generation"
        case sourceGeneration = "source_generation"
        case accountID = "account_id"
        case conversationIDs = "conversation_ids"
        case conversationBindings = "conversation_bindings"
        case readEnabled = "read_enabled"
        case sendEnabled = "send_enabled"
        case paused
        case revokedThrough = "revoked_through"
    }
}

public struct IMessageGatewayPersonaCaller: Codable, Equatable, Sendable {
    public let principalID: String
    public let personaID: String
    public let bindingVersion: Int64
    public let runID: String?
    public init(principalID: String, personaID: String, bindingVersion: Int64, runID: String? = nil) {
        self.principalID = principalID
        self.personaID = personaID
        self.bindingVersion = bindingVersion
        self.runID = gatewayNonempty(runID)
    }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self, optional: [.runID])
        principalID = try c.decode(String.self, forKey: .principalID)
        personaID = try c.decode(String.self, forKey: .personaID)
        bindingVersion = try c.decode(Int64.self, forKey: .bindingVersion)
        runID = gatewayNonempty(try c.decodeIfPresent(String.self, forKey: .runID))
        try IMessageConfiguredGatewayValidation.validate(self)
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case principalID = "principal_id"
        case personaID = "persona_id"
        case bindingVersion = "binding_version"
        case runID = "run_id"
    }
}

public struct IMessageGatewayStreamCaller: Codable, Equatable, Sendable {
    public let managerID: String
    public let streamID: String
    public let assignmentFence: Int64
    public init(managerID: String, streamID: String, assignmentFence: Int64) {
        self.managerID = managerID
        self.streamID = streamID
        self.assignmentFence = assignmentFence
    }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self)
        managerID = try c.decode(String.self, forKey: .managerID)
        streamID = try c.decode(String.self, forKey: .streamID)
        assignmentFence = try c.decode(Int64.self, forKey: .assignmentFence)
        try IMessageConfiguredGatewayValidation.validate(self)
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case managerID = "manager_id"
        case streamID = "stream_id"
        case assignmentFence = "assignment_fence"
    }
}

public struct IMessageGatewayHumanCaller: Codable, Equatable, Sendable {
    public let userID: String
    public let action: IMessageGatewayHumanAction
    public let conversationID: String?
    public let textSHA256: String?
    public init(userID: String, action: IMessageGatewayHumanAction, conversationID: String? = nil, textSHA256: String? = nil) {
        self.userID = userID
        self.action = action
        self.conversationID = gatewayNonempty(conversationID)
        self.textSHA256 = gatewayNonempty(textSHA256)
    }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self, optional: [.conversationID, .textSHA256])
        userID = try c.decode(String.self, forKey: .userID)
        action = try c.decode(IMessageGatewayHumanAction.self, forKey: .action)
        conversationID = gatewayNonempty(try c.decodeIfPresent(String.self, forKey: .conversationID))
        textSHA256 = gatewayNonempty(try c.decodeIfPresent(String.self, forKey: .textSHA256))
        try IMessageConfiguredGatewayValidation.validate(self)
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case userID = "user_id"
        case action
        case conversationID = "conversation_id"
        case textSHA256 = "text_sha256"
    }
}

public struct IMessageGatewayConfigIdentityInput: Codable, Equatable, Sendable {
    public let integrationID: String
    public init(integrationID: String) {
        self.integrationID = integrationID
    }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self)
        integrationID = try c.decode(String.self, forKey: .integrationID)
        try IMessageConfiguredGatewayValidation.validate(self)
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case integrationID = "integration_id"
    }
}

public struct IMessageGatewayConversationInput: Codable, Equatable, Sendable {
    public let integrationID: String
    public let conversationID: String
    public init(integrationID: String, conversationID: String) {
        self.integrationID = integrationID
        self.conversationID = conversationID
    }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self)
        integrationID = try c.decode(String.self, forKey: .integrationID)
        conversationID = try c.decode(String.self, forKey: .conversationID)
        try IMessageConfiguredGatewayValidation.validate(self)
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case integrationID = "integration_id"
        case conversationID = "conversation_id"
    }
}

public struct IMessageGatewayRecentMessagesInput: Codable, Equatable, Sendable {
    public let integrationID: String
    public let conversationID: String
    public let limit: Int?
    public init(integrationID: String, conversationID: String, limit: Int? = nil) {
        self.integrationID = integrationID
        self.conversationID = conversationID
        self.limit = limit
    }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self, optional: [.limit])
        integrationID = try c.decode(String.self, forKey: .integrationID)
        conversationID = try c.decode(String.self, forKey: .conversationID)
        limit = try c.decodeIfPresent(Int.self, forKey: .limit)
        try IMessageConfiguredGatewayValidation.validate(self)
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case integrationID = "integration_id"
        case conversationID = "conversation_id"
        case limit
    }
}

public struct IMessageGatewaySendMessageInput: Codable, Equatable, Sendable {
    public let integrationID: String
    public let conversationID: String
    public let clientRequestID: String
    public let text: String
    public init(integrationID: String, conversationID: String, clientRequestID: String, text: String) {
        self.integrationID = integrationID
        self.conversationID = conversationID
        self.clientRequestID = clientRequestID
        self.text = text
    }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self)
        integrationID = try c.decode(String.self, forKey: .integrationID)
        conversationID = try c.decode(String.self, forKey: .conversationID)
        clientRequestID = try c.decode(String.self, forKey: .clientRequestID)
        text = try c.decode(String.self, forKey: .text)
        try IMessageConfiguredGatewayValidation.validate(self)
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case integrationID = "integration_id"
        case conversationID = "conversation_id"
        case clientRequestID = "client_request_id"
        case text
    }
}

public struct IMessageGatewayReceivePageInput: Codable, Equatable, Sendable {
    public let conversationID: String
    public let after: IMessageRowID
    public let through: IMessageRowID?
    public let limit: Int
    public init(conversationID: String, after: IMessageRowID, through: IMessageRowID? = nil, limit: Int = 100) {
        self.conversationID = conversationID
        self.after = after
        self.through = through
        self.limit = limit
    }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self, optional: [.through])
        conversationID = try c.decode(String.self, forKey: .conversationID)
        after = try c.decode(IMessageRowID.self, forKey: .after)
        through = try c.decodeIfPresent(IMessageRowID.self, forKey: .through)
        limit = try c.decode(Int.self, forKey: .limit)
        try IMessageConfiguredGatewayValidation.validate(self)
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case conversationID = "conversation_id"
        case after
        case through
        case limit
    }
}

public struct IMessageGatewaySourceAnchor: Codable, Equatable, Sendable {
    public let conversationID: String
    public let rowID: IMessageRowID
    public let guid: String
    public init(conversationID: String, rowID: IMessageRowID, guid: String) {
        self.conversationID = conversationID
        self.rowID = rowID
        self.guid = guid
    }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self)
        conversationID = try c.decode(String.self, forKey: .conversationID)
        rowID = try c.decode(IMessageRowID.self, forKey: .rowID)
        guid = try c.decode(String.self, forKey: .guid)
        try IMessageConfiguredGatewayValidation.validate(self)
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case conversationID = "conversation_id"
        case rowID = "rowid"
        case guid
    }
}

public struct IMessageGatewaySourceCheckpointInput: Codable, Equatable, Sendable {
    public let conversationIDs: [String]
    public let anchors: [IMessageGatewaySourceAnchor]?
    public init(conversationIDs: [String], anchors: [IMessageGatewaySourceAnchor]? = nil) {
        self.conversationIDs = conversationIDs
        self.anchors = anchors?.isEmpty == true ? nil : anchors
    }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self, optional: [.anchors])
        conversationIDs = try c.decode([String].self, forKey: .conversationIDs)
        anchors = try c.decodeIfPresent([IMessageGatewaySourceAnchor].self, forKey: .anchors).flatMap { $0.isEmpty ? nil : $0 }
        try IMessageConfiguredGatewayValidation.validate(self)
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case conversationIDs = "conversation_ids"
        case anchors
    }
}

public struct IMessageGatewayPublicConversation: Codable, Equatable, Sendable {
    public let conversationID: String
    public let label: String
    public let participants: [String]
    public let isGroup: Bool
    public let service: String
    public let available: Bool
    public let lastMessageAt: String?
    public init(conversationID: String, label: String, participants: [String], isGroup: Bool, service: String = "imessage", available: Bool = true, lastMessageAt: String? = nil) {
        self.conversationID = conversationID
        self.label = label
        self.participants = participants
        self.isGroup = isGroup
        self.service = service
        self.available = available
        self.lastMessageAt = gatewayNonempty(lastMessageAt)
    }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self, optional: [.lastMessageAt])
        conversationID = try c.decode(String.self, forKey: .conversationID)
        label = try c.decode(String.self, forKey: .label)
        participants = try c.decode([String].self, forKey: .participants)
        isGroup = try c.decode(Bool.self, forKey: .isGroup)
        service = try c.decode(String.self, forKey: .service)
        available = try c.decode(Bool.self, forKey: .available)
        lastMessageAt = gatewayNonempty(try c.decodeIfPresent(String.self, forKey: .lastMessageAt))
        try IMessageConfiguredGatewayValidation.validate(self)
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case conversationID = "conversation_id"
        case label
        case participants
        case isGroup = "is_group"
        case service
        case available
        case lastMessageAt = "last_message_at"
    }
}

public struct IMessageGatewayAttachmentMetadata: Codable, Equatable, Sendable {
    public let attachmentID: String
    public let kind: IMessageGatewayAttachmentKind
    public let available: Bool
    public let name: String?
    public let mimeType: String?
    public let sizeBytes: Int64?
    public init(attachmentID: String, kind: IMessageGatewayAttachmentKind, available: Bool, name: String? = nil, mimeType: String? = nil, sizeBytes: Int64? = nil) {
        self.attachmentID = attachmentID
        self.kind = kind
        self.available = available
        self.name = gatewayNonempty(name)
        self.mimeType = gatewayNonempty(mimeType)
        self.sizeBytes = sizeBytes
    }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self, optional: [.name, .mimeType, .sizeBytes])
        attachmentID = try c.decode(String.self, forKey: .attachmentID)
        kind = try c.decode(IMessageGatewayAttachmentKind.self, forKey: .kind)
        available = try c.decode(Bool.self, forKey: .available)
        name = gatewayNonempty(try c.decodeIfPresent(String.self, forKey: .name))
        mimeType = gatewayNonempty(try c.decodeIfPresent(String.self, forKey: .mimeType))
        sizeBytes = try c.decodeIfPresent(Int64.self, forKey: .sizeBytes)
        try IMessageConfiguredGatewayValidation.validate(self)
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case attachmentID = "attachment_id"
        case kind
        case available
        case name
        case mimeType = "mime_type"
        case sizeBytes = "size_bytes"
    }
}

public struct IMessageGatewayPublicMessage: Codable, Equatable, Sendable {
    public let messageID: String
    public let conversationID: String
    public let sentAt: String
    public let sender: String
    public let isFromMe: Bool
    public let text: String
    public let textTruncated: Bool
    public let attachments: [IMessageGatewayAttachmentMetadata]
    public let attachmentCount: Int64
    public let senderLabel: String?
    public let replyToMessageID: String?
    public init(messageID: String, conversationID: String, sentAt: String, sender: String, isFromMe: Bool, text: String, textTruncated: Bool, attachments: [IMessageGatewayAttachmentMetadata], attachmentCount: Int64, senderLabel: String? = nil, replyToMessageID: String? = nil) {
        self.messageID = messageID
        self.conversationID = conversationID
        self.sentAt = sentAt
        self.sender = sender
        self.isFromMe = isFromMe
        self.text = text
        self.textTruncated = textTruncated
        self.attachments = attachments
        self.attachmentCount = attachmentCount
        self.senderLabel = gatewayNonempty(senderLabel)
        self.replyToMessageID = gatewayNonempty(replyToMessageID)
    }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self, optional: [.senderLabel, .replyToMessageID])
        messageID = try c.decode(String.self, forKey: .messageID)
        conversationID = try c.decode(String.self, forKey: .conversationID)
        sentAt = try c.decode(String.self, forKey: .sentAt)
        sender = try c.decode(String.self, forKey: .sender)
        isFromMe = try c.decode(Bool.self, forKey: .isFromMe)
        text = try c.decode(String.self, forKey: .text)
        textTruncated = try c.decode(Bool.self, forKey: .textTruncated)
        attachments = try c.decode([IMessageGatewayAttachmentMetadata].self, forKey: .attachments)
        attachmentCount = try c.decode(Int64.self, forKey: .attachmentCount)
        senderLabel = gatewayNonempty(try c.decodeIfPresent(String.self, forKey: .senderLabel))
        replyToMessageID = gatewayNonempty(try c.decodeIfPresent(String.self, forKey: .replyToMessageID))
        try IMessageConfiguredGatewayValidation.validate(self)
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case messageID = "message_id"
        case conversationID = "conversation_id"
        case sentAt = "sent_at"
        case sender
        case isFromMe = "is_from_me"
        case text
        case textTruncated = "text_truncated"
        case attachments
        case attachmentCount = "attachment_count"
        case senderLabel = "sender_label"
        case replyToMessageID = "reply_to_message_id"
    }
}

public struct IMessageGatewayNativeStatusResult: Codable, Equatable, Sendable {
    public let state: IMessageGatewayNativeState
    public let reasonCode: IMessageGatewayFailureCode?
    public let protocolVersion: Int
    public let adapterRevision: Int
    public init(state: IMessageGatewayNativeState, reasonCode: IMessageGatewayFailureCode? = nil, protocolVersion: Int = 1, adapterRevision: Int = 2) {
        self.state = state
        self.reasonCode = reasonCode
        self.protocolVersion = protocolVersion
        self.adapterRevision = adapterRevision
    }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self, optional: [.reasonCode])
        state = try c.decode(IMessageGatewayNativeState.self, forKey: .state)
        let rawReason = try c.decodeIfPresent(String.self, forKey: .reasonCode)
        if let rawReason, !rawReason.isEmpty {
            guard let code = IMessageGatewayFailureCode(rawValue: rawReason) else { throw IMessageGatewayWireError.invalidFrame }
            reasonCode = code
        } else { reasonCode = nil }
        protocolVersion = try c.decode(Int.self, forKey: .protocolVersion)
        adapterRevision = try c.decode(Int.self, forKey: .adapterRevision)
        try IMessageConfiguredGatewayValidation.validate(self)
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case state
        case reasonCode = "reason_code"
        case protocolVersion = "protocol_version"
        case adapterRevision = "adapter_revision"
    }
}

public struct IMessageGatewayConversationsResult: Codable, Equatable, Sendable {
    public let conversations: [IMessageGatewayPublicConversation]
    public init(conversations: [IMessageGatewayPublicConversation]) {
        self.conversations = conversations
    }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self)
        conversations = try c.decode([IMessageGatewayPublicConversation].self, forKey: .conversations)
        try IMessageConfiguredGatewayValidation.validate(self)
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case conversations
    }
}

public struct IMessageGatewayConversationResult: Codable, Equatable, Sendable {
    public let conversation: IMessageGatewayPublicConversation
    public init(conversation: IMessageGatewayPublicConversation) {
        self.conversation = conversation
    }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self)
        conversation = try c.decode(IMessageGatewayPublicConversation.self, forKey: .conversation)
        try IMessageConfiguredGatewayValidation.validate(self)
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case conversation
    }
}

public struct IMessageGatewayRecentMessagesResult: Codable, Equatable, Sendable {
    public let messages: [IMessageGatewayPublicMessage]
    public let windowLimit: Int
    public let truncated: Bool
    public init(messages: [IMessageGatewayPublicMessage], windowLimit: Int, truncated: Bool) {
        self.messages = messages
        self.windowLimit = windowLimit
        self.truncated = truncated
    }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self)
        messages = try c.decode([IMessageGatewayPublicMessage].self, forKey: .messages)
        windowLimit = try c.decode(Int.self, forKey: .windowLimit)
        truncated = try c.decode(Bool.self, forKey: .truncated)
        try IMessageConfiguredGatewayValidation.validate(self)
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case messages
        case windowLimit = "window_limit"
        case truncated
    }
}

public struct IMessageGatewaySendMessageResult: Codable, Equatable, Sendable {
    public let conversationID: String
    public let clientRequestID: String
    public let messageID: String
    public let outcome: String
    public let confirmedAt: String
    public init(conversationID: String, clientRequestID: String, messageID: String, outcome: String = "local_record_confirmed", confirmedAt: String) {
        self.conversationID = conversationID
        self.clientRequestID = clientRequestID
        self.messageID = messageID
        self.outcome = outcome
        self.confirmedAt = confirmedAt
    }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self)
        conversationID = try c.decode(String.self, forKey: .conversationID)
        clientRequestID = try c.decode(String.self, forKey: .clientRequestID)
        messageID = try c.decode(String.self, forKey: .messageID)
        outcome = try c.decode(String.self, forKey: .outcome)
        confirmedAt = try c.decode(String.self, forKey: .confirmedAt)
        try IMessageConfiguredGatewayValidation.validate(self)
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case conversationID = "conversation_id"
        case clientRequestID = "client_request_id"
        case messageID = "message_id"
        case outcome
        case confirmedAt = "confirmed_at"
    }
}

public struct IMessageGatewayReceiveRecord: Codable, Equatable, Sendable {
    public let rowID: IMessageRowID
    public let message: IMessageGatewayPublicMessage
    public let editedAt: String?
    public let unsentAt: String?
    public init(rowID: IMessageRowID, message: IMessageGatewayPublicMessage, editedAt: String? = nil, unsentAt: String? = nil) {
        self.rowID = rowID
        self.message = message
        self.editedAt = gatewayNonempty(editedAt)
        self.unsentAt = gatewayNonempty(unsentAt)
    }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self, optional: [.editedAt, .unsentAt])
        rowID = try c.decode(IMessageRowID.self, forKey: .rowID)
        message = try c.decode(IMessageGatewayPublicMessage.self, forKey: .message)
        editedAt = gatewayNonempty(try c.decodeIfPresent(String.self, forKey: .editedAt))
        unsentAt = gatewayNonempty(try c.decodeIfPresent(String.self, forKey: .unsentAt))
        try IMessageConfiguredGatewayValidation.validate(self)
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case rowID = "rowid"
        case message
        case editedAt = "edited_at"
        case unsentAt = "unsent_at"
    }
}

public struct IMessageGatewayReceivePageResult: Codable, Equatable, Sendable {
    public let sourceGeneration: String
    public let sourceHighWater: IMessageRowID
    public let messages: [IMessageGatewayReceiveRecord]
    public let nextRowID: IMessageRowID
    public let hasMore: Bool
    public let stopReason: IMessagePageStopReason
    public init(sourceGeneration: String, sourceHighWater: IMessageRowID, messages: [IMessageGatewayReceiveRecord], nextRowID: IMessageRowID, hasMore: Bool, stopReason: IMessagePageStopReason) {
        self.sourceGeneration = sourceGeneration
        self.sourceHighWater = sourceHighWater
        self.messages = messages
        self.nextRowID = nextRowID
        self.hasMore = hasMore
        self.stopReason = stopReason
    }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self)
        sourceGeneration = try c.decode(String.self, forKey: .sourceGeneration)
        sourceHighWater = try c.decode(IMessageRowID.self, forKey: .sourceHighWater)
        messages = try c.decode([IMessageGatewayReceiveRecord].self, forKey: .messages)
        nextRowID = try c.decode(IMessageRowID.self, forKey: .nextRowID)
        hasMore = try c.decode(Bool.self, forKey: .hasMore)
        stopReason = try c.decode(IMessagePageStopReason.self, forKey: .stopReason)
        try IMessageConfiguredGatewayValidation.validate(self)
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case sourceGeneration = "source_generation"
        case sourceHighWater = "source_high_water"
        case messages
        case nextRowID = "next_rowid"
        case hasMore = "has_more"
        case stopReason = "stop_reason"
    }
}

public struct IMessageGatewaySourceCheckpointConversation: Codable, Equatable, Sendable {
    public let conversationID: String
    public let chatGUID: String
    public let available: Bool
    public let tailRowID: IMessageRowID
    public let tailGUID: String
    public let anchorMatches: Bool?
    public init(conversationID: String, chatGUID: String, available: Bool, tailRowID: IMessageRowID, tailGUID: String, anchorMatches: Bool? = nil) {
        self.conversationID = conversationID
        self.chatGUID = chatGUID
        self.available = available
        self.tailRowID = tailRowID
        self.tailGUID = tailGUID
        self.anchorMatches = anchorMatches
    }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self, optional: [.anchorMatches])
        conversationID = try c.decode(String.self, forKey: .conversationID)
        chatGUID = try c.decode(String.self, forKey: .chatGUID)
        available = try c.decode(Bool.self, forKey: .available)
        tailRowID = try c.decode(IMessageRowID.self, forKey: .tailRowID)
        tailGUID = try c.decode(String.self, forKey: .tailGUID)
        anchorMatches = try c.decodeIfPresent(Bool.self, forKey: .anchorMatches)
        try IMessageConfiguredGatewayValidation.validate(self)
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case conversationID = "conversation_id"
        case chatGUID = "chat_guid"
        case available
        case tailRowID = "tail_rowid"
        case tailGUID = "tail_guid"
        case anchorMatches = "anchor_matches"
    }
}

public struct IMessageGatewaySourceCheckpointResult: Codable, Equatable, Sendable {
    public let accountID: String
    public let sourceGeneration: String
    public let sourceHighWater: IMessageRowID
    public let observedAt: String
    public let conversations: [IMessageGatewaySourceCheckpointConversation]
    public init(accountID: String, sourceGeneration: String, sourceHighWater: IMessageRowID, observedAt: String, conversations: [IMessageGatewaySourceCheckpointConversation]) {
        self.accountID = accountID
        self.sourceGeneration = sourceGeneration
        self.sourceHighWater = sourceHighWater
        self.observedAt = observedAt
        self.conversations = conversations
    }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self)
        accountID = try c.decode(String.self, forKey: .accountID)
        sourceGeneration = try c.decode(String.self, forKey: .sourceGeneration)
        sourceHighWater = try c.decode(IMessageRowID.self, forKey: .sourceHighWater)
        observedAt = try c.decode(String.self, forKey: .observedAt)
        conversations = try c.decode([IMessageGatewaySourceCheckpointConversation].self, forKey: .conversations)
        try IMessageConfiguredGatewayValidation.validate(self)
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case accountID = "account_id"
        case sourceGeneration = "source_generation"
        case sourceHighWater = "source_high_water"
        case observedAt = "observed_at"
        case conversations
    }
}

public enum IMessageGatewayConfiguredInput: Codable, Equatable, Sendable {
    case status(IMessageGatewayConfigIdentityInput)
    case conversations(IMessageGatewayConfigIdentityInput)
    case conversation(IMessageGatewayConversationInput)
    case recentMessages(IMessageGatewayRecentMessagesInput)
    case sendMessage(IMessageGatewaySendMessageInput)
    case receivePage(IMessageGatewayReceivePageInput)
    case sourceCheckpoint(IMessageGatewaySourceCheckpointInput)
    public var operationRawValue: String {
        switch self {
        case .status: "imessage_status"
        case .conversations: "imessage_conversations"
        case .conversation: "imessage_conversation"
        case .recentMessages: "imessage_recent_messages"
        case .sendMessage: "imessage_send_message"
        case .receivePage: "imessage_receive_page"
        case .sourceCheckpoint: "imessage_source_checkpoint"
        }
    }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self, optional: Set(CodingKeys.allCases))
        guard c.allKeys.count == 1, let key = c.allKeys.first else { throw IMessageGatewayWireError.invalidFrame }
        switch key {
        case .status: self = .status(try c.decode(IMessageGatewayConfigIdentityInput.self, forKey: key))
        case .conversations: self = .conversations(try c.decode(IMessageGatewayConfigIdentityInput.self, forKey: key))
        case .conversation: self = .conversation(try c.decode(IMessageGatewayConversationInput.self, forKey: key))
        case .recentMessages: self = .recentMessages(try c.decode(IMessageGatewayRecentMessagesInput.self, forKey: key))
        case .sendMessage: self = .sendMessage(try c.decode(IMessageGatewaySendMessageInput.self, forKey: key))
        case .receivePage: self = .receivePage(try c.decode(IMessageGatewayReceivePageInput.self, forKey: key))
        case .sourceCheckpoint: self = .sourceCheckpoint(try c.decode(IMessageGatewaySourceCheckpointInput.self, forKey: key))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .status(let value): try c.encode(value, forKey: .status)
        case .conversations(let value): try c.encode(value, forKey: .conversations)
        case .conversation(let value): try c.encode(value, forKey: .conversation)
        case .recentMessages(let value): try c.encode(value, forKey: .recentMessages)
        case .sendMessage(let value): try c.encode(value, forKey: .sendMessage)
        case .receivePage(let value): try c.encode(value, forKey: .receivePage)
        case .sourceCheckpoint(let value): try c.encode(value, forKey: .sourceCheckpoint)
        }
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case status
        case conversations
        case conversation
        case recentMessages = "recent_messages"
        case sendMessage = "send_message"
        case receivePage = "receive_page"
        case sourceCheckpoint = "source_checkpoint"
    }
}

public enum IMessageGatewayConfiguredResult: Codable, Equatable, Sendable {
    case status(IMessageGatewayNativeStatusResult)
    case conversations(IMessageGatewayConversationsResult)
    case conversation(IMessageGatewayConversationResult)
    case recentMessages(IMessageGatewayRecentMessagesResult)
    case sendMessage(IMessageGatewaySendMessageResult)
    case receivePage(IMessageGatewayReceivePageResult)
    case sourceCheckpoint(IMessageGatewaySourceCheckpointResult)
    public var operationRawValue: String {
        switch self {
        case .status: "imessage_status"
        case .conversations: "imessage_conversations"
        case .conversation: "imessage_conversation"
        case .recentMessages: "imessage_recent_messages"
        case .sendMessage: "imessage_send_message"
        case .receivePage: "imessage_receive_page"
        case .sourceCheckpoint: "imessage_source_checkpoint"
        }
    }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self, optional: Set(CodingKeys.allCases))
        guard c.allKeys.count == 1, let key = c.allKeys.first else { throw IMessageGatewayWireError.invalidFrame }
        switch key {
        case .status: self = .status(try c.decode(IMessageGatewayNativeStatusResult.self, forKey: key))
        case .conversations: self = .conversations(try c.decode(IMessageGatewayConversationsResult.self, forKey: key))
        case .conversation: self = .conversation(try c.decode(IMessageGatewayConversationResult.self, forKey: key))
        case .recentMessages: self = .recentMessages(try c.decode(IMessageGatewayRecentMessagesResult.self, forKey: key))
        case .sendMessage: self = .sendMessage(try c.decode(IMessageGatewaySendMessageResult.self, forKey: key))
        case .receivePage: self = .receivePage(try c.decode(IMessageGatewayReceivePageResult.self, forKey: key))
        case .sourceCheckpoint: self = .sourceCheckpoint(try c.decode(IMessageGatewaySourceCheckpointResult.self, forKey: key))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .status(let value): try c.encode(value, forKey: .status)
        case .conversations(let value): try c.encode(value, forKey: .conversations)
        case .conversation(let value): try c.encode(value, forKey: .conversation)
        case .recentMessages(let value): try c.encode(value, forKey: .recentMessages)
        case .sendMessage(let value): try c.encode(value, forKey: .sendMessage)
        case .receivePage(let value): try c.encode(value, forKey: .receivePage)
        case .sourceCheckpoint(let value): try c.encode(value, forKey: .sourceCheckpoint)
        }
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case status
        case conversations
        case conversation
        case recentMessages = "recent_messages"
        case sendMessage = "send_message"
        case receivePage = "receive_page"
        case sourceCheckpoint = "source_checkpoint"
    }
}

public struct IMessageGatewayNativeCommandRequest: Codable, Equatable, Sendable {
    public let command: IMessageGatewayCommand
    public init(command: IMessageGatewayCommand) { self.command = command }
    public init(from decoder: Decoder) throws {
        command = try gatewayContainer(decoder, CodingKeys.self).decode(IMessageGatewayCommand.self, forKey: .command)
        try IMessageGatewayWire.validate(command)
        guard case .configured = command.input else { throw IMessageGatewayWireError.invalidFrame }
    }
    enum CodingKeys: String, CodingKey, CaseIterable { case command }
}

public struct IMessageGatewayNativeAuthorizationResponse: Codable, Equatable, Sendable {
    public let authorized: Bool
    public let snapshot: IMessageGatewaySnapshot?
    public let reasonCode: IMessageGatewayFailureCode?
    public init(authorized: Bool, snapshot: IMessageGatewaySnapshot? = nil, reasonCode: IMessageGatewayFailureCode? = nil) {
        self.authorized = authorized; self.snapshot = snapshot; self.reasonCode = reasonCode
    }
    public init(from decoder: Decoder) throws {
        let c = try gatewayContainer(decoder, CodingKeys.self, optional: [.snapshot, .reasonCode])
        authorized = try c.decode(Bool.self, forKey: .authorized)
        snapshot = try c.decodeIfPresent(IMessageGatewaySnapshot.self, forKey: .snapshot)
        let rawReason = try c.decodeIfPresent(String.self, forKey: .reasonCode)
        if let rawReason, !rawReason.isEmpty {
            guard let code = IMessageGatewayFailureCode(rawValue: rawReason) else { throw IMessageGatewayWireError.invalidFrame }
            reasonCode = code
        } else { reasonCode = nil }
        if authorized {
            guard let snapshot, reasonCode == nil, snapshot.setupScope == nil, snapshot.configs.count == 1 else { throw IMessageGatewayWireError.invalidFrame }
            try IMessageGatewayWire.validate(snapshot)
        } else {
            guard snapshot == nil, reasonCode != nil else { throw IMessageGatewayWireError.invalidFrame }
        }
    }
    enum CodingKeys: String, CodingKey, CaseIterable { case authorized, snapshot, reasonCode = "reason_code" }
}
