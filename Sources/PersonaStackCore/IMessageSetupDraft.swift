import Foundation

public enum IMessageSetupDraftError: Error, Equatable, Sendable {
    case invalidRecord
    case scopeMismatch
    case conflictingJourney
    case expired
}

/// Private setup intention for visual restoration after relaunch. A draft is
/// never a grant, consent receipt or runtime snapshot. A trusted coordinator
/// must reauthorize the current human/workspace and freshly verify the account,
/// source and selected metadata before obtaining new local consent. Callback
/// generations and all transient tokens belong to that coordinator, not here.
public struct IMessageSetupDraft: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public struct SavedIntention: Codable, Equatable, Sendable, CustomStringConvertible, CustomReflectable {
        public let action: IMessageSavedPageCommand.Action
        public let configID: String
        public let expectedConfigVersion: Int64
        public var description: String { "IMessageSetupDraft.SavedIntention(<redacted>)" }
        public var customMirror: Mirror { Mirror(self, children: ["intention": "<redacted>"]) }
        public init(action: IMessageSavedPageCommand.Action, configID: String, expectedConfigVersion: Int64) throws {
            guard [.edit, .resume, .resumeFromNow, .repair].contains(action),
                  IMessageSavedPageCommand.validToken(configID), expectedConfigVersion > 0 else { throw IMessageSetupDraftError.invalidRecord }
            self.action = action; self.configID = configID; self.expectedConfigVersion = expectedConfigVersion
        }
        public init(from decoder: Decoder) throws {
            let all = try decoder.container(keyedBy: DraftKey.self)
            guard Set(all.allKeys.map(\.stringValue)) == Set(Keys.allCases.map(\.rawValue)) else { throw IMessageSetupDraftError.invalidRecord }
            let c = try decoder.container(keyedBy: Keys.self)
            let raw = try c.decode(String.self, forKey: .version)
            guard let action = IMessageSavedPageCommand.Action(rawValue: try c.decode(String.self, forKey: .flow)),
                  let version = Int64(raw), String(version) == raw else { throw IMessageSetupDraftError.invalidRecord }
            try self.init(action: action, configID: c.decode(String.self, forKey: .configID), expectedConfigVersion: version)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(action.rawValue, forKey: .flow); try c.encode(configID, forKey: .configID)
            try c.encode(String(expectedConfigVersion), forKey: .version)
        }
        private enum Keys: String, CodingKey, CaseIterable { case flow, configID = "config_id", version = "expected_config_version" }
    }
    public struct Selection: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        public let nativeChatRowID: String
        public let expectedGUID: String

        public init(nativeChatRowID: String, expectedGUID: String) throws {
            guard let row = Int64(nativeChatRowID), row > 0, String(row) == nativeChatRowID,
                  IMessageSetupDraft.identifier(expectedGUID) else { throw IMessageSetupDraftError.invalidRecord }
            self.nativeChatRowID = nativeChatRowID
            self.expectedGUID = expectedGUID
        }

        public var description: String { "IMessageSetupDraft.Selection(selectors: <redacted>)" }
        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, children: ["selectors": "<redacted>"]) }

        public init(from decoder: Decoder) throws {
            let all = try decoder.container(keyedBy: DraftKey.self)
            guard Set(all.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
                throw IMessageSetupDraftError.invalidRecord
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(nativeChatRowID: container.decode(String.self, forKey: .nativeChatRowID),
                          expectedGUID: container.decode(String.self, forKey: .expectedGUID))
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case nativeChatRowID = "native_chat_row_id", expectedGUID = "expected_guid"
        }
    }

    public let setupReference: String
    public let naturalUserID: String
    public let workspaceID: String
    public let environmentIdentity: String
    public let expiresAt: String
    public let expectedAccountID: String?
    public let sourceGeneration: String?
    public let selectedConversations: [Selection]
    public let savedIntention: SavedIntention?
    private let originalExpiry: Date

    public var expiry: Date { originalExpiry }
    public var description: String { "IMessageSetupDraft(identity: <redacted>, selections: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["identity": "<redacted>", "selections": "<redacted>"]) }

    public init(setupReference: String, naturalUserID: String, workspaceID: String,
                environmentIdentity: String, expiresAt: String, expectedAccountID: String? = nil,
                sourceGeneration: String? = nil, selectedConversations: [Selection] = [], savedIntention: SavedIntention? = nil) throws {
        let expiry: Date
        do {
            expiry = try IMessagePendingEnrollment.validateIdentity(setupReference: setupReference,
                naturalUserID: naturalUserID, workspaceID: workspaceID,
                environmentIdentity: environmentIdentity, expiresAt: expiresAt)
        } catch { throw IMessageSetupDraftError.invalidRecord }
        guard selectedConversations.count <= 32, (expectedAccountID == nil) == (sourceGeneration == nil),
              selectedConversations.isEmpty || expectedAccountID != nil else { throw IMessageSetupDraftError.invalidRecord }
        if let expectedAccountID, let sourceGeneration {
            guard Self.identifier(expectedAccountID), Self.identifier(sourceGeneration) else { throw IMessageSetupDraftError.invalidRecord }
        }
        var rows = Set<String>()
        var guids = Set<String>()
        for selection in selectedConversations {
            guard rows.insert(selection.nativeChatRowID).inserted, guids.insert(selection.expectedGUID).inserted else {
                throw IMessageSetupDraftError.invalidRecord
            }
        }
        self.setupReference = setupReference
        self.naturalUserID = naturalUserID
        self.workspaceID = workspaceID
        self.environmentIdentity = environmentIdentity
        self.expiresAt = expiresAt
        self.expectedAccountID = expectedAccountID
        self.sourceGeneration = sourceGeneration
        self.selectedConversations = selectedConversations
        self.savedIntention = savedIntention
        self.originalExpiry = expiry
    }

    public func requireEnvironment(_ expected: String) throws {
        guard environmentIdentity == expected else { throw IMessageSetupDraftError.scopeMismatch }
    }

    public func requireJourney(setupReference: String, naturalUserID: String, workspaceID: String,
                               environmentIdentity: String, expiresAt: String) throws {
        try requireEnvironment(environmentIdentity)
        guard self.setupReference == setupReference, self.naturalUserID == naturalUserID,
              self.workspaceID == workspaceID, self.expiresAt == expiresAt else {
            throw IMessageSetupDraftError.conflictingJourney
        }
    }

    public func requireUsable(now: Date) throws {
        guard expiry > now else { throw IMessageSetupDraftError.expired }
    }

    public init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: DraftKey.self)
        let keys = Set(all.allKeys.map(\.stringValue))
        let optionalKeys: Set<String> = [CodingKeys.expectedAccountID.rawValue, CodingKeys.sourceGeneration.rawValue, CodingKeys.savedIntention.rawValue]
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        guard allowed.subtracting(optionalKeys).isSubset(of: keys), keys.isSubset(of: allowed) else {
            throw IMessageSetupDraftError.invalidRecord
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .version) == 1,
              container.contains(.expectedAccountID) == container.contains(.sourceGeneration) else {
            throw IMessageSetupDraftError.invalidRecord
        }
        let account: String?
        let source: String?
        if container.contains(.expectedAccountID) {
            account = try container.decode(String.self, forKey: .expectedAccountID)
            source = try container.decode(String.self, forKey: .sourceGeneration)
        } else {
            account = nil
            source = nil
        }
        try self.init(setupReference: container.decode(String.self, forKey: .setupReference),
            naturalUserID: container.decode(String.self, forKey: .naturalUserID),
            workspaceID: container.decode(String.self, forKey: .workspaceID),
            environmentIdentity: container.decode(String.self, forKey: .environmentIdentity),
            expiresAt: container.decode(String.self, forKey: .expiresAt), expectedAccountID: account, sourceGeneration: source,
            selectedConversations: container.decode([Selection].self, forKey: .selectedConversations),
            savedIntention: container.contains(.savedIntention) ? container.decode(SavedIntention.self, forKey: .savedIntention) : nil)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .version)
        try container.encode(setupReference, forKey: .setupReference)
        try container.encode(naturalUserID, forKey: .naturalUserID)
        try container.encode(workspaceID, forKey: .workspaceID)
        try container.encode(environmentIdentity, forKey: .environmentIdentity)
        try container.encode(expiresAt, forKey: .expiresAt)
        try container.encodeIfPresent(expectedAccountID, forKey: .expectedAccountID)
        try container.encodeIfPresent(sourceGeneration, forKey: .sourceGeneration)
        try container.encode(selectedConversations, forKey: .selectedConversations)
        try container.encodeIfPresent(savedIntention, forKey: .savedIntention)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, setupReference = "setup_reference", naturalUserID = "natural_user_id"
        case workspaceID = "workspace_id", environmentIdentity = "environment_identity", expiresAt = "expires_at"
        case expectedAccountID = "expected_account_id", sourceGeneration = "source_generation"
        case selectedConversations = "selected_conversations", savedIntention = "saved_intention"
    }

    private static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
        !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}

private struct DraftKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
