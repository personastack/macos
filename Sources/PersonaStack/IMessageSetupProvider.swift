import CryptoKit
import Foundation
import PersonaStackCore

protocol IMessageSetupAccountReading: Sendable {
    func prepareProviderConnection(_ client: IMessageRPCClient) async throws
    func clearProviderBinding() async
    func validateProviderConnection() async throws
    func observeCurrentAccount() async throws -> IMessageCurrentAccountObservation
    func observe(chatGUIDs: [String], expectedAccountID: String?, requestAutomation: Bool) async throws -> IMessageLiveAccountObservation
}

extension IMessageAccountReader: IMessageSetupAccountReading {}

/// The app alone owns Apple account observation and the bundled provider child.
actor IMessageSetupProvider: IMessageSetupProviding {
    private let client: IMessageRPCClient
    private let accounts: any IMessageSetupAccountReading
    private let now: @Sendable () -> Date
    private var started = false
    private var generation: UInt64 = 0
    private var cleanup: Task<Void, Never>?

    init(client: IMessageRPCClient = IMessageRPCClient(transport: IMessageSubprocessTransport(bundle: .main)),
         accounts: any IMessageSetupAccountReading = IMessageAccountReader(),
         now: @escaping @Sendable () -> Date = Date.init) {
        self.client = client; self.accounts = accounts; self.now = now
    }

    static func setupReferenceDigest(_ reference: String) -> String {
        Data(SHA256.hash(data: Data(reference.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func prerequisites(deadline: Date) async throws -> IMessageGatewayPrerequisitesResult {
        let expected = generation
        do {
            let status = try await ready(deadline: deadline)
            return .init(protocolVersion: status.protocolVersion, adapterRevision: status.adapterRevision,
                         databaseReady: status.database.ready)
        } catch { throw await finishFailure(error, expectedGeneration: expected) }
    }

    func conversations(after: IMessageRowID, upper: IMessageRowID?, query: String, limit: Int,
                       deadline: Date) async throws -> IMessageSetupProviderPage {
        let expected = generation
        do {
            _ = try await ready(deadline: deadline)
            let expected = generation
            let account = try await accounts.observeCurrentAccount()
            try requireCurrent(expected, deadline: deadline)
            let page = try await client.conversations(after: after, upper: upper, query: query, limit: limit)
            try requireCurrent(expected, deadline: deadline)
            try await accounts.validateProviderConnection()
            try requireCurrent(expected, deadline: deadline)
            return .init(page: page, account: .init(accountID: account.accountID, sourceGeneration: account.sourceGeneration))
        } catch { throw await finishFailure(error, expectedGeneration: expected) }
    }

    func verify(conversations: [IMessageConversation], account: IMessageSetupAccount,
                deadline: Date) async throws -> IMessageSetupProviderVerification {
        let expected = generation
        do {
            _ = try await ready(deadline: deadline)
            let expected = generation
            let metadata = try await client.chatMetadata(chatIDs: conversations.map(\.id)).chats
            try requireCurrent(expected, deadline: deadline)
            guard metadata.count == conversations.count else { throw IMessageSetupProviderError.dependencyInvalid }
            for (requested, current) in zip(conversations, metadata) {
                guard requested.id == current.id else { throw IMessageSetupProviderError.dependencyInvalid }
                guard !current.available || current.guid == requested.guid else { throw IMessageSetupProviderError.accountChanged }
            }
            let available = metadata.filter(\.available).map(\.guid)
            var evidence: IMessageGatewayLiveAccountEvidence?
            if !available.isEmpty {
                // One exact batch. A second current-account probe would waste the command budget.
                let observed = try await accounts.observe(chatGUIDs: available,
                    expectedAccountID: account.accountID, requestAutomation: false)
                try requireCurrent(expected, deadline: deadline)
                guard observed.accountID == account.accountID, observed.sourceGeneration == account.sourceGeneration,
                      observed.chatGUIDs == available else { throw IMessageSetupProviderError.accountChanged }
                evidence = .init(accountID: observed.accountID, sourceGeneration: observed.sourceGeneration, chatGUIDs: available)
            }
            try await accounts.validateProviderConnection()
            try requireCurrent(expected, deadline: deadline)
            return .init(conversations: metadata, liveAccount: evidence)
        } catch { throw await finishFailure(error, expectedGeneration: expected) }
    }

    func stop() async {
        if let cleanup { await cleanup.value; return }
        generation &+= 1
        started = false
        let accounts = accounts, client = client
        let task = Task {
            await accounts.clearProviderBinding()
            await client.stop()
        }
        cleanup = task
        await task.value
        cleanup = nil
    }

    private func finishFailure(_ error: Error, expectedGeneration: UInt64) async -> IMessageSetupProviderError {
        if generation == expectedGeneration, Self.requiresFreshConnection(error) { await stop() }
        return Self.safeError(error)
    }

    private static func requiresFreshConnection(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        switch error as? IMessageRPCError {
        case .notStarted, .alreadyStarted, .invalidResponse, .frameTooLarge, .dependencyInvalid,
             .processExited, .deadlineExceeded, .cancelled, .outcomeUnknown:
            return true
        default: return false
        }
    }

    private func ready(deadline: Date) async throws -> IMessageRPCStatus {
        if let cleanup { await cleanup.value }
        try check(deadline)
        let expected = generation
        let status: IMessageRPCStatus
        if started { status = try await client.status() }
        else {
            try await accounts.prepareProviderConnection(client)
            try requireCurrent(expected, deadline: deadline)
            status = try await client.start()
            try requireCurrent(expected, deadline: deadline)
            started = true
        }
        try requireCurrent(expected, deadline: deadline)
        try await accounts.validateProviderConnection()
        try requireCurrent(expected, deadline: deadline)
        return status
    }

    private func check(_ deadline: Date) throws {
        try Task.checkCancellation()
        guard deadline > now() else { throw IMessageSetupProviderError.providerTimeout }
    }

    private func requireCurrent(_ value: UInt64, deadline: Date) throws {
        try check(deadline)
        guard generation == value else { throw CancellationError() }
    }

    private static func safeError(_ error: Error) -> IMessageSetupProviderError {
        if let typed = error as? IMessageSetupProviderError { return typed }
        if let account = error as? IMessageAccountError {
            switch account {
            case .automationRequired, .sourceUnavailable: return .permissionRequired
            case .messagesNotRunning, .selectedAccountUnavailable: return .messagesUnavailable
            case .sourceChanged: return .accountChanged
            case .sourceRecordUnavailable: return .dependencyInvalid
            }
        }
        switch error as? IMessageRPCError {
        case .busy: return .busy
        case .deadlineExceeded, .cancelled: return .providerTimeout
        case .frameTooLarge: return .payloadTooLarge
        default: return .dependencyInvalid
        }
    }
}
