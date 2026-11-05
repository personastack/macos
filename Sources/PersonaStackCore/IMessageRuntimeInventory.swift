import Foundation

internal enum IMessageRuntimeInventoryError: Error {
    case invalidSelection, payloadTooLarge, providerInvalid, accountChanged
    var code: IMessageGatewayFailureCode {
        switch self {
        case .invalidSelection: .invalidArguments
        case .payloadTooLarge: .payloadTooLarge
        case .providerInvalid: .dependencyInvalid
        case .accountChanged: .accountChanged
        }
    }
}

/// Two visible pages and the exact locally ACKed selection. No full-inventory map.
internal struct IMessageRuntimeInventory {
    struct Option: Sendable {
        let conversationID: String
        let metadata: IMessageConversation
        let expiresAt: Date
        let expectedGUID: String?
        init(conversationID: String, metadata: IMessageConversation, expiresAt: Date, expectedGUID: String? = nil) {
            self.conversationID = conversationID; self.metadata = metadata; self.expiresAt = expiresAt; self.expectedGUID = expectedGUID
        }
        var wire: IMessageGatewaySetupConversation { .init(conversationID: conversationID, metadata: metadata) }
    }
    struct Request {
        let after: IMessageRowID
        let upper: IMessageRowID?
        let fresh: Bool
        let cached: IMessageGatewayConversationsPageResult?
    }
    private struct Snapshot {
        let token: String
        let query: String
        let upper: IMessageRowID
        let expiresAt: Date
    }
    private struct Page {
        let input: IMessageGatewaySetupConversationsInput
        let result: IMessageGatewayConversationsPageResult
        let rows: [Option]
    }
    private var snapshot: Snapshot?
    private var pages: [Page] = []
    private var account: IMessageSetupAccount?
    private(set) var selected: [Option] = []

    func request(_ input: IMessageGatewaySetupConversationsInput, now: Date) throws -> Request {
        guard let token = input.snapshotToken else {
            return Request(after: try IMessageRowID(0), upper: nil, fresh: true, cached: nil)
        }
        guard let snapshot, snapshot.token == token, snapshot.query == input.query, snapshot.expiresAt > now else {
            throw IMessageRuntimeInventoryError.invalidSelection
        }
        if let cached = pages.last(where: { $0.input == input }) {
            return Request(after: try IMessageRowID(0), upper: snapshot.upper, fresh: false, cached: cached.result)
        }
        guard let pageToken = input.pageToken else {
            return Request(after: try IMessageRowID(0), upper: snapshot.upper, fresh: false, cached: nil)
        }
        guard let previous = pages.last(where: { $0.result.nextPageToken == pageToken }) else {
            throw IMessageRuntimeInventoryError.invalidSelection
        }
        return Request(after: previous.result.nextChatRowID, upper: snapshot.upper, fresh: false, cached: nil)
    }

    mutating func accept(_ response: IMessageSetupProviderPage, input: IMessageGatewaySetupConversationsInput,
                         request: Request, now: Date, makeID: () -> String) throws -> IMessageGatewayConversationsPageResult {
        let page = response.page
        try validate(page, request: request, limit: input.limit)
        guard validAccount(response.account) else { throw IMessageRuntimeInventoryError.providerInvalid }
        guard account.map({ $0 == response.account }) ?? true else { throw IMessageRuntimeInventoryError.accountChanged }
        let current: Snapshot
        if request.fresh {
            current = Snapshot(token: makeID(), query: input.query, upper: page.upperChatRowID,
                expiresAt: now.addingTimeInterval(IMessageRuntime.inventoryLifetime))
        } else {
            guard let snapshot, snapshot.expiresAt > now else { throw IMessageRuntimeInventoryError.invalidSelection }
            current = snapshot
        }
        let retained = selected + pages.reversed().flatMap(\.rows)
        let rows = page.chats.map { metadata -> Option in
            let old = retained.first { $0.metadata.id == metadata.id && $0.metadata.guid == metadata.guid && $0.expiresAt > now }
            return Option(conversationID: old?.conversationID ?? makeID(), metadata: metadata,
                          expiresAt: old?.expiresAt ?? current.expiresAt, expectedGUID: old?.expectedGUID)
        }
        let nextToken = page.hasMore || !rows.isEmpty ? makeID() : nil
        let result = try boundedResult(rows: rows, page: page, snapshot: current, nextToken: nextToken)
        try IMessageGatewayWire.validate(.conversationsPage(result))
        if request.fresh { pages.removeAll() }
        snapshot = current; account = response.account
        let emitted = Array(rows.prefix(result.conversations.count))
        pages.append(Page(input: input, result: result, rows: emitted))
        if pages.count > 2 { pages.removeFirst(pages.count - 2) }
        return result
    }

    private func boundedResult(rows: [Option], page: IMessageConversationPage, snapshot: Snapshot,
                               nextToken: String?) throws -> IMessageGatewayConversationsPageResult {
        var count = rows.count
        while true {
            let omitted = count < rows.count
            let hasMore = omitted || page.hasMore
            let next = omitted ? rows[count - 1].metadata.id : page.nextChatRowID
            let result = IMessageGatewayConversationsPageResult(snapshotToken: snapshot.token,
                nextPageToken: hasMore ? nextToken : nil, conversations: rows.prefix(count).map(\.wire),
                nextChatRowID: next, upperChatRowID: page.upperChatRowID, hasMore: hasMore,
                stopReason: omitted ? .outputLimit : page.stopReason)
            if try JSONEncoder().encode(IMessageGatewaySetupResult.conversationsPage(result)).count <= IMessageGatewayWire.maximumResultBytes {
                return result
            }
            guard count > 1 else { throw IMessageRuntimeInventoryError.payloadTooLarge }
            count -= 1
        }
    }

    mutating func select(_ ids: [String], now: Date) throws {
        guard ids.count <= 32, Set(ids).count == ids.count else { throw IMessageRuntimeInventoryError.invalidSelection }
        let known = pages.reversed().flatMap(\.rows) + selected
        let requested = try ids.map { id -> Option in
            guard let option = known.first(where: { $0.conversationID == id }), option.expiresAt > now,
                  option.metadata.available || selected.contains(where: { $0.conversationID == id }) else {
                throw IMessageRuntimeInventoryError.invalidSelection
            }
            return option
        }
        selected = requested
    }

    func verification(_ ids: [String], now: Date) throws -> (rows: [IMessageGatewaySetupConversation], account: IMessageSetupAccount) {
        guard let account, !ids.isEmpty, ids.count == selected.count,
              Set(ids) == Set(selected.map(\.conversationID)), selected.allSatisfy({ $0.expiresAt > now }) else {
            throw IMessageRuntimeInventoryError.invalidSelection
        }
        let rows = try ids.map { id -> IMessageGatewaySetupConversation in
            guard let row = selected.first(where: { $0.conversationID == id }) else { throw IMessageRuntimeInventoryError.invalidSelection }
            return row.wire
        }
        return (rows, account)
    }

    mutating func connectionReplaced() {
        snapshot = nil
        pages.removeAll()
    }

    func retained(now: Date) throws -> (rows: [IMessageGatewaySetupConversation], account: IMessageSetupAccount,
                                      expiresAt: Date, expectedSelections: [IMessageSetupDraft.Selection]) {
        let value = try verification(selected.map(\.conversationID), now: now)
        guard let expiry = selected.map(\.expiresAt).min() else { throw IMessageRuntimeInventoryError.invalidSelection }
        let intentions = try selected.map { try IMessageSetupDraft.Selection(nativeChatRowID: $0.metadata.id.rawValue,
            expectedGUID: $0.expectedGUID ?? $0.metadata.guid) }
        return (value.rows, value.account, expiry, intentions)
    }

    mutating func restore(_ response: IMessageSetupProviderVerification, selections: [IMessageSetupDraft.Selection],
                          account: IMessageSetupAccount, expiresAt: Date, makeID: () -> String) throws {
        guard validAccount(account), response.conversations.count == selections.count,
              let proof = response.liveAccount, proof.accountID == account.accountID,
              proof.sourceGeneration == account.sourceGeneration,
              proof.chatGUIDs == response.conversations.filter(\.available).map(\.guid) else { throw IMessageRuntimeInventoryError.accountChanged }
        for (choice, current) in zip(selections, response.conversations) {
            guard current.id.rawValue == choice.nativeChatRowID else { throw IMessageRuntimeInventoryError.accountChanged }
            if current.available {
                guard current.guid == choice.expectedGUID, current.service == "iMessage" else { throw IMessageRuntimeInventoryError.accountChanged }
            }
        }
        let oldIDs = Set((selected + pages.flatMap(\.rows)).map(\.conversationID))
        let rows = zip(response.conversations, selections).map { Option(conversationID: makeID(), metadata: $0.0,
            expiresAt: expiresAt, expectedGUID: $0.1.expectedGUID) }
        guard Set(rows.map(\.conversationID)).count == rows.count,
              rows.allSatisfy({ !oldIDs.contains($0.conversationID) }) else { throw IMessageRuntimeInventoryError.providerInvalid }
        // Public verification keeps its existing all-unavailable wire shape.
        // The private fresh account proof above remains mandatory for restore.
        let wire = IMessageGatewayVerificationResult(conversations: rows.map(\.wire), liveAccount: proof.chatGUIDs.isEmpty ? nil : proof)
        try IMessageGatewayWire.validate(.verification(wire))
        self = IMessageRuntimeInventory()
        self.account = account
        selected = rows
    }

    private func validate(_ page: IMessageConversationPage, request: Request, limit: Int) throws {
        guard page.chats.count <= limit, page.nextChatRowID >= request.after, page.nextChatRowID <= page.upperChatRowID,
              request.upper.map({ $0 == page.upperChatRowID }) ?? true,
              !page.hasMore || page.nextChatRowID > request.after else { throw IMessageRuntimeInventoryError.providerInvalid }
        var previous = request.after
        for row in page.chats {
            guard row.id > previous, row.id <= page.nextChatRowID else { throw IMessageRuntimeInventoryError.providerInvalid }
            previous = row.id
        }
    }

    private func validAccount(_ value: IMessageSetupAccount) -> Bool {
        [value.accountID, value.sourceGeneration].allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 256 && $0.trimmingCharacters(in: .whitespacesAndNewlines) == $0
                && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        }
    }
}
