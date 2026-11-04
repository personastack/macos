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
    private var approvalID: UUID?

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
            return try await refreshSelection(conversations, account: account, deadline: deadline)
        } catch { throw await finishFailure(error, expectedGeneration: expected) }
    }

    /// Direct native final approval only. It is absent from the gateway and page
    /// bridges and cannot be authorized by metadata consent or machine presence.
    func approvalEvidence(for consent: IMessageSetupFinalConsent, deadline: Date,
                          validateCurrent: @escaping @Sendable (IMessageSetupFinalConsent) async throws -> Bool) async throws -> IMessageSetupApprovalEvidence {
        guard approvalID == nil else { throw IMessageSetupProviderError.busy }
        let id = UUID(), expected = generation
        approvalID = id
        defer { if approvalID == id { approvalID = nil } }
        let originalDeadline = min(deadline, consent.deadline)
        let validation: @Sendable () async throws -> Bool = { try await validateCurrent(consent) }
        do {
            try check(originalDeadline)
            let delay = originalDeadline.timeIntervalSince(now())
            let result = try await withThrowingTaskGroup(of: IMessageSetupApprovalEvidence.self) { tasks in
                tasks.addTask {
                    try await self.collectApproval(consent, generation: expected, deadline: originalDeadline, validation: validation)
                }
                tasks.addTask {
                    try await Task.sleep(for: .seconds(delay))
                    throw IMessageSetupProviderError.providerTimeout
                }
                do {
                    guard let result = try await tasks.next() else { throw IMessageSetupApprovalError.invalidEvidence }
                    tasks.cancelAll()
                    return result
                } catch {
                    tasks.cancelAll()
                    if self.generation == expected { await self.stop() }
                    throw error
                }
            }
            try await requireContext(expected, deadline: originalDeadline, validation: validation)
            return result
        } catch {
            if generation == expected { await stop() }
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let typed = error as? IMessageSetupApprovalError { throw typed }
            throw await finishFailure(error, expectedGeneration: expected)
        }
    }

    private func collectApproval(_ consent: IMessageSetupFinalConsent, generation expected: UInt64, deadline: Date,
                                 validation: @escaping @Sendable () async throws -> Bool) async throws -> IMessageSetupApprovalEvidence {
        try await requireContext(expected, deadline: deadline, validation: validation)
        let verified = try await refreshSelection(consent.conversations.map(\.metadata), account: consent.account,
            deadline: deadline, requireAvailable: true, validation: validation, expectedGeneration: expected)
        try await requireContext(expected, deadline: deadline, validation: validation)
        let checkpoint = try await client.sourceCheckpoint(chatIDs: consent.conversations.map(\.metadata.id))
        try await requireContext(expected, deadline: deadline, validation: validation)
        try await accounts.validateProviderConnection()
        try await requireContext(expected, deadline: deadline, validation: validation)
        let selected = zip(consent.conversations, verified.conversations).map {
            IMessageGatewaySetupConversation(conversationID: $0.0.conversationID, metadata: $0.1)
        }
        let result = try IMessageSetupApprovalEvidence(verification: .init(conversations: selected, liveAccount: verified.liveAccount),
            checkpoint: .init(checkpoint), readEnabled: consent.readEnabled, sendEnabled: consent.sendEnabled)
        try await requireContext(expected, deadline: deadline, validation: validation)
        return result
    }

    private func refreshSelection(_ conversations: [IMessageConversation], account: IMessageSetupAccount, deadline: Date,
                                  requireAvailable: Bool = false,
                                  validation: (@Sendable () async throws -> Bool)? = nil,
                                  expectedGeneration: UInt64? = nil) async throws -> IMessageSetupProviderVerification {
        _ = try await ready(deadline: deadline, validation: validation, expectedGeneration: expectedGeneration)
        let expected = expectedGeneration ?? generation
        try await requireContext(expected, deadline: deadline, validation: validation)
        let metadata = try await client.chatMetadata(chatIDs: conversations.map(\.id)).chats
        try await requireContext(expected, deadline: deadline, validation: validation)
        guard metadata.count == conversations.count else { throw IMessageSetupProviderError.dependencyInvalid }
        for (requested, current) in zip(conversations, metadata) {
            guard requested.id == current.id else { throw IMessageSetupProviderError.dependencyInvalid }
            guard !current.available || current.guid == requested.guid else { throw IMessageSetupProviderError.accountChanged }
        }
        if requireAvailable && !metadata.allSatisfy(\.available) { throw IMessageSetupApprovalError.selectionUnavailable }
        let available = metadata.filter(\.available).map(\.guid)
        var evidence: IMessageGatewayLiveAccountEvidence?
        if !available.isEmpty {
            let observed = try await accounts.observe(chatGUIDs: available, expectedAccountID: account.accountID, requestAutomation: false)
            try await requireContext(expected, deadline: deadline, validation: validation)
            guard observed.accountID == account.accountID, observed.sourceGeneration == account.sourceGeneration,
                  observed.chatGUIDs == available else { throw IMessageSetupProviderError.accountChanged }
            evidence = .init(accountID: observed.accountID, sourceGeneration: observed.sourceGeneration, chatGUIDs: available)
        }
        try await accounts.validateProviderConnection()
        try await requireContext(expected, deadline: deadline, validation: validation)
        return .init(conversations: metadata, liveAccount: evidence)
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

    private func ready(deadline: Date, validation: (@Sendable () async throws -> Bool)? = nil,
                       expectedGeneration: UInt64? = nil) async throws -> IMessageRPCStatus {
        if let cleanup { await cleanup.value }
        try check(deadline)
        let expected = expectedGeneration ?? generation
        try await requireContext(expected, deadline: deadline, validation: validation)
        let status: IMessageRPCStatus
        if started { status = try await client.status() }
        else {
            try await accounts.prepareProviderConnection(client)
            try await requireContext(expected, deadline: deadline, validation: validation)
            status = try await client.start()
            try await requireContext(expected, deadline: deadline, validation: validation)
            started = true
        }
        try await requireContext(expected, deadline: deadline, validation: validation)
        try await accounts.validateProviderConnection()
        try await requireContext(expected, deadline: deadline, validation: validation)
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

    private func requireContext(_ value: UInt64, deadline: Date,
                                validation: (@Sendable () async throws -> Bool)?) async throws {
        try requireCurrent(value, deadline: deadline)
        if let validation {
            guard try await validation() else { throw IMessageSetupApprovalError.scopeChanged }
            try requireCurrent(value, deadline: deadline)
        }
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
