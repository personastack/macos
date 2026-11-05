import Foundation

/// Pure bounded projection. Callers must first prove current API and native authority.
public enum IMessageConfiguredProjection {
    private static func require(_ condition: Bool) throws {
        guard condition else { throw IMessageGatewayWireError.correlationMismatch }
    }
    public static func conversation(_ row: IMessageConversation, binding: IMessageGatewayConversationBinding) throws -> IMessageGatewayPublicConversation {
        try IMessageConfiguredGatewayValidation.validate(binding)
        try require(row.id == binding.nativeChatID)
        if row.available { try require(row.guid == binding.nativeChatGUID && row.service == "iMessage") }
        else {
            try require(row.guid.isEmpty && row.name.isEmpty && row.service.isEmpty && !row.isGroup
                && row.participants.isEmpty && row.accountID == nil && row.accountLogin == nil)
        }
        let value = IMessageGatewayPublicConversation(conversationID: binding.conversationID, label: row.name,
            participants: row.participants, isGroup: row.isGroup, available: row.available)
        try IMessageConfiguredGatewayValidation.validate(value)
        return value
    }
    public static func message(_ row: IMessageMessage, binding: IMessageGatewayConversationBinding) throws -> IMessageGatewayPublicMessage {
        try IMessageConfiguredGatewayValidation.validate(binding)
        try require(row.chatID == binding.nativeChatID && row.service == "iMessage" && row.rowID.value > 0
            && row.attachmentCount >= 0 && row.attachments.isEmpty)
        let value = IMessageGatewayPublicMessage(messageID: row.guid, conversationID: binding.conversationID,
            sentAt: row.date, sender: row.sender, isFromMe: row.isFromMe, text: row.text, textTruncated: row.textTruncated,
            attachments: [], attachmentCount: Int64(row.attachmentCount))
        try IMessageConfiguredGatewayValidation.validate(value)
        return value
    }
    public static func checkpoint(_ source: IMessageSourceCheckpoint, scope: IMessageGatewayConfigScope,
                                  input: IMessageGatewaySourceCheckpointInput, liveAccount: IMessageSetupAccount,
                                  deadline: String) throws -> IMessageGatewaySourceCheckpointResult {
        try IMessageConfiguredGatewayValidation.validate(.sourceCheckpoint(input), in: scope)
        try require(source.adapterRevision == 2 && liveAccount.accountID == scope.accountID && liveAccount.sourceGeneration == scope.sourceGeneration
            && source.chats.count == input.conversationIDs.count)
        let rows = try zip(input.conversationIDs, source.chats).map { id, row -> IMessageGatewaySourceCheckpointConversation in
            guard let binding = scope.conversationBindings.first(where: { $0.conversationID == id }) else {
                throw IMessageGatewayWireError.correlationMismatch
            }
            try require(row.chatID == binding.nativeChatID)
            if row.available { try require(row.service == "iMessage" && row.guid == binding.nativeChatGUID) }
            else { try require(row.guid.isEmpty && row.service.isEmpty && row.tailRowID.value == 0 && row.tailGUID.isEmpty) }
            return .init(conversationID: id, chatGUID: row.guid, available: row.available,
                tailRowID: row.tailRowID, tailGUID: row.tailGUID, anchorMatches: row.anchorMatches)
        }
        let value = IMessageGatewaySourceCheckpointResult(accountID: liveAccount.accountID, sourceGeneration: liveAccount.sourceGeneration,
            sourceHighWater: source.sourceHighWater, observedAt: source.observedAt, conversations: rows)
        try IMessageConfiguredGatewayValidation.validate(.sourceCheckpoint(value), for: .sourceCheckpoint(input), scope: scope, deadline: deadline)
        return value
    }
    public static func receivePage(_ source: IMessageReceivePage, binding: IMessageGatewayConversationBinding,
                                   scope: IMessageGatewayConfigScope, input: IMessageGatewayReceivePageInput,
                                   sourceHighWater: IMessageRowID, deadline: String) throws -> IMessageGatewayReceivePageResult {
        try IMessageConfiguredGatewayValidation.validate(.receivePage(input), in: scope)
        try require(binding.conversationID == input.conversationID && scope.conversationBindings.contains(binding)
            && source.messages.count <= input.limit && source.nextRowID >= input.after && source.nextRowID <= sourceHighWater
            && (input.through.map { source.nextRowID <= $0 } ?? true))
        let records = try source.messages.map { row in
            IMessageGatewayReceiveRecord(rowID: row.rowID, message: try message(row, binding: binding), editedAt: row.editedAt, unsentAt: row.unsentAt)
        }
        let full = IMessageGatewayReceivePageResult(sourceGeneration: scope.sourceGeneration, sourceHighWater: sourceHighWater,
            messages: records, nextRowID: source.nextRowID, hasMore: source.hasMore, stopReason: source.stopReason)
        let empty = IMessageGatewayReceivePageResult(sourceGeneration: scope.sourceGeneration, sourceHighWater: sourceHighWater,
            messages: [], nextRowID: source.nextRowID, hasMore: source.hasMore, stopReason: source.stopReason)
        // Encode each record once. Array commas and the empty envelope are exact
        // additive JSON costs. Never re-encode successively shorter full pages.
        var prefixBytes = [0]
        for row in records {
            let size = try IMessageConfiguredGatewayValidation.resultBytes(row)
            prefixBytes.append(prefixBytes[prefixBytes.count - 1] + size + (prefixBytes.count > 1 ? 1 : 0))
        }
        let fullBytes = try IMessageConfiguredGatewayValidation.resultBytes(IMessageGatewayConfiguredResult.receivePage(empty)) + (prefixBytes.last ?? 0)
        if fullBytes <= IMessageConfiguredGatewayValidation.maximumResultBytes {
            try IMessageConfiguredGatewayValidation.validate(.receivePage(full), for: .receivePage(input), scope: scope, deadline: deadline)
            return full
        }
        let limited = IMessageGatewayReceivePageResult(sourceGeneration: scope.sourceGeneration, sourceHighWater: sourceHighWater,
            messages: [], nextRowID: try IMessageRowID(0), hasMore: true, stopReason: .outputLimit)
        let envelopeBytes = try IMessageConfiguredGatewayValidation.resultBytes(IMessageGatewayConfiguredResult.receivePage(limited))
        var count = 0
        guard records.count > 1 else { throw IMessageGatewayWireError.resultTooLarge }
        for next in 1..<records.count {
            let bytes = envelopeBytes + prefixBytes[next] + records[next - 1].rowID.rawValue.utf8.count - 1
            if bytes > IMessageConfiguredGatewayValidation.maximumResultBytes { break }
            count = next
        }
        guard count > 0 else { throw IMessageGatewayWireError.resultTooLarge }
        let value = IMessageGatewayReceivePageResult(sourceGeneration: scope.sourceGeneration, sourceHighWater: sourceHighWater,
            messages: Array(records.prefix(count)), nextRowID: records[count - 1].rowID, hasMore: true, stopReason: .outputLimit)
        try IMessageConfiguredGatewayValidation.validate(.receivePage(value), for: .receivePage(input), scope: scope, deadline: deadline)
        return value
    }

    public static func recentMessages(_ source: IMessageRecentMessages, binding: IMessageGatewayConversationBinding,
                                      limit: Int) throws -> IMessageGatewayRecentMessagesResult {
        try require((1...100).contains(limit) && source.messages.count <= limit)
        let rows = try source.messages.map { try message($0, binding: binding) }
        let sizes = try rows.map { try IMessageConfiguredGatewayValidation.resultBytes($0) }
        let full = IMessageGatewayRecentMessagesResult(messages: rows, windowLimit: limit, truncated: source.truncated)
        let empty = IMessageGatewayRecentMessagesResult(messages: [], windowLimit: limit, truncated: source.truncated)
        let fullBytes = try IMessageConfiguredGatewayValidation.resultBytes(IMessageGatewayConfiguredResult.recentMessages(empty))
            + sizes.reduce(0, +) + max(0, sizes.count - 1)
        if fullBytes <= IMessageConfiguredGatewayValidation.maximumResultBytes {
            try IMessageConfiguredGatewayValidation.validate(.recentMessages(full))
            return full
        }
        let limited = IMessageGatewayRecentMessagesResult(messages: [], windowLimit: limit, truncated: true)
        var bytes = try IMessageConfiguredGatewayValidation.resultBytes(IMessageGatewayConfiguredResult.recentMessages(limited))
        var count = 0
        for size in sizes.reversed() {
            bytes += size + (count > 0 ? 1 : 0)
            if bytes > IMessageConfiguredGatewayValidation.maximumResultBytes { break }
            count += 1
        }
        guard count > 0 else { throw IMessageGatewayWireError.resultTooLarge }
        let value = IMessageGatewayRecentMessagesResult(messages: Array(rows.suffix(count)), windowLimit: limit, truncated: true)
        try IMessageConfiguredGatewayValidation.validate(.recentMessages(value))
        return value
    }

    public static func sendReceipt(_ receipt: IMessageSendReceipt, binding: IMessageGatewayConversationBinding,
                                   input: IMessageGatewaySendMessageInput, confirmedAt: String) throws -> IMessageGatewaySendMessageResult {
        try require(binding.conversationID == input.conversationID && receipt.chatGUID == binding.nativeChatGUID && receipt.rowID > 0)
        let value = IMessageGatewaySendMessageResult(conversationID: input.conversationID, clientRequestID: input.clientRequestID,
            messageID: receipt.messageGUID, confirmedAt: confirmedAt)
        try IMessageConfiguredGatewayValidation.validate(value)
        return value
    }
}
