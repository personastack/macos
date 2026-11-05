import Foundation

/// Mirrors the finite configured producer. Current membership and grants stay API-owned.
public enum IMessageConfiguredGatewayValidation {
    public static let wireVersion = 2
    public static let providerVersion = 1
    public static let adapterRevision = 2
    public static let maximumResultBytes = 1 << 20
    public static let maximumCommandControlBytes = 256 * 1024

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data, maximumBytes: Int = maximumResultBytes) throws -> T {
        try IMessageJSONDocument.validate(data: data, maximumBytes: maximumBytes)
        return try JSONDecoder().decode(type, from: data)
    }
    public static func resultBytes<T: Encodable>(_ value: T) throws -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var count = bytes.count
            for index in bytes.indices {
                switch bytes[index] {
                case 0x3c, 0x3e, 0x26: count += 5
                case 0xe2:
                    if index + 2 < bytes.count, bytes[index + 1] == 0x80,
                       bytes[index + 2] == 0xa8 || bytes[index + 2] == 0xa9 { count += 3 }
                default: break
                }
            }
            return count
        }
    }

    private static func require(_ condition: Bool) throws {
        guard condition else { throw IMessageGatewayWireError.invalidFrame }
    }
    private static func text(_ value: String, minimum: Int = 0, maximum: Int = 256) -> Bool {
        (minimum...maximum).contains(value.unicodeScalars.count)
    }
    private static func identifier(_ value: String) -> Bool {
        text(value, minimum: 1) && value.trimmingCharacters(in: .whitespacesAndNewlines) == value && !controls(value)
    }
    private static func controls(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }
    private static func approvalText(_ value: String, nonempty: Bool = true) -> Bool {
        value.utf8.count <= 256 && !controls(value) && (!nonempty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    private static func timestamp(_ value: String) -> Bool { (try? IMessageGatewayWire.utcDate(value)) != nil }
    private static func optionalTime(_ value: String?) -> Bool { value.map { $0.isEmpty || timestamp($0) } ?? true }
    private static func clientRequestID(_ value: String) -> Bool {
        text(value, minimum: 1, maximum: 128) && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private static func selectedIDs(_ ids: [String]) -> Bool {
        (1...32).contains(ids.count) && Set(ids).count == ids.count && ids.allSatisfy(identifier)
    }

    public static func validate(_ value: IMessageGatewayConversationBinding) throws {
        try require(identifier(value.conversationID) && value.nativeChatID.value > 0 && approvalText(value.nativeChatGUID))
    }
    public static func validate(_ value: IMessageGatewayConfigScope) throws {
        try require([value.configID, value.workspaceID, value.accountGeneration, value.sourceGeneration].allSatisfy(identifier)
            && value.configVersion > 0 && value.revokedThrough >= 0 && approvalText(value.accountID)
            && selectedIDs(value.conversationIDs) && value.conversationBindings.map(\.conversationID) == value.conversationIDs
            && Set(value.conversationBindings.map(\.nativeChatID)).count == value.conversationBindings.count
            && Set(value.conversationBindings.map(\.nativeChatGUID)).count == value.conversationBindings.count)
        for binding in value.conversationBindings { try validate(binding) }
    }
    public static func validate(_ value: IMessageGatewayPersonaCaller) throws {
        try require(identifier(value.principalID) && identifier(value.personaID) && value.bindingVersion > 0
            && (value.runID.map { $0.isEmpty || identifier($0) } ?? true))
    }
    public static func validate(_ value: IMessageGatewayStreamCaller) throws {
        try require(identifier(value.managerID) && identifier(value.streamID) && value.assignmentFence > 0)
    }
    public static func validate(_ value: IMessageGatewayHumanCaller) throws {
        try require(identifier(value.userID))
        switch value.action {
        case .check:
            try require((value.conversationID ?? "").isEmpty && (value.textSHA256 ?? "").isEmpty)
        case .testSend:
            let digest = value.textSHA256 ?? ""
            try require(identifier(value.conversationID ?? "") && digest.utf8.count == 64
                && digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
        }
    }
    public static func validate(_ value: IMessageGatewayConfigIdentityInput) throws { try require(identifier(value.integrationID)) }
    public static func validate(_ value: IMessageGatewayConversationInput) throws {
        try require(identifier(value.integrationID) && identifier(value.conversationID))
    }
    public static func validate(_ value: IMessageGatewayRecentMessagesInput) throws {
        try require(identifier(value.integrationID) && identifier(value.conversationID) && (1...100).contains(value.limit ?? 50))
    }
    public static func validate(_ value: IMessageGatewaySendMessageInput) throws {
        try require(identifier(value.integrationID) && identifier(value.conversationID) && clientRequestID(value.clientRequestID)
            && !value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.text.utf8.count <= 16 * 1024)
    }
    public static func validate(_ value: IMessageGatewayReceivePageInput) throws {
        try require(identifier(value.conversationID) && (1...100).contains(value.limit) && (value.through.map { $0 >= value.after } ?? true))
    }
    public static func validate(_ value: IMessageGatewaySourceAnchor) throws {
        try require(identifier(value.conversationID) && value.rowID.value > 0 && approvalText(value.guid))
    }
    public static func validate(_ value: IMessageGatewaySourceCheckpointInput) throws {
        let anchors = value.anchors ?? []
        try require(selectedIDs(value.conversationIDs) && anchors.count <= value.conversationIDs.count
            && Set(anchors.map(\.conversationID)).count == anchors.count)
        for anchor in anchors {
            try validate(anchor)
            try require(value.conversationIDs.contains(anchor.conversationID))
        }
    }
    public static func validate(_ value: IMessageGatewayPublicConversation) throws {
        try require(identifier(value.conversationID) && text(value.label) && value.service == "imessage"
            && value.participants.count <= 100 && (!value.available || !value.participants.isEmpty)
            && value.participants.allSatisfy { text($0, minimum: 1) } && optionalTime(value.lastMessageAt))
    }
    public static func validate(_ value: IMessageGatewayAttachmentMetadata) throws {
        try require(identifier(value.attachmentID) && text(value.name ?? "") && text(value.mimeType ?? "", maximum: 128)
            && (value.sizeBytes.map { $0 >= 0 } ?? true))
    }
    public static func validate(_ value: IMessageGatewayPublicMessage) throws {
        try require(identifier(value.messageID) && identifier(value.conversationID) && timestamp(value.sentAt)
            && text(value.sender) && text(value.senderLabel ?? "") && value.text.utf8.count <= 16 * 1024
            && value.attachments.count <= 20 && value.attachmentCount >= Int64(value.attachments.count)
            && (value.replyToMessageID.map { $0.isEmpty || identifier($0) } ?? true))
        for attachment in value.attachments { try validate(attachment) }
    }
    public static func validate(_ value: IMessageGatewayNativeStatusResult) throws {
        try require(value.protocolVersion == providerVersion && value.adapterRevision == adapterRevision
            && (value.state == .connected ? value.reasonCode == nil : value.reasonCode != nil))
    }
    public static func validate(_ value: IMessageGatewayConversationsResult) throws {
        try require(value.conversations.count <= 32)
        for row in value.conversations { try validate(row) }
    }
    public static func validate(_ value: IMessageGatewayConversationResult) throws { try validate(value.conversation) }
    public static func validate(_ value: IMessageGatewayRecentMessagesResult) throws {
        try require((1...100).contains(value.windowLimit) && value.messages.count <= value.windowLimit)
        for message in value.messages { try validate(message) }
    }
    public static func validate(_ value: IMessageGatewaySendMessageResult) throws {
        try require(identifier(value.conversationID) && clientRequestID(value.clientRequestID) && identifier(value.messageID)
            && value.outcome == "local_record_confirmed" && timestamp(value.confirmedAt))
    }
    public static func validate(_ value: IMessageGatewayReceiveRecord) throws {
        try require(value.rowID.value > 0 && optionalTime(value.editedAt) && optionalTime(value.unsentAt))
        try validate(value.message)
    }
    public static func validate(_ value: IMessageGatewayReceivePageResult) throws {
        try require(identifier(value.sourceGeneration) && value.nextRowID <= value.sourceHighWater && value.messages.count <= 100
            && !(value.hasMore && value.stopReason == .caughtUp) && (!value.hasMore || value.nextRowID < value.sourceHighWater)
            && Set(value.messages.map { $0.message.messageID }).count == value.messages.count)
        var previous = try IMessageRowID(0)
        for row in value.messages {
            try validate(row)
            try require(row.rowID > previous && row.rowID <= value.nextRowID)
            previous = row.rowID
        }
    }
    public static func validate(_ value: IMessageGatewaySourceCheckpointConversation) throws {
        try require(identifier(value.conversationID) && approvalText(value.tailGUID, nonempty: false))
        if value.available {
            try require(approvalText(value.chatGUID) && ((value.tailRowID.value == 0) == value.tailGUID.isEmpty))
        } else {
            try require(value.chatGUID.isEmpty && value.tailRowID.value == 0 && value.tailGUID.isEmpty && value.anchorMatches != true)
        }
    }
    public static func validate(_ value: IMessageGatewaySourceCheckpointResult) throws {
        try require(approvalText(value.accountID) && identifier(value.sourceGeneration) && timestamp(value.observedAt)
            && (1...32).contains(value.conversations.count) && Set(value.conversations.map(\.conversationID)).count == value.conversations.count)
        for row in value.conversations { try validate(row); try require(row.tailRowID <= value.sourceHighWater) }
    }

    public static func validate(_ result: IMessageGatewayConfiguredResult) throws {
        switch result {
        case .status(let value): try validate(value)
        case .conversations(let value): try validate(value)
        case .conversation(let value): try validate(value)
        case .recentMessages(let value): try validate(value)
        case .sendMessage(let value): try validate(value)
        case .receivePage(let value): try validate(value)
        case .sourceCheckpoint(let value): try validate(value)
        }
    }

    /// Structural semantic match only. This is never a replacement API grant check.
    public static func matches(_ scope: IMessageGatewayConfigScope, configID: String, workspaceID: String, configVersion: Int64,
                               accountGeneration: String, sourceGeneration: String, revision: Int64) -> Bool {
        scope.configID == configID && scope.workspaceID == workspaceID && scope.configVersion == configVersion
            && scope.accountGeneration == accountGeneration && scope.sourceGeneration == sourceGeneration
            && !scope.paused && revision > scope.revokedThrough
    }
    public static func validate(_ input: IMessageGatewayConfiguredInput, in scope: IMessageGatewayConfigScope) throws {
        try validate(scope)
        try require(!scope.paused)
        switch input {
        case .status(let value): try validate(value); try require(value.integrationID == scope.configID)
        case .conversations(let value): try validate(value); try require(scope.readEnabled && value.integrationID == scope.configID)
        case .conversation(let value): try validate(value); try require(scope.readEnabled && value.integrationID == scope.configID && scope.conversationIDs.contains(value.conversationID))
        case .recentMessages(let value): try validate(value); try require(scope.readEnabled && value.integrationID == scope.configID && scope.conversationIDs.contains(value.conversationID))
        case .sendMessage(let value): try validate(value); try require(scope.sendEnabled && value.integrationID == scope.configID && scope.conversationIDs.contains(value.conversationID))
        case .receivePage(let value): try validate(value); try require(scope.readEnabled && scope.conversationIDs.contains(value.conversationID))
        case .sourceCheckpoint(let value): try validate(value); try require(scope.readEnabled && value.conversationIDs.allSatisfy(scope.conversationIDs.contains))
        }
    }
    public static func validate(_ result: IMessageGatewayConfiguredResult, for input: IMessageGatewayConfiguredInput,
                                scope: IMessageGatewayConfigScope, deadline: String) throws {
        try validate(input, in: scope)
        try require(result.operationRawValue == input.operationRawValue && timestamp(deadline))
        try require(resultBytes(result) <= maximumResultBytes)
        switch (input, result) {
        case (.status, .status(let value)): try validate(value)
        case (.conversations, .conversations(let value)):
            try validate(value)
            try require(value.conversations.count == scope.conversationIDs.count && Set(value.conversations.map(\.conversationID)) == Set(scope.conversationIDs))
        case (.conversation(let request), .conversation(let value)):
            try validate(value); try require(value.conversation.conversationID == request.conversationID)
        case (.recentMessages(let request), .recentMessages(let value)):
            try validate(value)
            try require(value.windowLimit == (request.limit ?? 50) && value.messages.allSatisfy { $0.conversationID == request.conversationID }
                && Set(value.messages.map(\.messageID)).count == value.messages.count)
        case (.sendMessage(let request), .sendMessage(let value)):
            try validate(value); try require(value.conversationID == request.conversationID && value.clientRequestID == request.clientRequestID)
        case (.receivePage(let request), .receivePage(let value)): try validateReceive(value, for: request, sourceGeneration: scope.sourceGeneration)
        case (.sourceCheckpoint(let request), .sourceCheckpoint(let value)): try validateCheckpoint(value, for: request, scope: scope, deadline: deadline)
        default: throw IMessageGatewayWireError.correlationMismatch
        }
    }
    private static func validateReceive(_ value: IMessageGatewayReceivePageResult, for request: IMessageGatewayReceivePageInput,
                                        sourceGeneration: String) throws {
        try validate(value)
        try require(value.sourceGeneration == sourceGeneration && value.messages.count <= request.limit && value.nextRowID >= request.after
            && (!value.hasMore || value.nextRowID > request.after) && (request.through.map { value.nextRowID <= $0 } ?? true)
            && (request.through.map { !value.hasMore || value.nextRowID != $0 } ?? true))
        for row in value.messages { try require(row.rowID > request.after && row.message.conversationID == request.conversationID) }
    }
    private static func validateCheckpoint(_ value: IMessageGatewaySourceCheckpointResult, for request: IMessageGatewaySourceCheckpointInput,
                                           scope: IMessageGatewayConfigScope, deadline: String) throws {
        try validate(value)
        try require(value.accountID == scope.accountID && value.sourceGeneration == scope.sourceGeneration
            && value.conversations.map(\.conversationID) == request.conversationIDs
            && !(try IMessageGatewayWire.timestampPrecedes(deadline, value.observedAt)))
        for row in value.conversations {
            let binding = scope.conversationBindings.first { $0.conversationID == row.conversationID }
            try require(!row.available || binding?.nativeChatGUID == row.chatGUID)
            if let anchor = request.anchors?.first(where: { $0.conversationID == row.conversationID }) {
                try require(row.anchorMatches != nil)
                if row.anchorMatches == true {
                    try require(anchor.rowID <= row.tailRowID && (anchor.rowID != row.tailRowID || anchor.guid == row.tailGUID))
                }
            } else { try require(row.anchorMatches == nil) }
        }
    }
}
