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

/// One canonical provider owner. Configured execution requires separate current API and native authority.
public protocol IMessageSetupProviding: Sendable {
    func prerequisites(deadline: Date) async throws -> IMessageGatewayPrerequisitesResult
    func conversations(after: IMessageRowID, upper: IMessageRowID?, query: String, limit: Int,
                       deadline: Date) async throws -> IMessageSetupProviderPage
    func verify(conversations: [IMessageConversation], account: IMessageSetupAccount,
                deadline: Date) async throws -> IMessageSetupProviderVerification
    func restore(selections: [IMessageSetupDraft.Selection], account: IMessageSetupAccount,
                 deadline: Date) async throws -> IMessageSetupProviderVerification
    func executeConfigured(_ input: IMessageGatewayConfiguredInput, scope: IMessageGatewayConfigScope, deadline: Date,
                           validateCurrent: @escaping @Sendable () async throws -> Bool) async throws -> IMessageGatewayConfiguredResult
    func stop() async
}

public struct IMessageRuntimeRetainedSelection: Sendable {
    public let intent: IMessageRuntimeSetupIntent
    public let conversations: [IMessageGatewaySetupConversation]
    public let account: IMessageSetupAccount
    public let expiresAt: Date
    public let expectedSelections: [IMessageSetupDraft.Selection]
}

public struct IMessageRuntimeRestorationIntentions: Sendable {
    public let selections: [IMessageSetupDraft.Selection]
    public let account: IMessageSetupAccount
    public let conversationIDs: [String]
}

public extension IMessageSetupProviding {
    func executeConfigured(_ input: IMessageGatewayConfiguredInput, scope: IMessageGatewayConfigScope, deadline: Date,
                           validateCurrent: @escaping @Sendable () async throws -> Bool) async throws -> IMessageGatewayConfiguredResult {
        throw IMessageConfiguredAuthorizationError.denied(.capabilityDisabled)
    }
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

public enum IMessageConfiguredAuthorizationError: Error, Equatable, Sendable {
    case denied(IMessageGatewayFailureCode), unavailable
    var code: IMessageGatewayFailureCode {
        switch self { case .denied(let value): value; case .unavailable: .dependencyInvalid }
    }
}

public actor IMessageRuntime {
    public func diagnostics() -> IMessageRuntimeDiagnostics {
        .init(waitingCommands: waiting.count, activeCommand: active != nil, cleanupPending: cleanupID != nil, restorationPending: restoration != nil)
    }
    public static let maximumWaitingCommands = 8
    public static let commandLifetime: TimeInterval = 10
    public static let inventoryLifetime: TimeInterval = 300
    public static let sendLifetime: TimeInterval = 45
    public typealias ConfiguredAuthorization = @Sendable (IMessageGatewayCommand, UUID, Date) async throws -> IMessageGatewaySnapshot
    public typealias Reply = @Sendable (IMessageGatewayPayload) async -> Void
    private let installationID: String
    private let provider: any IMessageSetupProviding
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> String
    private let referenceDigest: @Sendable (String) -> String
    private let textDigest: @Sendable (String) -> String
    private let authorizeConfigured: ConfiguredAuthorization
    private let applicationAdmission: @Sendable () async -> Bool
    private var configuredEnabled = false
    private var executionAvailable = true
    private var interactiveReads = 0
    private var humanIntents: [String: (command: IMessageGatewayCommand, generation: UUID, deadline: Date)] = [:]
    private var connectionID: UUID?
    private var intent: IMessageRuntimeSetupIntent?
    private var metadataConsent = false
    private var retired = false
    private var snapshot: IMessageGatewaySnapshot?
    // The installation currently permits one configured identity. Grant revisions are not config epochs.
    private var configuredScope: IMessageGatewayConfigScope?
    private var highestSetupRevision: Int64 = 0
    private var restrictiveCutoff: Int64 = 0
    private var waiting: [Job] = []
    private var active: (job: Job, task: Task<Void, Never>, timer: Task<Void, Never>, replying: Bool)?
    private var inventory = IMessageRuntimeInventory()
    private var cleanup: Task<Void, Never>?
    private var cleanupID: UUID?
    private var restoration: (id: UUID, task: Task<IMessageRuntimeRetainedSelection, Error>)?

    private struct Job: Sendable {
        let id: UUID
        let connectionID: UUID
        let authority: Authority
        let command: IMessageGatewayCommand
        let admittedSnapshot: IMessageGatewaySnapshot
        let deadline: Date
        let reply: Reply
    }

    private enum Authority: Sendable {
        case setup(IMessageRuntimeSetupIntent, IMessageGatewaySetupScope)
        case configured(IMessageGatewayConfigScope)
    }

    public init(installationID: String, provider: any IMessageSetupProviding,
                referenceDigest: @escaping @Sendable (String) -> String,
                textDigest: @escaping @Sendable (String) -> String = { _ in "" },
                authorizeConfigured: @escaping ConfiguredAuthorization = { _, _, _ in throw IMessageConfiguredAuthorizationError.denied(.scopeDenied) },
                applicationAdmission: @escaping @Sendable () async -> Bool = { true },
                now: @escaping @Sendable () -> Date = Date.init,
                makeID: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.installationID = installationID; self.provider = provider
        self.referenceDigest = referenceDigest; self.textDigest = textDigest; self.authorizeConfigured = authorizeConfigured
        self.applicationAdmission = applicationAdmission
        self.now = now; self.makeID = makeID
    }

    public func setConfiguredPolicy(enabled: Bool) {
        configuredEnabled = enabled
        if !enabled { humanIntents.removeAll(); cancelInvalidJobs() }
    }
    public func setExecutionAvailable(_ available: Bool) {
        executionAvailable = available
        if !available { humanIntents.removeAll(); cancelWork(code: .scopeDenied) }
    }
    /// Trusted native confirmation only. No page handler may call this from raw JS scope.
    public func registerHumanAction(_ command: IMessageGatewayCommand, localGeneration: UUID, confirmed: Bool, deadline: Date) async throws {
        guard await applicationAdmission() else { throw IMessageSetupProviderError.accountChanged }
        try IMessageGatewayWire.validate(command)
        guard confirmed, command.caller.kind == .humanAction, configuredEnabled, executionAvailable, !retired,
              command.target.installationID == installationID, deadline > now(),
              deadline <= (try IMessageGatewayWire.utcDate(command.deadlineAt)) else { throw IMessageSetupProviderError.accountChanged }
        if let human = command.caller.humanAction, case .configured(.sendMessage(let input)) = command.input {
            guard human.textSHA256 == textDigest(input.text) else { throw IMessageSetupProviderError.accountChanged }
        }
        humanIntents = humanIntents.filter { $0.value.deadline > now() }
        guard humanIntents.count < Self.maximumWaitingCommands || humanIntents[command.authorizationID] != nil else { throw IMessageSetupProviderError.busy }
        humanIntents[command.authorizationID] = (command, localGeneration, deadline)
    }
    public func withdrawHumanActions(localGeneration: UUID) {
        let previous = humanIntents.count
        humanIntents = humanIntents.filter { $0.value.generation != localGeneration }
        guard humanIntents.count != previous else { return }
        cancelInvalidJobs()
    }

    /// Network replacement fences transport work without creating a semantic revocation.
    public func bind(connectionID: UUID) {
        guard !retired, self.connectionID != connectionID else { return }
        cancelWork(code: .scopeDenied)
        self.connectionID = connectionID
        snapshot = nil
        configuredScope = nil
        humanIntents.removeAll()
        inventory.connectionReplaced()
    }

    public func unbind(connectionID: UUID) {
        guard self.connectionID == connectionID else { return }
        self.connectionID = nil
        snapshot = nil
        configuredScope = nil
        humanIntents.removeAll()
        inventory.connectionReplaced()
        cancelWork(code: .scopeDenied)
    }

    public func activateLocalSetup(_ receipt: IMessageRuntimeSetupIntent) async throws {
        guard await applicationAdmission(), !retired else { throw IMessageSetupProviderError.accountChanged }
        try IMessageGatewayWire.validate(IMessageGatewaySnapshot(installationID: installationID, revision: 1, setupScope: receipt.scope))
        let expiry = try IMessageGatewayWire.utcDate(receipt.scope.expiresAt)
        guard receipt.scope.enabled, expiry > now(), expiry.timeIntervalSince(now()) <= 86400 else {
            throw IMessageSetupProviderError.accountChanged
        }
        guard intent != receipt else { return }
        restrictCurrentAuthority()
        // Setup replay memory belongs only to this exact trusted local intent.
        // A rejected earlier journey cannot deny this receipt's prerequisite check.
        highestSetupRevision = 0
        restrictiveCutoff = 0
        intent = receipt
        metadataConsent = false
        removeSetupSnapshot()
        inventory = IMessageRuntimeInventory()
    }

    public func setMetadataConsent(_ granted: Bool, for receipt: IMessageRuntimeSetupIntent) async throws {
        guard await applicationAdmission(), intent == receipt, try intentIsLive(receipt) else { throw IMessageSetupProviderError.accountChanged }
        metadataConsent = granted
        if !granted { restrictCurrentAuthority(); inventory = IMessageRuntimeInventory() }
    }

    public func withdrawLocalSetup(_ receipt: IMessageRuntimeSetupIntent) {
        guard intent == receipt else { return }
        restrictCurrentAuthority()
        intent = nil; metadataConsent = false
        removeSetupSnapshot()
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
                     expiresAt: min(value.expiresAt, try IMessageGatewayWire.utcDate(receipt.scope.expiresAt)), expectedSelections: value.expectedSelections)
    }

    /// Native edit intentions only. This neither installs an execution grant nor
    /// restores consent, option tokens, expiry or cached metadata.
    public func restorationIntentions(for receipt: IMessageRuntimeSetupIntent, configID: String,
                                      expectedConfigVersion: Int64) throws -> IMessageRuntimeRestorationIntentions {
        guard !retired, intent == receipt, metadataConsent, try intentIsLive(receipt),
              let snapshot, sameAuthority(receipt.scope, snapshot.setupScope),
              snapshot.configs.count == 1, let config = snapshot.configs.first,
              config.configID == configID, config.configVersion == expectedConfigVersion,
              config.workspaceID == receipt.scope.workspaceID else { throw IMessageSetupProviderError.accountChanged }
        let selections = try config.conversationBindings.map {
            try IMessageSetupDraft.Selection(nativeChatRowID: $0.nativeChatID.rawValue, expectedGUID: $0.nativeChatGUID)
        }
        return .init(selections: selections, account: .init(accountID: config.accountID, sourceGeneration: config.sourceGeneration), conversationIDs: config.conversationIDs)
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
        configuredScope = nil
        humanIntents.removeAll()
        inventory = IMessageRuntimeInventory()
        cancelWork(code: .scopeDenied)
        await joinCleanup()
    }

    /// Permanently retires this installation session. A fresh session is denied.
    public func drain() async {
        retired = true
        connectionID = nil; intent = nil; metadataConsent = false; snapshot = nil
        configuredScope = nil
        humanIntents.removeAll()
        inventory = IMessageRuntimeInventory()
        cancelWork(code: .scopeDenied)
        await joinCleanup()
    }

    private func joinCleanup() async {
        // Reply callbacks can reenter drain after provider execution has ended.
        // Keep their admission slot, but never join the callback that owns this drain.
        let work = active?.replying == false ? active?.task : nil
        let local = restoration?.task, pending = cleanup
        await pending?.value
        await work?.value
        _ = await local?.result
        await cleanup?.value
    }

    /// The ordered socket reader awaits this short operation. It starts no provider work.
    public func install(_ value: IMessageGatewaySnapshot, connectionID: UUID) async -> IMessageGatewayPayload {
        do {
            try IMessageGatewayWire.validate(value)
            guard await applicationAdmission(), !retired, self.connectionID == connectionID, value.installationID == installationID else { return failure(.scopeDenied) }
            guard value.configs.count <= 1 else { return failure(.scopeDenied) }
            let incoming = value.configs.first
            if value.revision < highestSetupRevision, let setup = value.setupScope, let previous = snapshot?.setupScope,
               !sameAuthority(previous, setup) { return failure(.scopeDenied) }
            if let old = configuredScope, let incoming, incoming.configID == old.configID,
               incoming.configVersion < old.configVersion { return failure(.scopeDenied) }
            if let incoming { configuredScope = incoming }
            else if value.setupScope == nil {
                configuredScope = nil
                restrictCurrentAuthority()
            }
            if value.setupScope != nil || value.configs.isEmpty {
                highestSetupRevision = max(highestSetupRevision, value.revision)
            }
            let setupMatches = intent.map { receipt in
                (try? intentIsLive(receipt)) == true && sameAuthority(receipt.scope, value.setupScope)
            } ?? false
            if !setupMatches && value.configs.isEmpty && value.setupScope != nil {
                restrictCurrentAuthority(); removeSetupSnapshot()
                return failure(.scopeDenied)
            }
            if setupMatches, value.setupScope?.enabled == false { restrictCurrentAuthority() }
            if setupMatches, value.setupScope?.enabled == true, value.revision <= restrictiveCutoff { return failure(.scopeDenied) }
            snapshot = value
            cancelInvalidJobs()
            return .snapshotAck(.init(revision: value.revision))
        } catch { return failure(.scopeDenied) }
    }

    public func admit(_ command: IMessageGatewayCommand, connectionID: UUID, reply: @escaping Reply) async -> IMessageGatewayFailure? {
        do {
            try IMessageGatewayWire.validate(command)
            guard await applicationAdmission(), !retired, executionAvailable, self.connectionID == connectionID, let snapshot,
                  snapshot.revision == command.target.snapshotRevision else { return safeFailure(.scopeDenied, command: command) }
            let authority = try admissionAuthority(command, snapshot: snapshot)
            if command.operation == .sendMessage, let attempt = command.sendAttemptID,
               active?.job.command.sendAttemptID == attempt || waiting.contains(where: { $0.command.sendAttemptID == attempt }) {
                return safeFailure(.requestInProgress, command: command, possibleDispatch: true)
            }
            guard restoration == nil, active?.job.command.requestID != command.requestID,
                  !waiting.contains(where: { $0.command.requestID == command.requestID }) else { return safeFailure(.busy, command: command) }
            guard active == nil || waiting.count < Self.maximumWaitingCommands else { return safeFailure(.busy, command: command) }
            let budget = command.operation == .sendMessage ? Self.sendLifetime : Self.commandLifetime
            var deadline = min(try IMessageGatewayWire.utcDate(command.deadlineAt), now().addingTimeInterval(budget))
            if case .setup(_, let scope) = authority { deadline = min(deadline, try IMessageGatewayWire.utcDate(scope.expiresAt)) }
            if command.caller.kind == .humanAction, let receipt = humanIntents[command.authorizationID] {
                deadline = min(deadline, receipt.deadline)
            }
            guard deadline > now() else { return safeFailure(.providerTimeout, command: command) }
            let job = Job(id: UUID(), connectionID: connectionID, authority: authority, command: command,
                          admittedSnapshot: snapshot, deadline: deadline, reply: reply)
            if active == nil { start(job) } else { waiting.append(job) }
            return nil
        } catch { return safeFailure(.scopeDenied, command: command) }
    }

    private func admissionAuthority(_ command: IMessageGatewayCommand, snapshot: IMessageGatewaySnapshot) throws -> Authority {
        if case .configured = command.input {
            guard configuredEnabled, humanPermitted(command), let scope = snapshot.configs.first(where: { $0.configID == command.target.configID }),
                  snapshot.revision > scope.revokedThrough else { throw RuntimeDenied.scope }
            try IMessageGatewayWire.validate(command: command, against: snapshot, humanTextSHA256: humanDigest(command))
            return .configured(scope)
        }
        guard let receipt = intent, try intentIsLive(receipt), let scope = snapshot.setupScope, scope.enabled,
              snapshot.revision > restrictiveCutoff, command.operation == .prerequisites || metadataConsent else { throw RuntimeDenied.scope }
        try IMessageGatewayWire.validate(command: command, against: snapshot,
            setupReferenceSHA256: referenceDigest(command.caller.setupSession?.setupReference ?? ""))
        return .setup(receipt, scope)
    }
    private func humanDigest(_ command: IMessageGatewayCommand) -> String? {
        if case .configured(.sendMessage(let input)) = command.input { return textDigest(input.text) }
        return nil
    }
    private func humanPermitted(_ command: IMessageGatewayCommand) -> Bool {
        guard command.caller.kind == .humanAction else { return true }
        guard let value = humanIntents[command.authorizationID] else { return false }
        return value.command == command && value.deadline > now()
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
        guard !retired, executionAvailable, connectionID == job.connectionID, job.deadline > now() else { return false }
        switch job.authority {
        case .setup(let receipt, let scope):
            return intent == receipt && scope.enabled && sameAuthority(receipt.scope, scope)
                && job.command.target.snapshotRevision > restrictiveCutoff && (try? intentIsLive(receipt)) == true
                && (job.command.operation == .prerequisites || metadataConsent)
        case .configured(let scope):
            return configuredEnabled && configuredScope == scope
                && job.command.target.snapshotRevision > scope.revokedThrough && humanPermitted(job.command)
        }
    }
    private func isCurrent(_ job: Job) async -> Bool {
        guard await applicationAdmission() else { return false }
        return !Task.isCancelled && active?.job.id == job.id && permitted(job)
    }
    private func cancelInvalidJobs() {
        let rejected = waiting.filter { !permitted($0) }
        waiting.removeAll { !permitted($0) }
        for job in rejected { Task { await job.reply(self.failure(.scopeDenied, command: job.command)) } }
        if let active, !permitted(active.job) { active.task.cancel(); scheduleCleanup() }
    }

    private func removeSetupSnapshot() {
        guard let current = snapshot else { return }
        snapshot = IMessageGatewaySnapshot(installationID: current.installationID, revision: current.revision, configs: current.configs)
    }

    private func restrictCurrentAuthority() {
        restrictiveCutoff = max(restrictiveCutoff, highestSetupRevision)
        let rejected = waiting.filter { if case .setup = $0.authority { return true }; return false }
        waiting.removeAll { if case .setup = $0.authority { return true }; return false }
        for job in rejected { Task { await job.reply(self.failure(.scopeDenied, command: job.command)) } }
        if let active, case .setup = active.job.authority { active.task.cancel(); scheduleCleanup() }
        restoration?.task.cancel()
        if active == nil { scheduleCleanup() }
        inventory = IMessageRuntimeInventory()
    }

    private func cancelWork(code: IMessageGatewayFailureCode) {
        let rejected = waiting
        waiting.removeAll()
        for job in rejected { Task { await job.reply(self.failure(code, command: job.command)) } }
        active?.task.cancel()
        restoration?.task.cancel()
        scheduleCleanup()
    }

    private func scheduleCleanup() {
        let previous = cleanup
        let provider = provider
        let id = UUID()
        cleanupID = id
        cleanup = Task {
            await previous?.value
            await provider.stop()
            if cleanupID == id { cleanupID = nil }
        }
    }

    private func start(_ job: Job) {
        if isReceive(job) { interactiveReads = 0 }
        else if job.command.operation != .sendMessage { interactiveReads += 1 }
        let task = Task { await run(job) }
        let delay = max(0, job.deadline.timeIntervalSince(now()))
        let timer = Task {
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            expire(jobID: job.id)
        }
        active = (job, task, timer, false)
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
        for job in expired { Task { await job.reply(self.failure(.providerTimeout, command: job.command)) } }
        if let job = active?.job, job.deadline <= now() { expire(jobID: job.id) }
    }

    private enum MutationPhase { case notInvoked, possibleDispatch }
    private func run(_ job: Job) async {
        var result: IMessageGatewayPayload
        var mutationPhase = MutationPhase.notInvoked
        do {
            await cleanup?.value
            try Task.checkCancellation()
            guard await isCurrent(job) else { throw RuntimeDenied.scope }
            if case .configured(let scope) = job.authority {
                let authorized = try await authorizeConfigured(job.command, job.connectionID, job.deadline)
                try Task.checkCancellation()
                guard await isCurrent(job), authorized.configs.first(where: { $0.configID == scope.configID }) == scope else { throw RuntimeDenied.scope }
                try IMessageGatewayWire.validate(command: job.command, against: authorized, humanTextSHA256: humanDigest(job.command))
            }
            try Task.checkCancellation()
            guard await isCurrent(job) else { throw RuntimeDenied.scope }
            if job.command.operation == .sendMessage { mutationPhase = .possibleDispatch }
            let value = try await execute(job)
            try Task.checkCancellation()
            guard await isCurrent(job) else { throw RuntimeDenied.scope }
            let frame = DesktopControlFrame(type: "imessage", requestID: job.command.requestID, imessage: .result(value))
            try IMessageGatewayWire.validateResult(frame, for: job.command, snapshot: job.admittedSnapshot,
                setupReferenceSHA256: referenceDigest(job.command.caller.setupSession?.setupReference ?? ""), humanTextSHA256: humanDigest(job.command))
            result = .result(value)
        } catch {
            if Task.isCancelled { await provider.stop() }
            result = jobFailure(error, job: job, possibleDispatch: mutationPhase == .possibleDispatch)
        }
        guard active?.job.id == job.id else { return }
        active?.timer.cancel()
        active?.replying = true
        if job.command.caller.kind == .humanAction { humanIntents.removeValue(forKey: job.command.authorizationID) }
        if connectionID == job.connectionID { await job.reply(result) }
        guard active?.job.id == job.id else { return }
        active = nil
        startNext()
    }
    private func jobFailure(_ error: Error, job: Job, possibleDispatch: Bool) -> IMessageGatewayPayload {
        let wireCode: IMessageGatewayFailureCode? = (error as? IMessageGatewayWireError) == .resultTooLarge ? .payloadTooLarge : nil
        let admissionCode: IMessageGatewayFailureCode? = error is RuntimeDenied ? .scopeDenied : nil
        let typedCode = (error as? IMessageSetupProviderError)?.code ?? (error as? IMessageRuntimeInventoryError)?.code
            ?? (error as? IMessageConfiguredAuthorizationError)?.code ?? wireCode ?? admissionCode
        if typedCode == .accountChanged {
            if case .setup = job.authority { restrictCurrentAuthority(); metadataConsent = false }
            else if case .configured(let scope) = job.authority, configuredScope == scope { configuredScope = nil; cancelInvalidJobs() }
        }
        let code: IMessageGatewayFailureCode
        if possibleDispatch { code = .outcomeUnknown }
        else if job.deadline <= now() { code = .providerTimeout }
        else if typedCode == .accountChanged { code = .accountChanged }
        else if !permitted(job) { code = .scopeDenied }
        else { code = typedCode ?? .dependencyInvalid }
        return failure(code, command: job.command, possibleDispatch: possibleDispatch)
    }

    private func isReceive(_ job: Job) -> Bool {
        job.command.operation == .receivePage || (job.command.operation == .sourceCheckpoint && job.command.caller.kind == .streamAssignment)
    }
    private func startNext() {
        guard !waiting.isEmpty else { return }
        if interactiveReads >= 3, let index = waiting.firstIndex(where: isReceive) { start(waiting.remove(at: index)) }
        else { start(waiting.removeFirst()) }
    }

    private func execute(_ job: Job) async throws -> IMessageGatewaySetupResult {
        switch job.command.input {
        case .configured(let input):
            guard case .configured(let scope) = job.authority else { throw RuntimeDenied.scope }
            return .configured(try await provider.executeConfigured(input, scope: scope, deadline: job.deadline,
                validateCurrent: { await self.isCurrent(job) }))
        case .prerequisites:
            return .prerequisites(try await provider.prerequisites(deadline: job.deadline))
        case .setupConversations(let input):
            let request = try inventory.request(input, now: now())
            if let cached = request.cached { return .conversationsPage(cached) }
            let response = try await provider.conversations(after: request.after, upper: request.upper,
                query: input.query, limit: input.limit, deadline: job.deadline)
            try Task.checkCancellation()
            guard await isCurrent(job) else { throw RuntimeDenied.scope }
            return .conversationsPage(try inventory.accept(response, input: input, request: request, now: now(), makeID: makeID))
        case .verifyConversations(let input):
            let selection = try inventory.verification(input.conversationIDs, now: now())
            guard selection.rows.allSatisfy({ $0.metadata.available }) else { throw IMessageRuntimeInventoryError.invalidSelection }
            let response = try await provider.verify(conversations: selection.rows.map(\.metadata),
                account: selection.account, deadline: job.deadline)
            try Task.checkCancellation()
            guard await isCurrent(job) else { throw RuntimeDenied.scope }
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
    private func failure(_ code: IMessageGatewayFailureCode, command: IMessageGatewayCommand? = nil, possibleDispatch: Bool = false) -> IMessageGatewayPayload {
        .failure(safeFailure(code, command: command, possibleDispatch: possibleDispatch))
    }
    private func safeFailure(_ code: IMessageGatewayFailureCode, command: IMessageGatewayCommand? = nil, possibleDispatch: Bool = false) -> IMessageGatewayFailure {
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
        case .outcomeUnknown: message = "The send outcome is unknown. Check recent messages before sending again."
        case .requestInProgress: message = "This send is already in progress."
        case .statusUnavailable: message = "This send status is unavailable."
        default: message = "The Messages provider is unavailable. Check PersonaStack on this Mac."
        }
        let key: String?
        if case .configured(.sendMessage(let input))? = command?.input { key = input.clientRequestID } else { key = nil }
        let unresolved = [IMessageGatewayFailureCode.outcomeUnknown, .requestInProgress, .statusUnavailable].contains(code)
        return .init(code: code, message: message, retrySafe: !possibleDispatch && !unresolved, clientRequestID: key)
    }
}
