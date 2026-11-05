#if canImport(PersonaStackCore)
import Foundation
import PersonaStackCore

/// The host binds this observation to the provider connection's fixed source identity.
/// `requestAutomation` may be true only following the explicit Verify Messages button.
public struct ProbeLiveAccount: Sendable {
    public let accountID: String?
    public let sourceGeneration: String
    public let liveChatGUID: String
    public init(accountID: String?, sourceGeneration: String, liveChatGUID: String) {
        self.accountID = accountID
        self.sourceGeneration = sourceGeneration
        self.liveChatGUID = liveChatGUID
    }
}

public actor CoreProbeBackend: ProbeBackend {
    private let client: IMessageRPCClient
    private let target: ProbeTarget
    private let liveAccount: @Sendable (Bool) async throws -> ProbeLiveAccount
    private var clientStarted = false
    private var invalidated = false
    private var invalidationTask: Task<Void, Never>?
    private var boundChatGUID: String?
    private var lastCheckpoint: SelectedCheckpoint?

    public init(client: IMessageRPCClient, target: ProbeTarget,
                liveAccount: @escaping @Sendable (Bool) async throws -> ProbeLiveAccount) {
        self.client = client
        self.target = target
        self.liveAccount = liveAccount
    }

    public func readiness(requestAutomation: Bool) async throws -> ProbeReadiness {
        let account = try await checkedAccount(requestAutomation)
        let status = try await providerStatus()
        // A first checkpoint establishes only a baseline. It does not verify continuity.
        _ = try await checkpoint(try IMessageRowID(decimal: target.conversationID))
        return ProbeReadiness(
            databaseReady: status.database.ready, liveAccountID: account.accountID,
            sourceGeneration: account.sourceGeneration, adapterRevision: status.adapterRevision
        )
    }

    public func inspect(_ requested: ProbeTarget) async throws -> ProbeReadObservation {
        try requireSelectedTarget(requested)
        let row = try IMessageRowID(decimal: target.conversationID)
        let before = try await checkpoint(row)
        guard before.observedContinuityVerified else { throw ProbeFailure.continuityUnavailable }
        _ = try await checkedAccount(false)
        let recent: IMessageRecentMessages
        do { recent = try await client.recentMessages(chatID: row, limit: 1) }
        catch { await retireTerminalProvider(error); throw error }
        let after = try await checkpoint(row)
        guard after.observedContinuityVerified else { throw ProbeFailure.continuityUnavailable }
        guard recent.messages.allSatisfy({ $0.chatID == row && $0.service == "iMessage" }) else {
            await invalidate()
            throw ProbeFailure.scopeMismatch
        }
        return ProbeReadObservation(
            target: target, service: .imessage, messagesObserved: recent.messages.count,
            continuityVerified: true
        )
    }

    public func send(_ requested: ProbeTarget, text: String) async throws -> ProbeSendObservation {
        let row: IMessageRowID
        let before: SelectedCheckpoint
        do {
            try Task.checkCancellation()
            try requireSelectedTarget(requested)
            row = try IMessageRowID(decimal: target.conversationID)
            before = try await checkpoint(row)
            guard before.observedContinuityVerified else { return .notStarted }
            _ = try await checkedAccount(false)
            try Task.checkCancellation()
        } catch { return .notStarted }
        let receipt: IMessageSendReceipt
        do {
            // The shared client also checks this public account inside its fixed
            // provider script immediately before the external mutation.
            try Task.checkCancellation()
            receipt = try await client.send(chatID: row, text: text, expectedAccountID: target.accountID, expectedChatGUID: before.chatGUID,
                deadline: Date().addingTimeInterval(45), validateCurrent: { try await self.sendContextIsCurrent(requested, chatGUID: before.chatGUID) })
        }
        catch IMessageRPCError.providerRejected(_, let retrySafe) {
            return retrySafe ? .notStarted : .outcomeUnknown
        } catch IMessageRPCError.cancelled {
            await retireTerminalProvider(IMessageRPCError.cancelled)
            return .notStarted
        } catch is CancellationError {
            return .notStarted
        } catch {
            await retireTerminalProvider(error)
            return .outcomeUnknown
        }
        guard receipt.rowID > before.sourceHighWater.value, receipt.chatGUID == before.chatGUID else {
            return .outcomeUnknown
        }
        do {
            // The shared client verifies the new exact local text/GUID receipt.
            // This fixture separately verifies its bounded live-source/anchor chain.
            let after = try await checkpoint(row)
            guard after.observedContinuityVerified else { return .outcomeUnknown }
            return .localRecordConfirmed(messageID: receipt.messageGUID, service: .imessage, target: target)
        } catch {
            return .outcomeUnknown
        }
    }

    public func cancel() async { await invalidate() }

    private func sendContextIsCurrent(_ requested: ProbeTarget, chatGUID: String) async throws -> Bool {
        try requireSelectedTarget(requested)
        let account = try await checkedAccount(false)
        return account.liveChatGUID == chatGUID
    }

    private struct SelectedCheckpoint: Sendable {
        let sourceHighWater: IMessageRowID
        let tailRowID: IMessageRowID
        let tailGUID: String
        let chatGUID: String
        let observedContinuityVerified: Bool
    }

    private func checkpoint(_ row: IMessageRowID) async throws -> SelectedCheckpoint {
        let account = try await checkedAccount(false)
        let previous = lastCheckpoint
        let anchors: [IMessageSourceAnchor]
        if let previous, previous.tailRowID.value > 0, !previous.tailGUID.isEmpty {
            anchors = [.init(chatID: row, rowID: previous.tailRowID, guid: previous.tailGUID)]
        } else {
            anchors = []
        }
        let result: IMessageSourceCheckpoint
        do { result = try await client.sourceCheckpoint(chatIDs: [row], anchors: anchors) }
        catch { await retireTerminalProvider(error); throw error }
        _ = try await checkedAccount(false)
        guard result.chats.count == 1, let chat = result.chats.first,
              chat.chatID == row, chat.available, chat.guid == account.liveChatGUID else {
            await invalidate()
            throw ProbeFailure.scopeMismatch
        }
        guard chat.service == "iMessage" else {
            await invalidate()
            throw ProbeFailure.unsupportedService
        }
        if let previous {
            guard result.sourceHighWater >= previous.sourceHighWater,
                  chat.tailRowID >= previous.tailRowID,
                  anchors.isEmpty || chat.anchorMatches == true else {
                await invalidate()
                throw ProbeFailure.continuityUnavailable
            }
        }
        let next = SelectedCheckpoint(
            sourceHighWater: result.sourceHighWater, tailRowID: chat.tailRowID,
            tailGUID: chat.tailGUID, chatGUID: chat.guid,
            observedContinuityVerified: previous != nil && !anchors.isEmpty && chat.anchorMatches == true
        )
        lastCheckpoint = next
        return next
    }

    private func checkedAccount(_ requestAutomation: Bool) async throws -> ProbeLiveAccount {
        try Task.checkCancellation()
        guard !invalidated else { throw ProbeFailure.identityChanged }
        let account: ProbeLiveAccount
        do { account = try await liveAccount(requestAutomation) }
        catch {
            await invalidate()
            throw ProbeFailure.identityChanged
        }
        try Task.checkCancellation()
        guard !invalidated else { throw ProbeFailure.identityChanged }
        guard account.accountID == target.accountID, account.sourceGeneration == target.sourceGeneration,
              !account.liveChatGUID.isEmpty, account.liveChatGUID.utf8.count <= 256,
              boundChatGUID.map({ $0 == account.liveChatGUID }) ?? true,
              lastCheckpoint.map({ $0.chatGUID == account.liveChatGUID }) ?? true else {
            await invalidate()
            throw ProbeFailure.identityChanged
        }
        if boundChatGUID == nil { boundChatGUID = account.liveChatGUID }
        return account
    }

    private func requireSelectedTarget(_ requested: ProbeTarget) throws {
        guard requested.conversationID == target.conversationID,
              requested.accountID == target.accountID,
              requested.sourceGeneration == target.sourceGeneration else { throw ProbeFailure.scopeMismatch }
    }

    private func providerStatus() async throws -> IMessageRPCStatus {
        do {
            if clientStarted { return try await client.status() }
            let status: IMessageRPCStatus
            do { status = try await client.start() }
            catch IMessageRPCError.alreadyStarted { status = try await client.status() }
            clientStarted = true
            return status
        } catch {
            await retireTerminalProvider(error)
            throw error
        }
    }

    private func retireTerminalProvider(_ error: Error) async {
        guard let failure = error as? IMessageRPCError else { return }
        switch failure {
        case .alreadyStarted, .busy, .invalidArguments, .providerRejected: return
        case .notStarted, .invalidResponse, .frameTooLarge, .dependencyInvalid, .restartLimitReached,
             .processExited, .deadlineExceeded, .cancelled, .outcomeUnknown: break
        }
        // No retry occurs here. A later explicit prerequisite check may start
        // one fresh provider only after this cleanup has joined. Retain the
        // live GUID and checkpoint so restart cannot erase continuity fences.
        // stop never resets the client's shared app-lifetime restart budget.
        clientStarted = false
        await client.stop()
    }

    private func invalidate() async {
        if let invalidationTask { await invalidationTask.value; return }
        invalidated = true
        clientStarted = false
        let cleanup = Task { [client] in await client.stop() }
        invalidationTask = cleanup
        await cleanup.value
    }
}
#endif
