import Foundation

public struct IMessageSetupAccount: Equatable, Sendable {
    public let accountID: String
    public let sourceGeneration: String
    public init(accountID: String, sourceGeneration: String) {
        self.accountID = accountID; self.sourceGeneration = sourceGeneration
    }
}

public struct IMessageSetupProviderPage: Sendable {
    public let page: IMessageConversationPage
    public let account: IMessageSetupAccount
    public init(page: IMessageConversationPage, account: IMessageSetupAccount) { self.page = page; self.account = account }
}

public struct IMessageSetupProviderVerification: Sendable {
    public let conversations: [IMessageConversation]
    public let liveAccount: IMessageGatewayLiveAccountEvidence?
    public init(conversations: [IMessageConversation], liveAccount: IMessageGatewayLiveAccountEvidence?) {
        self.conversations = conversations; self.liveAccount = liveAccount
    }
}

public enum IMessageSetupProviderError: Error, Equatable, Sendable {
    case permissionRequired, messagesUnavailable, accountChanged, dependencyInvalid, payloadTooLarge, providerTimeout, busy
    var code: IMessageGatewayFailureCode {
        switch self {
        case .permissionRequired: .permissionRequired
        case .messagesUnavailable: .messagesUnavailable
        case .accountChanged: .accountChanged
        case .dependencyInvalid: .dependencyInvalid
        case .payloadTooLarge: .payloadTooLarge
        case .providerTimeout: .providerTimeout
        case .busy: .busy
        }
    }
}

/// Metadata only. No message body, send, retry, or external authorization surface.
public protocol IMessageSetupProviding: Sendable {
    func prerequisites(deadline: Date) async throws -> IMessageGatewayPrerequisitesResult
    func conversations(after: IMessageRowID, upper: IMessageRowID?, query: String, limit: Int,
                       deadline: Date) async throws -> IMessageSetupProviderPage
    func verify(conversations: [IMessageConversation], account: IMessageSetupAccount,
                deadline: Date) async throws -> IMessageSetupProviderVerification
    func restore(selections: [IMessageSetupDraft.Selection], account: IMessageSetupAccount,
                 deadline: Date) async throws -> IMessageSetupProviderVerification
    func stop() async
}

public struct IMessageRuntimeRetainedSelection: Sendable {
    public let intent: IMessageRuntimeSetupIntent
    public let conversations: [IMessageGatewaySetupConversation]
    public let account: IMessageSetupAccount
    public let expiresAt: Date
}

public extension IMessageSetupProviding {
    func restore(selections: [IMessageSetupDraft.Selection], account: IMessageSetupAccount,
                 deadline: Date) async throws -> IMessageSetupProviderVerification {
        throw IMessageSetupProviderError.dependencyInvalid
    }
}

/// A trusted native coordinator owns this exact receipt. It is not API authority.
public struct IMessageRuntimeSetupIntent: Equatable, Sendable {
    public let localGeneration: UUID
    public let scope: IMessageGatewaySetupScope
    public init(localGeneration: UUID, scope: IMessageGatewaySetupScope) {
        self.localGeneration = localGeneration; self.scope = scope
    }
}

public actor IMessageRuntime {
    public static let maximumWaitingCommands = 8
    public static let commandLifetime: TimeInterval = 10
    public static let inventoryLifetime: TimeInterval = 300
    public typealias Reply = @Sendable (IMessageGatewayPayload) async -> Void
    private let installationID: String
    private let provider: any IMessageSetupProviding
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> String
    private let referenceDigest: @Sendable (String) -> String
    private var connectionID: UUID?
    private var intent: IMessageRuntimeSetupIntent?
    private var metadataConsent = false
    private var retired = false
    private var snapshot: IMessageGatewaySnapshot?
    private var highestRevision: Int64 = 0
    private var restrictiveCutoff: Int64 = 0
    private var waiting: [Job] = []
    private var active: (job: Job, task: Task<Void, Never>, timer: Task<Void, Never>)?
    private var inventory = IMessageRuntimeInventory()
    private var cleanup: Task<Void, Never>?
    private var restoration: (id: UUID, task: Task<IMessageRuntimeRetainedSelection, Error>)?

    private struct Job: Sendable {
        let id: UUID
        let connectionID: UUID
        let intent: IMessageRuntimeSetupIntent
        let command: IMessageGatewayCommand
        let admittedScope: IMessageGatewaySetupScope
        let deadline: Date
        let reply: Reply
    }

    public init(installationID: String, provider: any IMessageSetupProviding,
                referenceDigest: @escaping @Sendable (String) -> String,
                now: @escaping @Sendable () -> Date = Date.init,
                makeID: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.installationID = installationID; self.provider = provider
        self.referenceDigest = referenceDigest; self.now = now; self.makeID = makeID
    }

    /// Network replacement fences transport work without creating a semantic revocation.
    public func bind(connectionID: UUID) {
        guard !retired, self.connectionID != connectionID else { return }
        cancelWork(code: .scopeDenied)
        self.connectionID = connectionID
        snapshot = nil
        inventory.connectionReplaced()
    }

    public func unbind(connectionID: UUID) {
        guard self.connectionID == connectionID else { return }
        self.connectionID = nil
        snapshot = nil
        inventory.connectionReplaced()
        cancelWork(code: .scopeDenied)
    }

    public func activateLocalSetup(_ receipt: IMessageRuntimeSetupIntent) throws {
        guard !retired else { throw IMessageSetupProviderError.accountChanged }
        try IMessageGatewayWire.validate(IMessageGatewaySnapshot(installationID: installationID, revision: 1, setupScope: receipt.scope))
        let expiry = try IMessageGatewayWire.utcDate(receipt.scope.expiresAt)
        guard receipt.scope.enabled, expiry > now(), expiry.timeIntervalSince(now()) <= 86400 else {
            throw IMessageSetupProviderError.accountChanged
        }
        guard intent != receipt else { return }
        restrictCurrentAuthority()
        // Revision/cutoff memory belongs to this exact local intent. A fresh
        // coordinator receipt still requires a matching current API snapshot.
        highestRevision = 0
        restrictiveCutoff = 0
        intent = receipt
        metadataConsent = false
        snapshot = nil
        inventory = IMessageRuntimeInventory()
    }

    public func setMetadataConsent(_ granted: Bool, for receipt: IMessageRuntimeSetupIntent) throws {
        guard intent == receipt, try intentIsLive(receipt) else { throw IMessageSetupProviderError.accountChanged }
        metadataConsent = granted
        if !granted { restrictCurrentAuthority(); inventory = IMessageRuntimeInventory() }
    }

    public func withdrawLocalSetup(_ receipt: IMessageRuntimeSetupIntent) {
        guard intent == receipt else { return }
        restrictCurrentAuthority()
        intent = nil; metadataConsent = false; snapshot = nil
        inventory = IMessageRuntimeInventory()
    }

    /// Local bookkeeping only. The native picker awaits this ACK before paging away.
    public func setSelectedConversationIDs(_ ids: [String], for receipt: IMessageRuntimeSetupIntent) throws {
        guard intent == receipt, metadataConsent, try intentIsLive(receipt) else { throw IMessageSetupProviderError.accountChanged }
        try inventory.select(ids, now: now())
    }

    public func selectedConversationIDs(for receipt: IMessageRuntimeSetupIntent) -> [String] {
        guard intent == receipt else { return [] }
        return inventory.selected.map(\.conversationID)
    }

    /// Native-only. Page and gateway DTOs never expose retained account evidence.
    public func retainedSelection(for receipt: IMessageRuntimeSetupIntent) throws -> IMessageRuntimeRetainedSelection {
        guard !retired, intent == receipt, metadataConsent, try intentIsLive(receipt) else {
            throw IMessageSetupProviderError.accountChanged
        }
        let value = try inventory.retained(now: now())
        return .init(intent: receipt, conversations: value.rows, account: value.account,
                     expiresAt: min(value.expiresAt, try IMessageGatewayWire.utcDate(receipt.scope.expiresAt)))
    }

    public func restoreSelection(_ selections: [IMessageSetupDraft.Selection], account: IMessageSetupAccount,
                                 originalExpiresAt: Date, for receipt: IMessageRuntimeSetupIntent) async throws -> IMessageRuntimeRetainedSelection {
        guard restoration == nil else { throw IMessageSetupProviderError.busy }
        let id = UUID()
        let task = Task {
            do { return try await self.performRestoration(selections, account: account, originalExpiresAt: originalExpiresAt, for: receipt) }
            catch {
                if self.intent == receipt,
                   (error as? IMessageSetupProviderError) == .accountChanged || (error as? IMessageRuntimeInventoryError)?.code == .accountChanged {
                    self.restrictCurrentAuthority(); self.metadataConsent = false
                }
                if Task.isCancelled { await self.provider.stop() }
                throw error
            }
        }
        restoration = (id, task)
        defer { if restoration?.id == id { restoration = nil } }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func performRestoration(_ selections: [IMessageSetupDraft.Selection], account: IMessageSetupAccount,
                                    originalExpiresAt: Date, for receipt: IMessageRuntimeSetupIntent) async throws -> IMessageRuntimeRetainedSelection {
        guard !retired, intent == receipt, metadataConsent, try intentIsLive(receipt), active == nil,
              !selections.isEmpty, selections.count <= 32,
              Set(selections.map(\.nativeChatRowID)).count == selections.count,
              Set(selections.map(\.expectedGUID)).count == selections.count else {
            throw IMessageSetupProviderError.accountChanged
        }
        let expiry = min(originalExpiresAt, try IMessageGatewayWire.utcDate(receipt.scope.expiresAt),
                         now().addingTimeInterval(Self.inventoryLifetime))
        guard expiry > now() else { throw IMessageSetupProviderError.accountChanged }
        await cleanup?.value
        try Task.checkCancellation()
        guard !retired, intent == receipt, metadataConsent else { throw IMessageSetupProviderError.accountChanged }
        let response = try await provider.restore(selections: selections, account: account,
            deadline: min(expiry, now().addingTimeInterval(Self.commandLifetime)))
        try Task.checkCancellation()
        guard !retired, intent == receipt, metadataConsent, expiry > now(), active == nil else {
            throw IMessageSetupProviderError.accountChanged
        }
        try inventory.restore(response, selections: selections, account: account, expiresAt: expiry, makeID: makeID)
        return try retainedSelection(for: receipt)
    }

    public func unbindAndDrain(connectionID: UUID) async {
        guard self.connectionID == connectionID else { return }
        unbind(connectionID: connectionID)
        await joinCleanup()
    }

    public func withdrawLocalSetupAndDrain(_ receipt: IMessageRuntimeSetupIntent) async {
        guard intent == receipt else { return }
        withdrawLocalSetup(receipt)
        await joinCleanup()
    }

    public func suspendAndDrain() async {
        intent = nil; metadataConsent = false; snapshot = nil
        inventory = IMessageRuntimeInventory()
        cancelWork(code: .scopeDenied)
        await joinCleanup()
    }

    /// Permanently retires this installation session. A fresh session is denied.
    public func drain() async {
        retired = true
        connectionID = nil; intent = nil; metadataConsent = false; snapshot = nil
        inventory = IMessageRuntimeInventory()
        cancelWork(code: .scopeDenied)
        await joinCleanup()
    }

    private func joinCleanup() async {
        let work = active?.task, local = restoration?.task, pending = cleanup
        await pending?.value
        await work?.value
        _ = await local?.result
        await cleanup?.value
    }

    /// The ordered socket reader awaits this short operation. It starts no provider work.
    public func install(_ value: IMessageGatewaySnapshot, connectionID: UUID) -> IMessageGatewayPayload {
        do {
            try IMessageGatewayWire.validate(value)
            guard self.connectionID == connectionID, value.installationID == installationID else { return failure(.scopeDenied) }
            let old = snapshot?.setupScope
            if value.revision < highestRevision, !sameAuthority(old ?? intent?.scope, value.setupScope) { return failure(.scopeDenied) }
            highestRevision = max(highestRevision, value.revision)
            guard let receipt = intent, try intentIsLive(receipt),
                  let scope = value.setupScope, sameAuthority(receipt.scope, scope) else {
                restrictCurrentAuthority(); snapshot = nil
                return failure(.scopeDenied)
            }
            if !scope.enabled {
                restrictCurrentAuthority(); snapshot = value
                return .snapshotAck(.init(revision: value.revision))
            }
            guard value.revision > restrictiveCutoff else { return failure(.scopeDenied) }
            if let old, !sameAuthority(old, scope) { restrictCurrentAuthority() }
            snapshot = value
            return .snapshotAck(.init(revision: value.revision))
        } catch { return failure(.scopeDenied) }
    }

    /// Validation and FIFO admission are ordered with snapshot installation.
    /// The callback owns one existing socket request slot until its reply finishes.
    public func admit(_ command: IMessageGatewayCommand, connectionID: UUID, reply: @escaping Reply) -> IMessageGatewayFailure? {
        do {
            try IMessageGatewayWire.validate(command)
            guard self.connectionID == connectionID, let receipt = intent, try intentIsLive(receipt),
                  let snapshot, let scope = snapshot.setupScope, scope.enabled,
                  snapshot.revision == command.target.snapshotRevision, snapshot.revision > restrictiveCutoff else {
                return safeFailure(.scopeDenied)
            }
            try IMessageGatewayWire.validate(command: command, against: snapshot,
                setupReferenceSHA256: referenceDigest(command.caller.setupSession.setupReference))
            guard command.operation == .prerequisites || metadataConsent else { return safeFailure(.scopeDenied) }
            guard restoration == nil else { return safeFailure(.busy) }
            guard active?.job.command.requestID != command.requestID,
                  !waiting.contains(where: { $0.command.requestID == command.requestID }) else { return safeFailure(.busy) }
            guard active == nil || waiting.count < Self.maximumWaitingCommands else { return safeFailure(.busy) }
            let deadline = min(try IMessageGatewayWire.utcDate(command.deadlineAt),
                now().addingTimeInterval(Self.commandLifetime), try IMessageGatewayWire.utcDate(scope.expiresAt))
            guard deadline > now() else { return safeFailure(.providerTimeout) }
            let job = Job(id: UUID(), connectionID: connectionID, intent: receipt, command: command,
                          admittedScope: scope, deadline: deadline, reply: reply)
            if active == nil { start(job) } else { waiting.append(job) }
            return nil
        } catch { return safeFailure(.scopeDenied) }
    }

    private func intentIsLive(_ value: IMessageRuntimeSetupIntent) throws -> Bool {
        guard value.scope.enabled else { return false }
        return try IMessageGatewayWire.utcDate(value.scope.expiresAt) > now()
    }

    private func sameAuthority(_ lhs: IMessageGatewaySetupScope?, _ rhs: IMessageGatewaySetupScope?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return lhs.setupReferenceSHA256 == rhs.setupReferenceSHA256 && lhs.generation == rhs.generation
            && lhs.workspaceID == rhs.workspaceID && lhs.userID == rhs.userID
            && (try? IMessageGatewayWire.timestampsEqual(lhs.expiresAt, rhs.expiresAt)) == true
    }

    private func permitted(_ job: Job) -> Bool {
        guard connectionID == job.connectionID, intent == job.intent, snapshot?.setupScope?.enabled == true,
              sameAuthority(snapshot?.setupScope, job.admittedScope), job.command.target.snapshotRevision > restrictiveCutoff,
              job.deadline > now(), (try? intentIsLive(job.intent)) == true else { return false }
        return job.command.operation == .prerequisites || metadataConsent
    }

    private func restrictCurrentAuthority() {
        restrictiveCutoff = max(restrictiveCutoff, highestRevision)
        cancelWork(code: .scopeDenied)
        inventory = IMessageRuntimeInventory()
    }

    private func cancelWork(code: IMessageGatewayFailureCode) {
        let rejected = waiting
        waiting.removeAll()
        for job in rejected { Task { await job.reply(self.failure(code)) } }
        active?.task.cancel()
        restoration?.task.cancel()
        scheduleCleanup()
    }

    private func scheduleCleanup() {
        let previous = cleanup
        let provider = provider
        cleanup = Task { await previous?.value; await provider.stop() }
    }

    private func start(_ job: Job) {
        let task = Task { await run(job) }
        let delay = max(0, job.deadline.timeIntervalSince(now()))
        let timer = Task {
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            expire(jobID: job.id)
        }
        active = (job, task, timer)
    }

    private func expire(jobID: UUID) {
        guard active?.job.id == jobID else { return }
        active?.task.cancel()
        scheduleCleanup()
    }

    /// Also permits deterministic fake-clock expiry without a wall-clock wait.
    public func reconcileDeadlines() {
        let expired = waiting.filter { $0.deadline <= now() }
        waiting.removeAll { $0.deadline <= now() }
        for job in expired { Task { await job.reply(self.failure(.providerTimeout)) } }
        if let job = active?.job, job.deadline <= now() { expire(jobID: job.id) }
    }

    private func run(_ job: Job) async {
        var result: IMessageGatewayPayload
        do {
            await cleanup?.value
            try Task.checkCancellation()
            guard permitted(job) else { throw RuntimeDenied.scope }
            let value = try await execute(job)
            try Task.checkCancellation()
            guard permitted(job) else { throw RuntimeDenied.scope }
            let frame = DesktopControlFrame(type: "imessage", requestID: job.command.requestID, imessage: .result(value))
            try IMessageGatewayWire.validateResult(frame, for: job.command)
            result = .result(value)
        } catch {
            if Task.isCancelled { await provider.stop() }
            let typedCode = (error as? IMessageSetupProviderError)?.code
                ?? (error as? IMessageRuntimeInventoryError)?.code
            if typedCode == .accountChanged {
                restrictCurrentAuthority()
                metadataConsent = false
            }
            if job.deadline <= now() { result = failure(.providerTimeout) }
            else if typedCode == .accountChanged { result = failure(.accountChanged) }
            else if !permitted(job) { result = failure(.scopeDenied) }
            else { result = failure(typedCode ?? .dependencyInvalid) }
        }
        guard active?.job.id == job.id else { return }
        active?.timer.cancel()
        if connectionID == job.connectionID { await job.reply(result) }
        guard active?.job.id == job.id else { return }
        active = nil
        if !waiting.isEmpty { start(waiting.removeFirst()) }
    }

    private func execute(_ job: Job) async throws -> IMessageGatewaySetupResult {
        switch job.command.input {
        case .prerequisites:
            return .prerequisites(try await provider.prerequisites(deadline: job.deadline))
        case .setupConversations(let input):
            let request = try inventory.request(input, now: now())
            if let cached = request.cached { return .conversationsPage(cached) }
            let response = try await provider.conversations(after: request.after, upper: request.upper,
                query: input.query, limit: input.limit, deadline: job.deadline)
            try Task.checkCancellation()
            guard permitted(job) else { throw RuntimeDenied.scope }
            return .conversationsPage(try inventory.accept(response, input: input, request: request, now: now(), makeID: makeID))
        case .verifyConversations(let input):
            let selection = try inventory.verification(input.conversationIDs, now: now())
            let response = try await provider.verify(conversations: selection.rows.map(\.metadata),
                account: selection.account, deadline: job.deadline)
            try Task.checkCancellation()
            guard permitted(job) else { throw RuntimeDenied.scope }
            try validateVerification(response, selected: selection.rows, account: selection.account)
            let rows = zip(selection.rows, response.conversations).map {
                IMessageGatewaySetupConversation(conversationID: $0.0.conversationID, metadata: $0.1)
            }
            return .verification(.init(conversations: rows, liveAccount: response.liveAccount))
        }
    }

    private func validateVerification(_ response: IMessageSetupProviderVerification,
                                      selected: [IMessageGatewaySetupConversation], account: IMessageSetupAccount) throws {
        guard response.conversations.map(\.id) == selected.map({ $0.metadata.id }) else {
            throw IMessageSetupProviderError.dependencyInvalid
        }
        for (expected, current) in zip(selected, response.conversations) {
            guard !current.available || current.guid == expected.metadata.guid else { throw IMessageSetupProviderError.accountChanged }
        }
        if let proof = response.liveAccount {
            guard proof.accountID == account.accountID, proof.sourceGeneration == account.sourceGeneration else {
                throw IMessageSetupProviderError.accountChanged
            }
        }
    }

    private enum RuntimeDenied: Error { case scope }
    private func failure(_ code: IMessageGatewayFailureCode) -> IMessageGatewayPayload { .failure(safeFailure(code)) }
    private func safeFailure(_ code: IMessageGatewayFailureCode) -> IMessageGatewayFailure {
        let message: String
        switch code {
        case .scopeDenied: message = "This Messages setup is no longer authorized. Review it on this Mac."
        case .busy: message = "Messages is handling another request. Try again."
        case .providerTimeout: message = "The Messages check timed out. Try again."
        case .permissionRequired: message = "Messages permissions need attention on this Mac."
        case .messagesUnavailable: message = "Open Messages on this Mac and check its connection."
        case .accountChanged: message = "The Messages account or source changed. Review the connection on this Mac."
        case .payloadTooLarge: message = "This conversation metadata is too large."
        case .invalidArguments: message = "The conversation selection expired or changed. Select it again."
        default: message = "The Messages provider is unavailable. Check PersonaStack on this Mac."
        }
        return .init(code: code, message: message)
    }
}
