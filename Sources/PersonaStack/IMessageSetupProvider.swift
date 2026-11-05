import CryptoKit
import Foundation
import PersonaStackCore

protocol IMessageSetupAccountReading: Sendable {
    func prepareProviderConnection(_ client: IMessageRPCClient) async throws
    func clearProviderBinding() async
    func validateProviderConnection() async throws
    func observeCurrentAccount() async throws -> IMessageCurrentAccountObservation
    func requestCurrentAccountPermission() async throws -> IMessageCurrentAccountObservation
    func observe(chatGUIDs: [String], expectedAccountID: String?, requestAutomation: Bool) async throws -> IMessageLiveAccountObservation
}

extension IMessageSetupAccountReading {
    func requestCurrentAccountPermission() async throws -> IMessageCurrentAccountObservation {
        throw IMessageAccountError.automationRequired
    }
}

extension IMessageAccountReader: IMessageSetupAccountReading {}

enum IMessageSetupPermissionState: Equatable, Sendable {
    case ready, messagesNotRunning, fullDiskAccessRequired, automationRequired, sourceChanged, unavailable
}

/// The app alone owns Apple account observation and the bundled provider child.
actor IMessageSetupProvider: IMessageSetupProviding {
    private let client: IMessageRPCClient
    private let accounts: any IMessageSetupAccountReading
    private let now: @Sendable () -> Date
    private var started = false
    private var generation: UInt64 = 0
    private var cleanup: Task<Void, Never>?
    private var approvalID: UUID?
    private var accountDisplay: (account: IMessageSetupAccount, label: String)?

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
            rememberDisplay(account.accountLabel, accountID: account.accountID, sourceGeneration: account.sourceGeneration)
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

    /// Passive native setup check. It never asks for Automation permission.
    func setupPermissionState(deadline: Date) async throws -> IMessageSetupPermissionState {
        let expected = generation
        let deadline = min(deadline, now().addingTimeInterval(IMessageRuntime.commandLifetime))
        do {
            let result: IMessageSetupPermissionState = try await bounded(deadline: deadline, generation: expected) {
                let status = try await self.ready(deadline: deadline, expectedGeneration: expected)
                guard status.database.ready else {
                    await self.stop()
                    return .unavailable
                }
                let observed = try await self.accounts.observeCurrentAccount()
                try await self.requireCurrent(expected, deadline: deadline)
                try await self.accounts.validateProviderConnection()
                try await self.requireCurrent(expected, deadline: deadline)
                await self.rememberDisplay(observed.accountLabel, accountID: observed.accountID, sourceGeneration: observed.sourceGeneration)
                return .ready
            }
            try Task.checkCancellation()
            return result
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            let state = Self.permissionState(for: error)
            if generation == expected, Self.requiresFreshConnection(error) || (error as? IMessageAccountError) != nil { await stop() }
            try Task.checkCancellation()
            return state
        }
    }

    private static func permissionState(for error: Error) -> IMessageSetupPermissionState {
        switch error as? IMessageAccountError {
        case .messagesNotRunning: .messagesNotRunning
        case .sourceUnavailable: .fullDiskAccessRequired
        case .automationRequired: .automationRequired
        case .sourceChanged: .sourceChanged
        default: .unavailable
        }
    }

    /// Explicit native Allow Messages Access only. Passive consumers never call this.
    func requestMessagesAccess(deadline: Date) async throws {
        let expected = generation
        do {
            _ = try await ready(deadline: deadline, expectedGeneration: expected)
            let observed = try await accounts.requestCurrentAccountPermission()
            try requireCurrent(expected, deadline: deadline)
            rememberDisplay(observed.accountLabel, accountID: observed.accountID, sourceGeneration: observed.sourceGeneration)
        } catch { throw await finishFailure(error, expectedGeneration: expected) }
    }

    /// Native display only. A label is never sender-address or account proof.
    func displayAccount(for account: IMessageSetupAccount) async throws -> String {
        let expected = generation
        try await accounts.validateProviderConnection()
        try requireCurrent(expected, deadline: now().addingTimeInterval(1))
        guard let accountDisplay, accountDisplay.account == account else { throw IMessageSetupProviderError.accountChanged }
        return accountDisplay.label
    }

    func restore(selections: [IMessageSetupDraft.Selection], account: IMessageSetupAccount,
                 deadline: Date) async throws -> IMessageSetupProviderVerification {
        let expected = generation
        do {
            guard (1...32).contains(selections.count), Set(selections.map(\.nativeChatRowID)).count == selections.count,
                  Set(selections.map(\.expectedGUID)).count == selections.count else { throw IMessageSetupProviderError.accountChanged }
            let ids = try selections.map { try IMessageRowID(decimal: $0.nativeChatRowID) }
            return try await bounded(deadline: deadline, generation: expected) {
                try await self.refreshSelection(chatIDs: ids, expectedGUIDs: selections.map(\.expectedGUID), account: account,
                    deadline: deadline, requireAvailable: true, expectedGeneration: expected)
            }
        } catch { throw await finishFailure(error, expectedGeneration: expected) }
    }

    private func bounded<Value: Sendable>(deadline: Date, generation expected: UInt64,
                                         operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try check(deadline)
        let delay = deadline.timeIntervalSince(now())
        return try await withThrowingTaskGroup(of: Value.self) { tasks in
            tasks.addTask { try await operation() }
            tasks.addTask {
                try await Task.sleep(for: .seconds(delay))
                throw IMessageSetupProviderError.providerTimeout
            }
            do {
                guard let result = try await tasks.next() else { throw IMessageSetupProviderError.dependencyInvalid }
                tasks.cancelAll()
                return result
            } catch {
                tasks.cancelAll()
                if self.generation == expected { await self.stop() }
                throw error
            }
        }
    }

    private func rememberDisplay(_ label: String?, accountID: String, sourceGeneration: String) {
        guard let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, label.utf8.count <= 256,
              !label.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return }
        accountDisplay = (.init(accountID: accountID, sourceGeneration: sourceGeneration), label)
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
            let result = try await bounded(deadline: originalDeadline, generation: expected) {
                try await self.collectApproval(consent, generation: expected, deadline: originalDeadline, validation: validation)
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
        try await refreshSelection(chatIDs: conversations.map(\.id), expectedGUIDs: conversations.map(\.guid), account: account,
            deadline: deadline, requireAvailable: requireAvailable, validation: validation, expectedGeneration: expectedGeneration)
    }

    private func refreshSelection(chatIDs: [IMessageRowID], expectedGUIDs: [String], account: IMessageSetupAccount, deadline: Date,
                                  requireAvailable: Bool, validation: (@Sendable () async throws -> Bool)? = nil,
                                  expectedGeneration: UInt64? = nil) async throws -> IMessageSetupProviderVerification {
        _ = try await ready(deadline: deadline, validation: validation, expectedGeneration: expectedGeneration)
        let expected = expectedGeneration ?? generation
        try await requireContext(expected, deadline: deadline, validation: validation)
        let metadata = try await client.chatMetadata(chatIDs: chatIDs).chats
        try await requireContext(expected, deadline: deadline, validation: validation)
        guard metadata.map(\.id) == chatIDs, expectedGUIDs.count == metadata.count else { throw IMessageSetupProviderError.dependencyInvalid }
        for (guid, current) in zip(expectedGUIDs, metadata) {
            guard !current.available || current.guid == guid else { throw IMessageSetupProviderError.accountChanged }
        }
        if requireAvailable && !metadata.allSatisfy(\.available) { throw IMessageSetupApprovalError.selectionUnavailable }
        let available = metadata.filter(\.available).map(\.guid)
        var evidence: IMessageGatewayLiveAccountEvidence?
        if !available.isEmpty {
            let observed = try await accounts.observe(chatGUIDs: available, expectedAccountID: account.accountID, requestAutomation: false)
            try await requireContext(expected, deadline: deadline, validation: validation)
            guard observed.accountID == account.accountID, observed.sourceGeneration == account.sourceGeneration,
                  observed.chatGUIDs == available else { throw IMessageSetupProviderError.accountChanged }
            rememberDisplay(observed.accountLabel, accountID: observed.accountID, sourceGeneration: observed.sourceGeneration)
            evidence = .init(accountID: observed.accountID, sourceGeneration: observed.sourceGeneration, chatGUIDs: available)
        }
        try await accounts.validateProviderConnection()
        try await requireContext(expected, deadline: deadline, validation: validation)
        return .init(conversations: metadata, liveAccount: evidence)
    }

    static func messageTextDigest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func executeConfigured(_ input: IMessageGatewayConfiguredInput, scope: IMessageGatewayConfigScope, deadline: Date,
                           validateCurrent: @escaping @Sendable () async throws -> Bool) async throws -> IMessageGatewayConfiguredResult {
        let expected = generation
        do {
            try IMessageConfiguredGatewayValidation.validate(input, in: scope)
            return try await bounded(deadline: deadline, generation: expected) {
                try await self.performConfigured(input, scope: scope, generation: expected, deadline: deadline, validation: validateCurrent)
            }
        } catch { throw await finishFailure(error, expectedGeneration: expected) }
    }

    private func performConfigured(_ input: IMessageGatewayConfiguredInput, scope: IMessageGatewayConfigScope, generation expected: UInt64,
                                   deadline: Date, validation: @escaping @Sendable () async throws -> Bool) async throws -> IMessageGatewayConfiguredResult {
        let status = try await ready(deadline: deadline, validation: validation, expectedGeneration: expected)
        guard status.database.ready else { throw IMessageSetupProviderError.messagesUnavailable }
        if case .status = input {
            try await observeConfiguredAccount(scope, bindings: [], generation: expected, deadline: deadline, validation: validation)
            return .status(.init(state: .connected, protocolVersion: status.protocolVersion, adapterRevision: status.adapterRevision))
        }
        let bindings = try configuredBindings(input, scope: scope)
        let metadata = try await client.chatMetadata(chatIDs: bindings.map(\.nativeChatID)).chats
        try await requireContext(expected, deadline: deadline, validation: validation)
        guard metadata.map(\.id) == bindings.map(\.nativeChatID) else { throw IMessageSetupProviderError.dependencyInvalid }
        for (row, binding) in zip(metadata, bindings) {
            guard !row.available || (row.guid == binding.nativeChatGUID && row.service == "iMessage") else { throw IMessageSetupProviderError.accountChanged }
        }
        let available = zip(metadata, bindings).filter { $0.0.available }.map { $0.1 }
        try await observeConfiguredAccount(scope, bindings: available, generation: expected, deadline: deadline, validation: validation)
        return try await configuredResult(input, scope: scope, bindings: bindings, metadata: metadata,
            generation: expected, deadline: deadline, validation: validation)
    }

    private func configuredBindings(_ input: IMessageGatewayConfiguredInput, scope: IMessageGatewayConfigScope) throws -> [IMessageGatewayConversationBinding] {
        let ids: [String]
        switch input {
        case .status: ids = []
        case .conversations: ids = scope.conversationIDs
        case .conversation(let value): ids = [value.conversationID]
        case .recentMessages(let value): ids = [value.conversationID]
        case .sendMessage(let value): ids = [value.conversationID]
        case .receivePage(let value): ids = [value.conversationID]
        case .sourceCheckpoint(let value): ids = value.conversationIDs
        }
        return try ids.map { id in
            guard let binding = scope.conversationBindings.first(where: { $0.conversationID == id }) else { throw IMessageSetupProviderError.accountChanged }
            return binding
        }
    }

    private func observeConfiguredAccount(_ scope: IMessageGatewayConfigScope, bindings: [IMessageGatewayConversationBinding], generation expected: UInt64,
                                          deadline: Date, validation: @escaping @Sendable () async throws -> Bool) async throws {
        try await requireContext(expected, deadline: deadline, validation: validation)
        let account: IMessageSetupAccount
        if bindings.isEmpty {
            let value = try await accounts.observeCurrentAccount()
            try await requireContext(expected, deadline: deadline, validation: validation)
            account = .init(accountID: value.accountID, sourceGeneration: value.sourceGeneration)
            rememberDisplay(value.accountLabel, accountID: value.accountID, sourceGeneration: value.sourceGeneration)
        } else {
            let guids = bindings.map(\.nativeChatGUID)
            let value = try await accounts.observe(chatGUIDs: guids, expectedAccountID: scope.accountID, requestAutomation: false)
            try await requireContext(expected, deadline: deadline, validation: validation)
            guard value.chatGUIDs == guids else { throw IMessageSetupProviderError.accountChanged }
            account = .init(accountID: value.accountID, sourceGeneration: value.sourceGeneration)
            rememberDisplay(value.accountLabel, accountID: value.accountID, sourceGeneration: value.sourceGeneration)
        }
        guard account.accountID == scope.accountID, account.sourceGeneration == scope.sourceGeneration else { throw IMessageSetupProviderError.accountChanged }
        try await accounts.validateProviderConnection()
        try await requireContext(expected, deadline: deadline, validation: validation)
    }

    private func configuredResult(_ input: IMessageGatewayConfiguredInput, scope: IMessageGatewayConfigScope,
                                  bindings: [IMessageGatewayConversationBinding], metadata: [IMessageConversation], generation expected: UInt64,
                                  deadline: Date, validation: @escaping @Sendable () async throws -> Bool) async throws -> IMessageGatewayConfiguredResult {
        switch input {
        case .status: throw IMessageSetupProviderError.dependencyInvalid
        case .conversations:
            let rows = try zip(metadata, bindings).map { try IMessageConfiguredProjection.conversation($0.0, binding: $0.1) }
            return .conversations(.init(conversations: rows))
        case .conversation:
            guard let row = metadata.first, let binding = bindings.first else { throw IMessageSetupProviderError.dependencyInvalid }
            return .conversation(.init(conversation: try IMessageConfiguredProjection.conversation(row, binding: binding)))
        case .sourceCheckpoint(let request):
            let anchors = try (request.anchors ?? []).map { anchor -> IMessageSourceAnchor in
                guard let binding = bindings.first(where: { $0.conversationID == anchor.conversationID }) else { throw IMessageSetupProviderError.accountChanged }
                return .init(chatID: binding.nativeChatID, rowID: anchor.rowID, guid: anchor.guid)
            }
            let checkpoint = try await client.sourceCheckpoint(chatIDs: bindings.map(\.nativeChatID), anchors: anchors)
            try await requireContext(expected, deadline: deadline, validation: validation)
            let available = zip(metadata, bindings).filter { $0.0.available }.map { $0.1 }
            try await observeConfiguredAccount(scope, bindings: available, generation: expected, deadline: deadline, validation: validation)
            return .sourceCheckpoint(try IMessageConfiguredProjection.checkpoint(checkpoint, scope: scope, input: request,
                liveAccount: .init(accountID: scope.accountID, sourceGeneration: scope.sourceGeneration), deadline: Self.utc(deadline)))
        default:
            guard let binding = bindings.first, metadata.first?.available == true else { throw IMessageSetupProviderError.messagesUnavailable }
            return try await configuredContent(input, scope: scope, binding: binding, generation: expected, deadline: deadline, validation: validation)
        }
    }

    private func configuredContent(_ input: IMessageGatewayConfiguredInput, scope: IMessageGatewayConfigScope, binding: IMessageGatewayConversationBinding,
                                   generation expected: UInt64, deadline: Date,
                                   validation: @escaping @Sendable () async throws -> Bool) async throws -> IMessageGatewayConfiguredResult {
        switch input {
        case .recentMessages(let request):
            let limit = request.limit ?? 50
            let source = try await client.recentMessages(chatID: binding.nativeChatID, limit: limit)
            try await requireContext(expected, deadline: deadline, validation: validation)
            try await observeConfiguredAccount(scope, bindings: [binding], generation: expected, deadline: deadline, validation: validation)
            return .recentMessages(try IMessageConfiguredProjection.recentMessages(source, binding: binding, limit: limit))
        case .receivePage(let request):
            let checkpoint = try await client.sourceCheckpoint(chatIDs: [binding.nativeChatID])
            try await requireContext(expected, deadline: deadline, validation: validation)
            guard let row = checkpoint.chats.first, row.available, row.guid == binding.nativeChatGUID,
                  row.service == "iMessage", checkpoint.sourceHighWater >= request.after else { throw IMessageSetupProviderError.accountChanged }
            let through = min(request.through ?? checkpoint.sourceHighWater, checkpoint.sourceHighWater)
            let source = try await client.receivePage(chatID: binding.nativeChatID, since: request.after, through: through, limit: request.limit)
            try await requireContext(expected, deadline: deadline, validation: validation)
            try await observeConfiguredAccount(scope, bindings: [binding], generation: expected, deadline: deadline, validation: validation)
            return .receivePage(try IMessageConfiguredProjection.receivePage(source, binding: binding, scope: scope, input: request,
                sourceHighWater: checkpoint.sourceHighWater, deadline: Self.utc(deadline)))
        case .sendMessage(let request):
            let receipt = try await client.send(chatID: binding.nativeChatID, text: request.text, expectedAccountID: scope.accountID,
                expectedChatGUID: binding.nativeChatGUID, deadline: deadline, validateCurrent: {
                    try await self.requireContext(expected, deadline: deadline, validation: validation)
                    try await self.accounts.validateProviderConnection()
                    try await self.requireContext(expected, deadline: deadline, validation: validation)
                    return true
                })
            try await requireContext(expected, deadline: deadline, validation: validation)
            try await observeConfiguredAccount(scope, bindings: [binding], generation: expected, deadline: deadline, validation: validation)
            return .sendMessage(try IMessageConfiguredProjection.sendReceipt(receipt, binding: binding, input: request, confirmedAt: Self.utc(now())))
        default: throw IMessageSetupProviderError.dependencyInvalid
        }
    }
    private static func utc(_ value: Date) -> String { ISO8601DateFormatter().string(from: value) }

    func stop() async {
        if let cleanup { await cleanup.value; return }
        generation &+= 1
        started = false
        accountDisplay = nil
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
        if (error as? IMessageAccountError) == .sourceChanged || (error as? IMessageSetupProviderError) == .accountChanged { return true }
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
