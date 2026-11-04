import Foundation

/// Structural and correlation checks only. The API grants and native local
/// intent checks remain required before any provider operation.
public enum IMessageGatewayWire {
    public static let protocolVersion = 1
    public static let providerAdapterRevision = 2
    public static let maximumResultBytes = 1 << 20
    public static func supports(protocolVersion: Int?) -> Bool { protocolVersion == Self.protocolVersion }

    public static func validate(_ frame: DesktopControlFrame) throws {
        guard frame.type == "imessage" else {
            guard frame.imessage == nil, (frame.imessageProtocolVersion ?? 0) >= 0 else { throw IMessageGatewayWireError.invalidFrame }
            if let version = frame.imessageProtocolVersion, version > 0, !["ready", "heartbeat"].contains(frame.type) {
                throw IMessageGatewayWireError.invalidFrame
            }
            return
        }
        guard frame.version == 1, let requestID = frame.requestID, identifier(requestID), let payload = frame.imessage,
              !frame.hasLegacyIMessageFields else { throw IMessageGatewayWireError.invalidFrame }
        switch payload {
        case .snapshot(let value): try validate(value)
        case .snapshotAck(let value): guard value.revision > 0 else { throw IMessageGatewayWireError.invalidFrame }
        case .command(let value):
            try validate(value)
            guard value.requestID == requestID else { throw IMessageGatewayWireError.invalidFrame }
        case .result(let value): try validate(value)
        case .failure(let value):
            guard value.retrySafe, ![.outcomeUnknown, .requestInProgress, .statusUnavailable].contains(value.code),
                  (1...512).contains(value.message.unicodeScalars.count) else { throw IMessageGatewayWireError.invalidFrame }
        }
    }

    public static func validate(_ snapshot: IMessageGatewaySnapshot) throws {
        guard identifier(snapshot.installationID), snapshot.revision > 0 else { throw IMessageGatewayWireError.invalidFrame }
        if let scope = snapshot.setupScope {
            guard canonical32(scope.setupReferenceSHA256), scope.generation > 0, identifier(scope.workspaceID), identifier(scope.userID) else {
                throw IMessageGatewayWireError.invalidFrame
            }
            _ = try timestampKey(scope.expiresAt)
        }
    }

    public static func validate(_ command: IMessageGatewayCommand) throws {
        let caller = command.caller.setupSession
        guard identifier(command.requestID), identifier(command.authorizationID), identifier(command.target.installationID),
              identifier(command.target.workspaceID), command.target.snapshotRevision > 0, identifier(caller.userID),
              caller.setupGeneration > 0, canonical32(caller.setupReference), command.input.operation == command.operation else {
            throw IMessageGatewayWireError.invalidFrame
        }
        _ = try timestampKey(command.deadlineAt)
        switch command.input {
        case .prerequisites: break
        case .setupConversations(let value):
            guard value.query.unicodeScalars.count <= 128, (1...50).contains(value.limit),
                  value.snapshotToken.map(identifier) ?? true, value.pageToken.map(identifier) ?? true,
                  value.pageToken == nil || value.snapshotToken != nil else { throw IMessageGatewayWireError.invalidFrame }
        case .verifyConversations(let value):
            guard (1...32).contains(value.conversationIDs.count), Set(value.conversationIDs).count == value.conversationIDs.count,
                  value.conversationIDs.allSatisfy(identifier) else { throw IMessageGatewayWireError.invalidFrame }
        }
    }

    public static func validate(_ result: IMessageGatewaySetupResult) throws {
        switch result {
        case .prerequisites(let value):
            guard value.protocolVersion == 1, value.adapterRevision == providerAdapterRevision else { throw IMessageGatewayWireError.invalidFrame }
        case .conversationsPage(let value): try validatePage(value)
        case .verification(let value): try validateVerification(value)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let encoded = try encoder.encode(result)
        guard goJSONBytes(encoded) <= maximumResultBytes else { throw IMessageGatewayWireError.resultTooLarge }
    }

    public static func validateSnapshotAck(_ frame: DesktopControlFrame, requestID: String, revision: Int64) throws {
        try validate(frame)
        guard frame.type == "imessage", frame.requestID == requestID, let payload = frame.imessage, case .snapshotAck(let ack) = payload,
              ack.revision == revision else { throw IMessageGatewayWireError.correlationMismatch }
    }

    /// The App computes this digest from the canonical locator's UTF-8 text
    /// using CryptoKit. Passing a digest never establishes API or local consent.
    public static func validate(command: IMessageGatewayCommand, against snapshot: IMessageGatewaySnapshot,
                                setupReferenceSHA256: String) throws {
        try validate(command); try validate(snapshot)
        let caller = command.caller.setupSession
        guard canonical32(setupReferenceSHA256), let scope = snapshot.setupScope, scope.enabled,
              snapshot.installationID == command.target.installationID, snapshot.revision == command.target.snapshotRevision,
              scope.workspaceID == command.target.workspaceID, scope.userID == caller.userID,
              scope.generation == caller.setupGeneration, scope.setupReferenceSHA256 == setupReferenceSHA256,
              try timestampKey(scope.expiresAt) >= timestampKey(command.deadlineAt) else { throw IMessageGatewayWireError.correlationMismatch }
    }

    public static func validateSnapshotUnchanged(_ installed: IMessageGatewaySnapshot, _ authorized: IMessageGatewaySnapshot) throws {
        try validate(installed); try validate(authorized)
        guard installed.installationID == authorized.installationID, installed.revision == authorized.revision else {
            throw IMessageGatewayWireError.correlationMismatch
        }
        switch (installed.setupScope, authorized.setupScope) {
        case (nil, nil): return
        case (let a?, let b?):
            guard a.setupReferenceSHA256 == b.setupReferenceSHA256, a.generation == b.generation, a.workspaceID == b.workspaceID,
                  a.userID == b.userID, a.enabled == b.enabled, try timestampsEqual(a.expiresAt, b.expiresAt) else {
                throw IMessageGatewayWireError.correlationMismatch
            }
        default: throw IMessageGatewayWireError.correlationMismatch
        }
    }

    public static func validateResult(_ frame: DesktopControlFrame, for command: IMessageGatewayCommand) throws {
        try validate(command); try validate(frame)
        guard frame.type == "imessage", frame.requestID == command.requestID else { throw IMessageGatewayWireError.correlationMismatch }
        guard let payload = frame.imessage else { throw IMessageGatewayWireError.correlationMismatch }
        if case .failure = payload { return }
        guard case .result(let result) = payload, result.operation == command.operation else { throw IMessageGatewayWireError.correlationMismatch }
        switch (command.input, result) {
        case (.setupConversations(let input), .conversationsPage(let page)):
            guard page.conversations.count <= input.limit, input.snapshotToken.map({ $0 == page.snapshotToken }) ?? true else {
                throw IMessageGatewayWireError.correlationMismatch
            }
        case (.verifyConversations(let input), .verification(let value)):
            guard input.conversationIDs == value.conversations.map(\.conversationID) else { throw IMessageGatewayWireError.correlationMismatch }
        default: break
        }
    }

    public static func timestampsEqual(_ lhs: String, _ rhs: String) throws -> Bool { try timestampKey(lhs) == timestampKey(rhs) }
    public static func timestampPrecedes(_ lhs: String, _ rhs: String) throws -> Bool { try timestampKey(lhs) < timestampKey(rhs) }
    public static func utcDate(_ value: String) throws -> Date {
        _ = try timestampKey(value)
        let formatter = ISO8601DateFormatter()
        guard let whole = formatter.date(from: String(value.prefix(19)) + "Z") else { throw IMessageGatewayWireError.invalidFrame }
        guard value.count > 20 else { return whole }
        let fractional = "0" + String(value.dropFirst(19).dropLast())
        guard let fraction = TimeInterval(fractional) else { throw IMessageGatewayWireError.invalidFrame }
        return whole.addingTimeInterval(fraction)
    }

    private static func timestampKey(_ value: String) throws -> String {
        guard value.utf8.count <= 40,
              value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,9})?Z$"#, options: .regularExpression) != nil else {
            throw IMessageGatewayWireError.invalidFrame
        }
        let ordinary = String(value.prefix(19)) + "Z"
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: ordinary), formatter.string(from: date) == ordinary,
              !value.hasPrefix("0000-") else { throw IMessageGatewayWireError.invalidFrame }
        let fraction = value.count > 20 ? String(value.dropFirst(20).dropLast()) : ""
        let key = String(value.prefix(19)) + "." + fraction + String(repeating: "0", count: 9 - fraction.count)
        guard key != "0001-01-01T00:00:00.000000000" else { throw IMessageGatewayWireError.invalidFrame }
        return key
    }

    private static func validatePage(_ page: IMessageGatewayConversationsPageResult) throws {
        guard identifier(page.snapshotToken), page.nextPageToken.map(identifier) ?? true,
              page.hasMore == (page.nextPageToken != nil), page.nextChatRowID <= page.upperChatRowID,
              !page.hasMore || page.nextChatRowID.value > 0, page.stopReason != .caughtUp || !page.hasMore else {
            throw IMessageGatewayWireError.invalidFrame
        }
        try validateRows(page.conversations, maximum: 50, exact: false)
        var previous: Int64 = 0
        for row in page.conversations {
            guard row.metadata.id.value > previous, row.metadata.id <= page.nextChatRowID else { throw IMessageGatewayWireError.invalidFrame }
            previous = row.metadata.id.value
        }
    }

    private static func validateVerification(_ value: IMessageGatewayVerificationResult) throws {
        guard !value.conversations.isEmpty else { throw IMessageGatewayWireError.invalidFrame }
        try validateRows(value.conversations, maximum: 32, exact: true)
        let available = value.conversations.filter { $0.metadata.available }.map(\.metadata.guid)
        guard !available.isEmpty else {
            guard value.liveAccount == nil else { throw IMessageGatewayWireError.invalidFrame }
            return
        }
        guard let live = value.liveAccount, metadataText(live.accountID, nonempty: true),
              !live.accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !controls(live.accountID),
              identifier(live.sourceGeneration), live.chatGUIDs == available, Set(live.chatGUIDs).count == live.chatGUIDs.count,
              live.chatGUIDs.allSatisfy({ metadataText($0, nonempty: true) && !controls($0) }) else { throw IMessageGatewayWireError.invalidFrame }
    }

    private static func validateRows(_ rows: [IMessageGatewaySetupConversation], maximum: Int, exact: Bool) throws {
        guard rows.count <= maximum, Set(rows.map(\.conversationID)).count == rows.count,
              Set(rows.map(\.metadata.id)).count == rows.count else { throw IMessageGatewayWireError.invalidFrame }
        for row in rows {
            guard identifier(row.conversationID) else { throw IMessageGatewayWireError.invalidFrame }
            try validateMetadata(row.metadata, exact: exact)
        }
    }

    private static func validateMetadata(_ row: IMessageConversation, exact: Bool) throws {
        guard row.id.value > 0, metadataText(row.guid), metadataText(row.name), row.participants.count <= 100,
              row.participants.allSatisfy({ metadataText($0, nonempty: true) }), row.accountID.map({ metadataText($0) }) ?? true,
              row.accountLogin.map({ metadataText($0) }) ?? true else { throw IMessageGatewayWireError.invalidFrame }
        if row.available {
            guard row.service == "iMessage", !row.guid.isEmpty else { throw IMessageGatewayWireError.invalidFrame }
        } else {
            guard row.service.isEmpty || row.service == "iMessage" else { throw IMessageGatewayWireError.invalidFrame }
            if exact {
                guard row.guid.isEmpty, row.name.isEmpty, row.service.isEmpty, !row.isGroup, row.participants.isEmpty,
                      row.accountID == nil, row.accountLogin == nil else { throw IMessageGatewayWireError.invalidFrame }
            }
        }
    }

    private static func controls(_ value: String) -> Bool { value.unicodeScalars.contains { $0.properties.generalCategory == .control } }
    private static func identifier(_ value: String) -> Bool {
        (1...256).contains(value.unicodeScalars.count) && value.trimmingCharacters(in: .whitespacesAndNewlines) == value && !controls(value)
    }
    private static func metadataText(_ value: String, nonempty: Bool = false) -> Bool { value.utf8.count <= 256 && (!nonempty || !value.isEmpty) }
    private static func canonical32(_ value: String) -> Bool {
        guard value.utf8.count == 43, let bytes = Data(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="), bytes.count == 32 else { return false }
        return bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") == value
    }
    private static func goJSONBytes(_ data: Data) -> Int {
        let bytes = Array(data)
        var count = bytes.count
        for index in bytes.indices {
            if [UInt8(0x3c), 0x3e, 0x26].contains(bytes[index]) { count += 5 }
            if index + 2 < bytes.count, bytes[index] == 0xe2, bytes[index + 1] == 0x80, [UInt8(0xa8), 0xa9].contains(bytes[index + 2]) { count += 3 }
        }
        return count
    }
}

extension DesktopControlFrame {
    internal var hasLegacyIMessageFields: Bool {
        target != nil || operation != nil || arguments != nil || deadlineAt != nil || result != nil || errorCode != nil || errorMessage != nil ||
        streamID != nil || sequence != nil || streamChannel != nil || streamData != nil || lastHeartbeat != nil || readiness != nil ||
        diagnosticsSupported != nil || diagnostics != nil || imessageProtocolVersion != nil
    }
}
