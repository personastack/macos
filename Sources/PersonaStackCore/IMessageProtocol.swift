import Foundation

public enum IMessageRPCError: Error, Equatable, Sendable {
    case notStarted, alreadyStarted, busy, invalidArguments, invalidResponse
    case frameTooLarge, dependencyInvalid, restartLimitReached, processExited, deadlineExceeded, cancelled
    case providerRejected(code: Int, retrySafe: Bool)
    case outcomeUnknown
}

/// A SQLite position is never represented by a floating point JSON number.
public struct IMessageRowID: Codable, Hashable, Sendable, Comparable {
    public let rawValue: String
    public var value: Int64 { Int64(rawValue)! }

    public init(_ value: Int64) throws {
        guard value >= 0 else { throw IMessageRPCError.invalidArguments }
        self.rawValue = String(value)
    }

    public init(decimal: String) throws {
        guard let value = Int64(decimal), value >= 0, String(value) == decimal else {
            throw IMessageRPCError.invalidArguments
        }
        self.rawValue = decimal
    }

    public init(from decoder: Decoder) throws {
        try self.init(decimal: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }
}

public enum IMessagePageStopReason: String, Codable, Sendable {
    case caughtUp = "caught_up", outputLimit = "output_limit"
    case scanLimit = "scan_limit", timeLimit = "time_limit"
}

public struct IMessageRPCStatus: Decodable, Sendable {
    public struct Database: Decodable, Sendable { public let ready: Bool }
    public let protocolVersion: Int
    public let adapterRevision: Int
    public let database: Database
    public let methods: [String]
    enum CodingKeys: String, CodingKey {
        case database, methods
        case protocolVersion = "protocol_version"
        case adapterRevision = "personastack_adapter_revision"
    }
}

public struct IMessageConversation: Decodable, Sendable, Equatable {
    public let id: IMessageRowID
    public let guid: String
    public let name: String
    public let service: String
    public let isGroup: Bool
    public let available: Bool
    public let participants: [String]
    public let accountID: String?
    public let accountLogin: String?
    enum CodingKeys: String, CodingKey {
        case id, guid, name, service, participants, available
        case isGroup = "is_group", accountID = "account_id", accountLogin = "account_login"
    }
}

public struct IMessageConversationPage: Decodable, Sendable {
    public let chats: [IMessageConversation]
    public let nextChatRowID: IMessageRowID
    public let upperChatRowID: IMessageRowID
    public let hasMore: Bool
    public let stopReason: IMessagePageStopReason
    enum CodingKeys: String, CodingKey {
        case chats
        case nextChatRowID = "next_chat_rowid", upperChatRowID = "upper_chat_rowid"
        case hasMore = "has_more", stopReason = "stop_reason"
    }
}

/// Exact, ordered metadata for a bounded selected set. Unavailable rows retain
/// only the requested row ID and never substitute another conversation.
public struct IMessageChatMetadata: Decodable, Sendable {
    public let chats: [IMessageConversation]
}

public struct IMessageSourceAnchor: Encodable, Sendable {
    public let chatID: IMessageRowID
    public let rowID: IMessageRowID
    public let guid: String
    public init(chatID: IMessageRowID, rowID: IMessageRowID, guid: String) {
        self.chatID = chatID; self.rowID = rowID; self.guid = guid
    }
    enum CodingKeys: String, CodingKey { case chatID = "chat_id", rowID = "rowid", guid }
}

public struct IMessageSourceCheckpoint: Decodable, Sendable {
    public struct Chat: Decodable, Sendable {
        public let chatID: IMessageRowID
        public let guid: String
        public let service: String
        public let available: Bool
        public let tailRowID: IMessageRowID
        public let tailGUID: String
        public let accountID: String?
        public let accountLogin: String?
        public let anchorMatches: Bool?
        enum CodingKeys: String, CodingKey {
            case guid, service, available
            case chatID = "chat_id", tailRowID = "tail_rowid", tailGUID = "tail_guid"
            case accountID = "account_id", accountLogin = "account_login", anchorMatches = "anchor_matches"
        }
    }
    public let adapterRevision: Int
    public let sourceHighWater: IMessageRowID
    public let chats: [Chat]
    public let observedAt: String
    enum CodingKeys: String, CodingKey {
        case chats, adapterRevision = "adapter_revision"
        case sourceHighWater = "source_high_water", observedAt = "observed_at"
    }
}

public struct IMessageMessage: Decodable, Sendable, Equatable {
    public let rowID: IMessageRowID
    public let guid: String
    public let chatID: IMessageRowID
    public let text: String
    public let isFromMe: Bool
    public let date: String
    public let sender: String
    public let service: String
    public let textTruncated: Bool
    public let attachmentCount: Int
    public let attachments: [IMessageAttachment]
    public let editedAt: String?
    public let unsentAt: String?
    enum CodingKeys: String, CodingKey {
        case guid, text, date, sender, service, attachments
        case textTruncated = "text_truncated", attachmentCount = "attachment_count"
        case editedAt = "edited_at", unsentAt = "unsent_at"
        case rowID = "rowid", chatID = "chat_id", isFromMe = "is_from_me"
    }
}

public struct IMessageAttachment: Decodable, Sendable, Equatable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: IMessageCodingKey.self)
        guard container.allKeys.isEmpty else { throw IMessageRPCError.invalidResponse }
    }
}

public struct IMessageRecentMessages: Decodable, Sendable {
    public let messages: [IMessageMessage]
    public let truncated: Bool
    public let stopReason: IMessagePageStopReason
    enum CodingKeys: String, CodingKey {
        case messages, truncated, stopReason = "stop_reason"
    }
}

public struct IMessageReceivePage: Decodable, Sendable {
    public let messages: [IMessageMessage]
    public let nextRowID: IMessageRowID
    public let hasMore: Bool
    public let stopReason: IMessagePageStopReason
    enum CodingKeys: String, CodingKey {
        case messages, nextRowID = "next_rowid", hasMore = "has_more", stopReason = "stop_reason"
    }
}

public struct IMessageSendReceipt: Sendable, Equatable {
    public let messageGUID: String
    public let rowID: Int64
    public let chatGUID: String
}

internal enum IMessageRPCMethod: String, Encodable, Sendable, CaseIterable {
    case initialize = "personastack.initialize"
    case status = "personastack.status"
    case send = "personastack.send"
    case chatsPage = "personastack.chats.page"
    case chatMetadata = "personastack.chatMetadata"
    case sourceCheckpoint = "personastack.source_checkpoint"
    case receivePage = "personastack.receive_page"
    case recentMessages = "personastack.recent_messages"
}

internal struct IMessageEmptyParams: Encodable, Sendable {}
internal struct IMessageRPCRequest<Parameters: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: String
    let method: IMessageRPCMethod
    let params: Parameters
}

internal struct IMessageRPCIdentity: Decodable {
    let jsonrpc: String
    let id: String
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: IMessageCodingKey.self)
        guard Set(container.allKeys.map(\.stringValue)).isSubset(of: ["jsonrpc", "id", "result", "error"]),
              container.contains(.init("result")) != container.contains(.init("error")) else {
            throw IMessageRPCError.invalidResponse
        }
        jsonrpc = try container.decode(String.self, forKey: .init("jsonrpc"))
        id = try container.decode(String.self, forKey: .init("id"))
        guard jsonrpc == "2.0", !id.isEmpty else { throw IMessageRPCError.invalidResponse }
    }
}

internal struct IMessageProviderError: Decodable {
    struct Disposition: Decodable {
        let retrySafe: Bool
        enum CodingKeys: String, CodingKey { case retrySafe = "retry_safe" }
    }
    let code: Int
    let data: Disposition?
    enum CodingKeys: String, CodingKey { case code, data }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(Int.self, forKey: .code)
        data = try? container.decode(Disposition.self, forKey: .data)
    }
}

internal struct IMessageRPCResponse<Result: Decodable>: Decodable {
    let result: Result?
    let error: IMessageProviderError?
}

internal struct IMessageCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

internal struct IMessageRPCResultKeys: Decodable {
    struct Keys: Decodable {
        let names: Set<String>
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: IMessageCodingKey.self)
            names = Set(container.allKeys.map(\.stringValue))
        }
    }
    let result: Keys?
}
