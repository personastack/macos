import Foundation

/// The host resolves one explicitly approved conversation. Selectors never enter evidence.
public struct ProbeTarget: Sendable, Equatable {
    public let conversationID: String
    public let accountID: String
    public let sourceGeneration: String
    public let displayName: String

    public init(conversationID: String, accountID: String, sourceGeneration: String, displayName: String) {
        self.conversationID = conversationID
        self.accountID = accountID
        self.sourceGeneration = sourceGeneration
        self.displayName = displayName
    }
}

public struct ProbeReadiness: Sendable {
    public let databaseReady: Bool
    public let liveAccountID: String?
    public let sourceGeneration: String
    public let adapterRevision: Int

    public init(databaseReady: Bool, liveAccountID: String?, sourceGeneration: String, adapterRevision: Int) {
        self.databaseReady = databaseReady
        self.liveAccountID = liveAccountID
        self.sourceGeneration = sourceGeneration
        self.adapterRevision = adapterRevision
    }
}

public struct ProbeReadObservation: Sendable {
    public let target: ProbeTarget
    public let service: ProbeService
    public let messagesObserved: Int
    public let continuityVerified: Bool

    public init(target: ProbeTarget, service: ProbeService, messagesObserved: Int, continuityVerified: Bool) {
        self.target = target
        self.service = service
        self.messagesObserved = messagesObserved
        self.continuityVerified = continuityVerified
    }
}

public enum ProbeService: String, Sendable {
    case imessage
    case other
}

public enum ProbeSendObservation: Sendable {
    /// The backend must verify a new outgoing row in the selected chat/account.
    case localRecordConfirmed(messageID: String, service: ProbeService, target: ProbeTarget)
    case notStarted
    case outcomeUnknown
}

/// Implemented by the real host using IMessageRPCClient and its fixed live-account probe.
/// A fake conformance proves policy only. It cannot establish a macOS permission grant.
public protocol ProbeBackend: Sendable {
    func readiness(requestAutomation: Bool) async throws -> ProbeReadiness
    func inspect(_ target: ProbeTarget) async throws -> ProbeReadObservation
    func send(_ target: ProbeTarget, text: String) async throws -> ProbeSendObservation
    /// Cancels pending work and joins cleanup of the owned provider process.
    func cancel() async
}

public enum ProbePhase: String, Codable, Sendable {
    case idle
    case checking
    case readyToRead = "ready_to_read"
    case reading
    case readyToSend = "ready_to_send"
    case sending
    case localRecordConfirmed = "local_record_confirmed"
    case notSent = "not_sent"
    case outcomeUnknown = "outcome_unknown"
    case needsAttention = "needs_attention"
    case cancelled
}

public enum ProbeFailure: String, Error, Codable, Sendable {
    case invalidTarget = "invalid_target"
    case prerequisitesUnavailable = "prerequisites_unavailable"
    case identityChanged = "identity_changed"
    case scopeMismatch = "scope_mismatch"
    case unsupportedService = "unsupported_service"
    case continuityUnavailable = "continuity_unavailable"
    case noMessageObserved = "no_message_observed"
    case actionNotAllowed = "action_not_allowed"
    case providerUnavailable = "provider_unavailable"
}

/// Content-free observations. Signature and physical-state evidence remain external gates.
public struct ProbeEvidence: Codable, Sendable {
    public let schemaVersion: Int
    public let evidenceKind: String
    public let runID: UUID
    public var phase: ProbePhase
    public var failure: ProbeFailure?
    public var adapterRevision: Int?
    public var databaseReady: Bool
    public var liveAccountVerified: Bool
    public var selectedConversationVerified: Bool
    public var retainedMessageObserved: Bool
    public var observedCheckpointContinuityVerified: Bool
    public let continuityScope: String
    public var sendAttempted: Bool
    public var localOutgoingRecordVerified: Bool
    public var updatedAt: Date
    public let requiresExternalSignatureVerification: Bool

    public func redactedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(self)
    }
}

/// One local probe session permits at most one send attempt, including uncertain failures.
public actor ProbeCoordinator {
    public static let expectedAdapterRevision = 2
    public static let testText = "PersonaStack iMessage bridge test. No reply needed."
    /// Presentation and execution are captured from the same approved selection.
    public nonisolated let approvedTargetDisplayName: String

    private let backend: any ProbeBackend
    private let target: ProbeTarget
    private let clock: @Sendable () -> Date
    private var generation = 0
    private var evidence: ProbeEvidence
    private var activeOperation: Task<ProbeEvidence, Never>?
    private var activeOperationID: UUID?
    private var cancellation: Task<Void, Never>?

    private enum Operation: Sendable { case prerequisites, read, send }

    public init(backend: any ProbeBackend, target: ProbeTarget, clock: @escaping @Sendable () -> Date = Date.init) {
        self.backend = backend
        self.target = target
        self.approvedTargetDisplayName = target.displayName
        self.clock = clock
        self.evidence = ProbeEvidence(
            schemaVersion: 2, evidenceKind: "provider_probe_observation", runID: UUID(),
            phase: .idle, databaseReady: false, liveAccountVerified: false,
            selectedConversationVerified: false, retainedMessageObserved: false,
            observedCheckpointContinuityVerified: false, continuityScope: "same_probe_session", sendAttempted: false,
            localOutgoingRecordVerified: false, updatedAt: clock(),
            requiresExternalSignatureVerification: true
        )
    }

    public func snapshot() -> ProbeEvidence { evidence }

    public func checkPrerequisites() async -> ProbeEvidence { await runOwned(.prerequisites) }

    public func readSelectedConversation() async -> ProbeEvidence { await runOwned(.read) }

    public func sendOneConfirmedTestMessage() async -> ProbeEvidence { await runOwned(.send) }

    private func performPrerequisites() async -> ProbeEvidence {
        guard !Task.isCancelled else { return evidence }
        guard evidence.phase == .idle || evidence.phase == .needsAttention else { return evidence }
        guard validTarget else { return fail(.invalidTarget) }
        generation += 1
        let expectedGeneration = generation
        update(.checking)
        do {
            let readiness = try await backend.readiness(requestAutomation: true)
            guard expectedGeneration == generation else { return evidence }
            try validate(readiness)
            evidence.adapterRevision = readiness.adapterRevision
            evidence.databaseReady = true
            evidence.liveAccountVerified = true
            update(.readyToRead)
        } catch let error as ProbeFailure {
            if expectedGeneration == generation { return fail(error) }
        } catch {
            if expectedGeneration == generation { return fail(.providerUnavailable) }
        }
        return evidence
    }

    /// Called only from the explicit Read selected conversation button.
    private func performRead() async -> ProbeEvidence {
        guard !Task.isCancelled else { return evidence }
        guard evidence.phase == .readyToRead else { return evidence }
        let expectedGeneration = generation
        update(.reading)
        do {
            try validate(try await backend.readiness(requestAutomation: false))
            guard expectedGeneration == generation else { return evidence }
            let observed = try await backend.inspect(target)
            guard expectedGeneration == generation else { return evidence }
            guard sameScope(observed.target) else { return fail(.scopeMismatch) }
            guard observed.service == .imessage else { return fail(.unsupportedService) }
            guard observed.continuityVerified else { return fail(.continuityUnavailable) }
            guard observed.messagesObserved > 0 else { return fail(.noMessageObserved) }
            evidence.selectedConversationVerified = true
            evidence.retainedMessageObserved = true
            evidence.observedCheckpointContinuityVerified = true
            update(.readyToSend)
        } catch let error as ProbeFailure {
            if expectedGeneration == generation { return fail(error) }
        } catch {
            if expectedGeneration == generation { return fail(.providerUnavailable) }
        }
        return evidence
    }

    /// The native UI presents the exact target and fixed text before calling this method.
    private func performSend() async -> ProbeEvidence {
        guard !Task.isCancelled else { return evidence }
        guard evidence.phase == .readyToSend, !evidence.sendAttempted else { return evidence }
        let expectedGeneration = generation
        update(.sending)
        do {
            try validate(try await backend.readiness(requestAutomation: false))
            guard expectedGeneration == generation, !Task.isCancelled else { return evidence }
            try Task.checkCancellation()
            evidence.sendAttempted = true
            let result = try await backend.send(target, text: Self.testText)
            // A late result still describes the one attempted effect after Cancel.
            switch result {
            case let .localRecordConfirmed(messageID, service, returnedTarget):
                if !messageID.isEmpty && service == .imessage && sameScope(returnedTarget) {
                    evidence.localOutgoingRecordVerified = true
                    update(.localRecordConfirmed)
                } else {
                    update(.outcomeUnknown)
                }
            case .notStarted:
                update(Task.isCancelled ? .cancelled : .notSent)
            case .outcomeUnknown:
                update(.outcomeUnknown)
            }
        } catch let error as ProbeFailure {
            if evidence.sendAttempted { update(.outcomeUnknown) }
            else if expectedGeneration == generation { return fail(error) }
        } catch {
            if evidence.sendAttempted { update(.outcomeUnknown) }
            else if expectedGeneration == generation { return fail(.providerUnavailable) }
        }
        return evidence
    }

    public func cancel() async -> ProbeEvidence {
        if let cancellation {
            await cancellation.value
            return evidence
        }
        let owned = activeOperation
        let ownedID = activeOperationID
        generation += 1
        owned?.cancel()
        if ![.localRecordConfirmed, .notSent, .outcomeUnknown, .cancelled].contains(evidence.phase) {
            update(evidence.sendAttempted ? .outcomeUnknown : .cancelled)
        }
        let cleanup = Task { [backend] in
            await backend.cancel()
            if let owned { _ = await owned.value }
        }
        cancellation = cleanup
        await cleanup.value
        if activeOperationID == ownedID { activeOperation = nil; activeOperationID = nil }
        cancellation = nil
        return evidence
    }

    private func runOwned(_ operation: Operation) async -> ProbeEvidence {
        guard activeOperation == nil, cancellation == nil, !Task.isCancelled else { return evidence }
        let id = UUID()
        let owned = Task { [self] in
            switch operation {
            case .prerequisites: return await performPrerequisites()
            case .read: return await performRead()
            case .send: return await performSend()
            }
        }
        activeOperation = owned
        activeOperationID = id
        return await withTaskCancellationHandler {
            let result = await owned.value
            if activeOperationID == id { activeOperation = nil; activeOperationID = nil }
            return result
        } onCancel: {
            owned.cancel()
            Task { _ = await self.cancel() }
        }
    }

    private var validTarget: Bool {
        [target.conversationID, target.accountID, target.sourceGeneration, target.displayName]
            .allSatisfy { !$0.isEmpty && $0.utf8.count <= 256 }
    }

    private func sameScope(_ other: ProbeTarget) -> Bool {
        other.conversationID == target.conversationID && other.accountID == target.accountID
            && other.sourceGeneration == target.sourceGeneration
    }

    private func validate(_ readiness: ProbeReadiness) throws {
        guard readiness.databaseReady, readiness.adapterRevision == Self.expectedAdapterRevision else {
            throw ProbeFailure.prerequisitesUnavailable
        }
        guard readiness.liveAccountID == target.accountID,
              readiness.sourceGeneration == target.sourceGeneration else {
            throw ProbeFailure.identityChanged
        }
    }

    private func fail(_ failure: ProbeFailure) -> ProbeEvidence {
        evidence.failure = failure
        if failure == .identityChanged || failure == .continuityUnavailable || failure == .scopeMismatch {
            evidence.observedCheckpointContinuityVerified = false
        }
        update(.needsAttention)
        return evidence
    }

    private func update(_ phase: ProbePhase) {
        evidence.phase = phase
        evidence.updatedAt = clock()
        if phase != .needsAttention { evidence.failure = nil }
    }
}
