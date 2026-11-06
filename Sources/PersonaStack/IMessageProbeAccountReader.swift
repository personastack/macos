import AppKit
import CoreServices
import CryptoKit
import Foundation
import PersonaStackCore

enum IMessageAccountError: Error, Equatable {
    case messagesNotRunning, automationRequired, selectedAccountUnavailable
    case sourceUnavailable, sourceRecordUnavailable, sourceChanged

    var safeMessage: String {
        switch self {
        case .messagesNotRunning: "Open Messages, then verify again."
        case .automationRequired: "Allow PersonaStack to control Messages in System Settings."
        case .selectedAccountUnavailable: "The selected conversation needs a connected iMessage account in Messages."
        case .sourceUnavailable: "Allow PersonaStack Full Disk Access, then restart PersonaStack."
        case .sourceRecordUnavailable: "The local connection record could not be saved."
        case .sourceChanged: "The Messages source changed. Close this check and review the connection again."
        }
    }
}

/// The live public account observation for every exact requested conversation.
/// SQLite account attributes are never used as account or generation evidence.
struct IMessageLiveAccountObservation: Equatable, Sendable {
    let accountID: String
    let sourceGeneration: String
    let chatGUIDs: [String]
    let accountLabel: String?
    init(accountID: String, sourceGeneration: String, chatGUIDs: [String], accountLabel: String? = nil) {
        self.accountID = accountID; self.sourceGeneration = sourceGeneration; self.chatGUIDs = chatGUIDs; self.accountLabel = accountLabel
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.accountID == rhs.accountID && lhs.sourceGeneration == rhs.sourceGeneration && lhs.chatGUIDs == rhs.chatGUIDs
    }
}

struct IMessageCurrentAccountObservation: Equatable, Sendable {
    let accountID: String
    let sourceGeneration: String
    let accountLabel: String?
    init(accountID: String, sourceGeneration: String, accountLabel: String? = nil) {
        self.accountID = accountID; self.sourceGeneration = sourceGeneration; self.accountLabel = accountLabel
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.accountID == rhs.accountID && lhs.sourceGeneration == rhs.sourceGeneration
    }
}

struct IMessageSourceFileIdentity: Codable, Equatable, Sendable {
    let volumeUUID: String
    let file: String
    let birth: Date
}

protocol IMessageAccountEnvironment: Sendable {
    func messagesBundleID() -> String?
    func messagesRunning(bundleID: String) async -> Bool
    func permissionAllowed(bundleID: String, requestAutomation: Bool) async -> Bool
    func sourceIdentity() throws -> IMessageSourceFileIdentity
    func sourceGeneration(identity: IMessageSourceFileIdentity, accountID: String) throws -> String
}

/// Shared production and diagnostic account proof. It reads no message body.
actor IMessageAccountReader {
    static let maximumChatCount = 32
    static let processTimeoutSeconds: TimeInterval = 5
    static let maximumOutputBytes = 4096
    private let environment: any IMessageAccountEnvironment
    private let process: any CuaProcessRunning
    private var connectionSource: IMessageSourceFileIdentity?
    private var connectionAccountID: String?
    private var bindingGeneration: UInt64 = 0
    private var observing = false

    init(environment: (any IMessageAccountEnvironment)? = nil, process: (any CuaProcessRunning)? = nil) {
        self.environment = environment ?? SystemIMessageAccountEnvironment()
        self.process = process ?? SystemCuaProcessRunner(timeout: Self.processTimeoutSeconds, outputLimit: Self.maximumOutputBytes)
    }

    private static let script = """
        on run argv
            if (count of argv) < 1 or (count of argv) > 32 then return "unavailable"
            try
                set commonAccountID to missing value
                set commonAccountLabel to ""
                tell application "/System/Applications/Messages.app"
                    repeat with requestedGUID in argv
                        set exactGUID to requestedGUID as text
                        set selectedChat to get chat id exactGUID
                        if (id of selectedChat as text) is not exactGUID then return "unavailable"
                        set selectedAccount to get account of selectedChat
                        if (service type of selectedAccount) is not iMessage then return "unavailable"
                        if (enabled of selectedAccount) is false then return "unavailable"
                        if (connection status of selectedAccount) is not connected then return "unavailable"
                        set observedAccountID to id of selectedAccount as text
                        if commonAccountID is missing value then
                            set commonAccountID to observedAccountID
                            set commonAccountLabel to description of selectedAccount as text
                        else if commonAccountID is not observedAccountID then
                            return "unavailable"
                        end if
                    end repeat
                    if (count of commonAccountLabel) > 256 then set commonAccountLabel to ""
                    return commonAccountID & tab & commonAccountLabel
                end tell
            on error
                return "unavailable"
            end try
        end run
        """

    private static let currentAccountScript = """
        on run argv
            if (count of argv) is not 0 then return "unavailable"
            try
                set observedAccountIDs to {}
                set observedAccountLabel to ""
                tell application "/System/Applications/Messages.app"
                    repeat with candidateAccount in accounts
                        -- Only fully verified accounts qualify. Unreadable entries remain ineligible.
                        try
                            if (service type of candidateAccount) is iMessage then
                                if (enabled of candidateAccount) is true then
                                    if (connection status of candidateAccount) is connected then
                                        set end of observedAccountIDs to id of candidateAccount as text
                                        set observedAccountLabel to description of candidateAccount as text
                                    end if
                                end if
                            end if
                        end try
                    end repeat
                end tell
                if (count of observedAccountIDs) is not 1 then return "unavailable"
                if (count of observedAccountLabel) > 256 then set observedAccountLabel to ""
                return (item 1 of observedAccountIDs) & tab & observedAccountLabel
            on error
                return "unavailable"
            end try
        end run
        """

    /// Inventory needs a live account before any conversation has been selected.
    /// This passive read cannot request Automation or launch Messages.
    func observeCurrentAccount() async throws -> IMessageCurrentAccountObservation {
        try await observeCurrentAccount(requestAutomation: false)
    }

    func requestCurrentAccountPermission() async throws -> IMessageCurrentAccountObservation {
        try await observeCurrentAccount(requestAutomation: true)
    }

    private func observeCurrentAccount(requestAutomation: Bool) async throws -> IMessageCurrentAccountObservation {
        let observation = try await observeAccount(script: Self.currentAccountScript, arguments: [],
            expectedAccountID: nil, requestAutomation: requestAutomation)
        return IMessageCurrentAccountObservation(accountID: observation.accountID,
            sourceGeneration: observation.sourceGeneration, accountLabel: observation.accountLabel)
    }

    /// Stop the old descriptor before binding path evidence for a fresh provider.
    func prepareProviderConnection(_ client: IMessageRPCClient) async throws {
        bindingGeneration &+= 1
        let expected = bindingGeneration
        connectionSource = nil
        connectionAccountID = nil
        await client.stop()
        try Task.checkCancellation()
        guard bindingGeneration == expected else { throw IMessageAccountError.sourceChanged }
        connectionSource = try environment.sourceIdentity()
    }

    func clearProviderBinding() {
        bindingGeneration &+= 1
        connectionSource = nil
        connectionAccountID = nil
    }

    func validateProviderConnection() throws {
        try Task.checkCancellation()
        _ = try verifiedConnectionSource()
    }

    /// Passive and remote consumers leave requestAutomation false. Only an
    /// explicit local permission action may set it to true.
    func observe(chatGUIDs: [String], expectedAccountID: String? = nil,
                 requestAutomation: Bool = false) async throws -> IMessageLiveAccountObservation {
        try Task.checkCancellation()
        try Self.validateSelection(chatGUIDs, expectedAccountID: expectedAccountID)
        return try await observeAccount(script: Self.script, arguments: chatGUIDs,
            expectedAccountID: expectedAccountID, requestAutomation: requestAutomation)
    }

    private func observeAccount(script: String, arguments: [String], expectedAccountID: String?,
                                requestAutomation: Bool) async throws -> IMessageLiveAccountObservation {
        try Task.checkCancellation()
        guard !observing else { throw IMessageRPCError.busy }
        observing = true
        defer { observing = false }
        let expectedBinding = bindingGeneration
        let sourceBefore = try verifiedConnectionSource()
        guard let bundleID = environment.messagesBundleID(), await environment.messagesRunning(bundleID: bundleID) else {
            throw IMessageAccountError.messagesNotRunning
        }
        try Task.checkCancellation()
        try requireBinding(expectedBinding, source: sourceBefore)
        let allowed = await environment.permissionAllowed(bundleID: bundleID, requestAutomation: requestAutomation)
        try Task.checkCancellation()
        try requireBinding(expectedBinding, source: sourceBefore)
        guard allowed else { throw IMessageAccountError.automationRequired }

        let runner = process
        let command = Task.detached {
            try runner.run(URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-e", script] + arguments)
        }
        let result = try await withTaskCancellationHandler { try await command.value } onCancel: { command.cancel() }
        try Task.checkCancellation()
        try requireBinding(expectedBinding, source: sourceBefore)
        let display = try Self.readAccount(result)
        let accountID = display.id
        guard expectedAccountID.map({ $0 == accountID }) ?? true,
              connectionAccountID.map({ $0 == accountID }) ?? true else { throw IMessageAccountError.sourceChanged }
        let sourceGeneration = try environment.sourceGeneration(identity: sourceBefore, accountID: accountID)
        try Task.checkCancellation()
        try requireBinding(expectedBinding, source: sourceBefore)
        connectionAccountID = accountID
        return IMessageLiveAccountObservation(accountID: accountID, sourceGeneration: sourceGeneration, chatGUIDs: arguments, accountLabel: display.label)
    }

    private func verifiedConnectionSource() throws -> IMessageSourceFileIdentity {
        guard let connectionSource, try environment.sourceIdentity() == connectionSource else {
            throw IMessageAccountError.sourceChanged
        }
        return connectionSource
    }

    private func requireBinding(_ generation: UInt64, source: IMessageSourceFileIdentity) throws {
        guard bindingGeneration == generation, try verifiedConnectionSource() == source else {
            throw IMessageAccountError.sourceChanged
        }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 256 &&
        !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private static func validateSelection(_ chatGUIDs: [String], expectedAccountID: String?) throws {
        guard (1...maximumChatCount).contains(chatGUIDs.count), Set(chatGUIDs).count == chatGUIDs.count,
              chatGUIDs.allSatisfy({ validIdentifier($0) && !$0.hasPrefix("-") }),
              expectedAccountID.map(validIdentifier) ?? true else {
            throw IMessageAccountError.selectedAccountUnavailable
        }
    }

    private static func readAccount(_ result: CuaProcessResult) throws -> (id: String, label: String?) {
        guard result.status == 0, result.stdout.count <= maximumOutputBytes, result.stderr.count <= maximumOutputBytes,
              var accountID = String(data: result.stdout, encoding: .utf8) else {
            throw IMessageAccountError.selectedAccountUnavailable
        }
        if accountID.hasSuffix("\n") { accountID.removeLast() }
        if accountID.hasSuffix("\r") { accountID.removeLast() }
        let parts = accountID.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), validIdentifier(String(parts[0])), parts[0] != "unavailable" else {
            throw IMessageAccountError.selectedAccountUnavailable
        }
        // Display quality cannot change account identity or source continuity.
        let rawLabel = parts.count == 2 ? String(parts[1]) : nil
        let label = rawLabel.map { validIdentifier($0) ? $0 : "Messages" }
        return (String(parts[0]), label)
    }
}

private struct SystemIMessageAccountEnvironment: IMessageAccountEnvironment {
    private static let messagesApplicationURL = URL(fileURLWithPath: "/System/Applications/Messages.app")

    func messagesBundleID() -> String? {
        guard let identifier = Bundle(url: Self.messagesApplicationURL)?.bundleIdentifier,
              ["com.apple.MobileSMS", "com.apple.iChat"].contains(identifier) else { return nil }
        return identifier
    }

    func messagesRunning(bundleID: String) async -> Bool {
        await MainActor.run { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }
    }

    func permissionAllowed(bundleID: String, requestAutomation: Bool) async -> Bool {
        await Task.detached {
            var address = AEAddressDesc()
            let bytes = Array(bundleID.utf8)
            let status = bytes.withUnsafeBytes {
                AECreateDesc(DescType(typeApplicationBundleID), $0.baseAddress, $0.count, &address)
            }
            guard status == noErr else { return false }
            defer { AEDisposeDesc(&address) }
            return AEDeterminePermissionToAutomateTarget(
                &address, AEEventClass(kAECoreSuite), AEEventID(kAEGetData), requestAutomation
            ) == noErr
        }.value
    }

    private struct SourceEvidence: Encodable {
        let identity: IMessageSourceFileIdentity
        let accountID: String
    }

    private struct SourceRecord: Codable {
        let salt: String
        let fingerprint: String
        let generation: String
    }

    func sourceIdentity() throws -> IMessageSourceFileIdentity {
        let files = FileManager.default
        let database = files.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db")
        let attributes: [FileAttributeKey: Any]
        do { attributes = try files.attributesOfItem(atPath: database.path) }
        catch { throw IMessageAccountError.sourceUnavailable }
        let volumeUUID: String?
        do { volumeUUID = try database.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString }
        catch { throw IMessageAccountError.sourceUnavailable }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let volumeUUID, !volumeUUID.isEmpty, volumeUUID.utf8.count <= 256,
              let file = attributes[.systemFileNumber] as? NSNumber,
              let birth = attributes[.creationDate] as? Date else {
            throw IMessageAccountError.sourceUnavailable
        }
        return IMessageSourceFileIdentity(volumeUUID: volumeUUID, file: file.stringValue, birth: birth)
    }

    func sourceGeneration(identity: IMessageSourceFileIdentity, accountID: String) throws -> String {
        let files = FileManager.default
        do {
            let directory = try files.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("PersonaStack/IMessageProbe", isDirectory: true)
            try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let recordURL = directory.appendingPathComponent("source.json")
            let prior = try readSourceRecord(recordURL)
            let salt = prior?.salt ?? UUID().uuidString
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            encoder.dateEncodingStrategy = .secondsSince1970
            var material = Data(salt.utf8)
            material.append(try encoder.encode(SourceEvidence(identity: identity, accountID: accountID)))
            let fingerprint = Data(SHA256.hash(data: material)).base64EncodedString()
            if prior?.fingerprint == fingerprint, let prior { return prior.generation }
            let record = SourceRecord(salt: salt, fingerprint: fingerprint, generation: UUID().uuidString)
            try encoder.encode(record).write(to: recordURL, options: .atomic)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)
            return record.generation
        } catch {
            throw IMessageAccountError.sourceRecordUnavailable
        }
    }

    private func readSourceRecord(_ url: URL) throws -> SourceRecord? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: 8193), data.count <= 8192 else {
            throw IMessageAccountError.sourceRecordUnavailable
        }
        let record = try JSONDecoder().decode(SourceRecord.self, from: data)
        guard UUID(uuidString: record.salt) != nil, UUID(uuidString: record.generation) != nil,
              record.fingerprint.utf8.count <= 128 else { throw IMessageAccountError.sourceRecordUnavailable }
        return record
    }
}
