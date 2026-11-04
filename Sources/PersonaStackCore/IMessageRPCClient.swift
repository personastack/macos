import Foundation

/// Owns only the bundled provider child. The integration runtime owns scope and scheduling.
public protocol IMessageRPCTransport: Sendable {
    func launch() async throws
    func read(maximumBytes: Int) async throws -> Data
    func write(_ data: Data) async throws
    func terminate() async
}

public actor IMessageRPCClient {
    public static let maximumFrameBytes = 4 * 1024 * 1024
    public static let adapterRevision = 2
    /// The provider has one shared 1-second SQLite budget, 512 physical rows
    /// and 1 MiB output. Transport time is bounded separately without retries.
    public static let chatMetadataTimeoutSeconds: TimeInterval = 2
    public static let maximumChatMetadataResultBytes = 1024 * 1024
    private static let chatMetadataEnvelopeBytes = 256
    private let transport: any IMessageRPCTransport
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    private var started = false
    private var ready = false
    private var stopping = false
    /// Set before launch. Only joined transport cleanup releases this ownership,
    /// including a launch that throws after partially starting its child.
    private var transportNeedsCleanup = false
    private var mutationInFlight = false
    private var mutationDeadline: Date?
    private var receiptDeadline: Date?
    private let readTimeoutSeconds: TimeInterval
    private let sendTimeoutSeconds: TimeInterval
    private var buffer = Data()
    private var reader: Task<Void, Never>?
    private var launchTask: Task<Void, Error>?
    private var cleanupTask: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var pending: Pending?

    private struct Pending {
        let id: String
        let method: IMessageRPCMethod
        let continuation: CheckedContinuation<Data, Error>
        let maximumResponseBytes: Int
        var dispatched = false
    }

    public init(transport: any IMessageRPCTransport) {
        self.transport = transport
        self.readTimeoutSeconds = 10
        self.sendTimeoutSeconds = 45
    }

    internal init(transport: any IMessageRPCTransport, readTimeoutSeconds: TimeInterval, sendTimeoutSeconds: TimeInterval) {
        self.transport = transport
        self.readTimeoutSeconds = readTimeoutSeconds
        self.sendTimeoutSeconds = sendTimeoutSeconds
    }

    deinit {
        reader?.cancel()
        timeout?.cancel()
        let existingCleanup = cleanupTask
        let needsCleanup = transportNeedsCleanup
        guard existingCleanup != nil || needsCleanup else { return }
        let ownedTransport = transport
        let startingChild = launchTask
        Task {
            if let existingCleanup { await existingCleanup.value; return }
            if let startingChild { _ = await startingChild.result }
            await ownedTransport.terminate()
        }
    }

    public func start() async throws -> IMessageRPCStatus {
        guard !started, !stopping, !transportNeedsCleanup else { throw IMessageRPCError.alreadyStarted }
        try Task.checkCancellation()
        generation &+= 1
        let current = generation
        started = true
        transportNeedsCleanup = true
        let launch = Task { [transport] in try await transport.launch() }
        launchTask = launch
        do { try await launch.value }
        catch {
            if generation == current { await stop() }
            throw IMessageRPCError.processExited
        }
        guard generation == current, started else { throw IMessageRPCError.cancelled }
        launchTask = nil
        reader = Task { [weak self, transport] in
            do {
                while !Task.isCancelled {
                    let bytes = try await transport.read(maximumBytes: 8192)
                    guard !bytes.isEmpty else { break }
                    guard await self?.receive(bytes, generation: current) == true else { return }
                }
                await self?.failed(.processExited, generation: current)
            } catch {
                await self?.failed(.processExited, generation: current)
            }
        }
        do {
            let status: IMessageRPCStatus = try await call(.initialize, params: IMessageEmptyParams(),
                timeoutSeconds: readTimeoutSeconds, keys: ["protocol_version", "personastack_adapter_revision", "database", "methods"])
            try validate(status)
            ready = true
            return status
        } catch {
            if generation == current { await stop() }
            throw error
        }
    }

    public func stop() async {
        if let cleanupTask {
            await joinCleanup(cleanupTask, generation: generation)
            return
        }
        guard transportNeedsCleanup else {
            reader?.cancel(); reader = nil
            return
        }
        stopping = true
        started = false
        ready = false
        generation &+= 1
        reader?.cancel(); reader = nil
        timeout?.cancel(); timeout = nil
        buffer.removeAll(keepingCapacity: false)
        finish(.failure(.cancelled))
        let startingChild = launchTask
        launchTask = nil
        let cleanup = Task { [transport] in
            if let startingChild { _ = await startingChild.result }
            await transport.terminate()
        }
        cleanupTask = cleanup
        await joinCleanup(cleanup, generation: generation)
    }

    public func status() async throws -> IMessageRPCStatus {
        let result: IMessageRPCStatus = try await call(.status, params: IMessageEmptyParams(), timeoutSeconds: readTimeoutSeconds, keys: ["protocol_version", "personastack_adapter_revision", "database", "methods"])
        try validate(result)
        return result
    }

    public func conversations(after: IMessageRowID, upper: IMessageRowID? = nil,
                              query: String = "", limit: Int = 50) async throws -> IMessageConversationPage {
        guard query.count <= 128, (1...50).contains(limit), upper.map({ $0 >= after }) ?? true else {
            throw IMessageRPCError.invalidArguments
        }
        let result: IMessageConversationPage = try await call(.chatsPage,
            params: ChatPageParams(after: after, upper: upper, query: query, limit: limit), timeoutSeconds: readTimeoutSeconds,
            keys: ["chats", "next_chat_rowid", "upper_chat_rowid", "has_more", "stop_reason"])
        guard result.chats.count <= limit, result.nextChatRowID >= after,
              result.nextChatRowID <= result.upperChatRowID,
              upper.map({ $0 == result.upperChatRowID }) ?? true,
              !result.hasMore || result.nextChatRowID > after else { throw IMessageRPCError.invalidResponse }
        for chat in result.chats { try validate(chat) }
        return result
    }

    public func sourceCheckpoint(chatIDs: [IMessageRowID], anchors: [IMessageSourceAnchor] = []) async throws -> IMessageSourceCheckpoint {
        let selected = Set(chatIDs)
        guard (1...32).contains(chatIDs.count), selected.count == chatIDs.count,
              chatIDs.allSatisfy({ $0.value > 0 }), anchors.count <= 32,
              Set(anchors.map(\.chatID)).count == anchors.count,
              anchors.allSatisfy({ selected.contains($0.chatID) && bounded($0.guid, maximum: 256, nonempty: true) }) else {
            throw IMessageRPCError.invalidArguments
        }
        let result: IMessageSourceCheckpoint = try await call(.sourceCheckpoint,
            params: CheckpointParams(chatIDs: chatIDs, anchors: anchors), timeoutSeconds: readTimeoutSeconds,
            keys: ["adapter_revision", "source_high_water", "chats", "observed_at"])
        guard result.adapterRevision == Self.adapterRevision,
              Set(result.chats.map(\.chatID)) == selected, result.chats.count == chatIDs.count,
              validDate(result.observedAt) else { throw IMessageRPCError.invalidResponse }
        for chat in result.chats {
            guard chat.tailRowID <= result.sourceHighWater,
                  bounded(chat.guid, maximum: 256), bounded(chat.tailGUID, maximum: 256),
                  chat.accountID.map({ bounded($0, maximum: 256) }) ?? true,
                  chat.accountLogin.map({ bounded($0, maximum: 256) }) ?? true,
                  !chat.available || chat.service == "iMessage" else { throw IMessageRPCError.invalidResponse }
        }
        return result
    }

    public func chatMetadata(chatIDs: [IMessageRowID]) async throws -> IMessageChatMetadata {
        guard (1...32).contains(chatIDs.count), Set(chatIDs).count == chatIDs.count,
              chatIDs.allSatisfy({ $0.value > 0 }) else { throw IMessageRPCError.invalidArguments }
        let result: IMessageChatMetadata = try await call(.chatMetadata, params: ChatMetadataParams(chatIDs: chatIDs),
            timeoutSeconds: min(readTimeoutSeconds, Self.chatMetadataTimeoutSeconds), keys: ["chats"],
            maximumResponseBytes: Self.maximumChatMetadataResultBytes + Self.chatMetadataEnvelopeBytes)
        guard result.chats.map(\.id) == chatIDs else { throw IMessageRPCError.invalidResponse }
        for chat in result.chats {
            if chat.available {
                try validate(chat)
                let fields = [chat.guid, chat.name] + chat.participants + [chat.accountID, chat.accountLogin].compactMap { $0 }
                guard fields.allSatisfy({ $0.utf8.count <= 256 }) else { throw IMessageRPCError.invalidResponse }
            }
            else {
                guard chat.guid.isEmpty, chat.name.isEmpty, chat.service.isEmpty, !chat.isGroup,
                      chat.participants.isEmpty, chat.accountID == nil, chat.accountLogin == nil else {
                    throw IMessageRPCError.invalidResponse
                }
            }
        }
        return result
    }

    public func receivePage(chatID: IMessageRowID, since: IMessageRowID, through: IMessageRowID? = nil,
                            limit: Int = 100) async throws -> IMessageReceivePage {
        guard chatID.value > 0, (1...100).contains(limit), through.map({ $0 >= since }) ?? true else {
            throw IMessageRPCError.invalidArguments
        }
        let result: IMessageReceivePage = try await call(.receivePage,
            params: ReceiveParams(chatID: chatID, since: since, through: through, limit: limit), timeoutSeconds: readTimeoutSeconds,
            keys: ["messages", "next_rowid", "has_more", "stop_reason"])
        guard result.messages.count <= limit, result.nextRowID >= since,
              through.map({ result.nextRowID <= $0 }) ?? true,
              !result.hasMore || result.nextRowID > since else { throw IMessageRPCError.invalidResponse }
        var previous = since
        for message in result.messages {
            try validate(message, chatID: chatID)
            guard message.rowID > previous, message.rowID <= result.nextRowID else { throw IMessageRPCError.invalidResponse }
            previous = message.rowID
        }
        return result
    }

    public func recentMessages(chatID: IMessageRowID, limit: Int = 50) async throws -> IMessageRecentMessages {
        guard chatID.value > 0, (1...100).contains(limit) else { throw IMessageRPCError.invalidArguments }
        let result: IMessageRecentMessages = try await call(.recentMessages,
            params: RecentParams(chatID: chatID, limit: limit), timeoutSeconds: readTimeoutSeconds,
            keys: ["messages", "truncated", "stop_reason"])
        guard result.messages.count <= limit else { throw IMessageRPCError.invalidResponse }
        for message in result.messages { try validate(message, chatID: chatID) }
        return result
    }

    /// Executes one send and verifies a new exact row in the selected chat.
    /// The caller must separately supply the current API-owned immediate-send grant.
    public func send(chatID: IMessageRowID, text: String, expectedAccountID: String) async throws -> IMessageSendReceipt {
        guard chatID.value > 0, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 16 * 1024, validAccountID(expectedAccountID) else { throw IMessageRPCError.invalidArguments }
        guard !mutationInFlight else { throw IMessageRPCError.busy }
        mutationInFlight = true
        mutationDeadline = Date().addingTimeInterval(sendTimeoutSeconds)
        defer { mutationInFlight = false; mutationDeadline = nil; receiptDeadline = nil }
        let checkpoint = try await sourceCheckpoint(chatIDs: [chatID])
        guard let chat = checkpoint.chats.first, chat.available, chat.service == "iMessage",
              bounded(chat.guid, maximum: 256, nonempty: true) else { throw IMessageRPCError.invalidResponse }
        let result: SendResult = try await call(.send, params: SendParams(chatID: chatID, chatGUID: chat.guid, text: text, expectedAccountID: expectedAccountID),
            timeoutSeconds: sendTimeoutSeconds, keys: ["submitted", "transport", "service", "chat_guid"])
        do {
            guard result.submitted, result.transport == "applescript", result.service == "iMessage",
                  result.chatGUID == chat.guid else { throw IMessageRPCError.outcomeUnknown }
            receiptDeadline = Date().addingTimeInterval(min(8, mutationDeadline?.timeIntervalSinceNow ?? 0))
            return try await confirmSend(chatID: chatID, chatGUID: chat.guid, text: text,
                                         after: checkpoint.sourceHighWater)
        } catch { throw IMessageRPCError.outcomeUnknown }
    }

    private func confirmSend(chatID: IMessageRowID, chatGUID: String, text: String,
                             after boundary: IMessageRowID) async throws -> IMessageSendReceipt {
        let submittedBytes = Data(text.utf8)
        while true {
            let observed = try await receivePage(chatID: chatID, since: boundary)
            let matches = observed.messages.filter { $0.isFromMe && Data($0.text.utf8) == submittedBytes && !$0.textTruncated }
            guard !observed.hasMore, observed.stopReason == .caughtUp, matches.count <= 1 else { throw IMessageRPCError.outcomeUnknown }
            if let match = matches.first {
                return IMessageSendReceipt(messageGUID: match.guid, rowID: match.rowID.value, chatGUID: chatGUID)
            }
            guard let receiptDeadline, receiptDeadline > Date() else { throw IMessageRPCError.outcomeUnknown }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func call<Parameters: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: IMessageRPCMethod, params: Parameters, timeoutSeconds: TimeInterval, keys: Set<String>?,
        maximumResponseBytes: Int = IMessageRPCClient.maximumFrameBytes
    ) async throws -> Result {
        guard started, ready || method == .initialize else { throw IMessageRPCError.notStarted }
        guard pending == nil else { throw IMessageRPCError.busy }
        try Task.checkCancellation()
        let effectiveTimeout = min(timeoutSeconds, mutationDeadline?.timeIntervalSinceNow ?? timeoutSeconds,
                                   receiptDeadline?.timeIntervalSinceNow ?? timeoutSeconds)
        guard effectiveTimeout > 0 else { throw IMessageRPCError.deadlineExceeded }
        let dispatchDeadline = Date().addingTimeInterval(effectiveTimeout)
        sequence &+= 1
        let id = "\(generation):\(sequence)"
        var request = try JSONEncoder().encode(IMessageRPCRequest(id: id, method: method, params: params))
        guard request.count < Self.maximumFrameBytes else { throw IMessageRPCError.invalidArguments }
        request.append(0x0a)
        let encodedRequest = request
        let cancellation = IMessageRPCDispatchGate()
        let raw: Data = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending = Pending(id: id, method: method, continuation: continuation, maximumResponseBytes: maximumResponseBytes)
                let current = generation
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(max(0, dispatchDeadline.timeIntervalSinceNow))) }
                    catch { return }
                    await self?.expire(id: id, generation: current)
                }
                Task { [weak self] in await self?.write(encodedRequest, id: id, generation: current, cancellation: cancellation, deadline: dispatchDeadline) }
            }
        } onCancel: {
            cancellation.cancel()
            Task { [weak self] in await self?.cancel(id: id) }
        }
        do {
            if let keys {
                let observed = try JSONDecoder().decode(IMessageRPCResultKeys.self, from: raw)
                if let names = observed.result?.names, !names.isSubset(of: keys) { throw IMessageRPCError.invalidResponse }
            }
            let response = try JSONDecoder().decode(IMessageRPCResponse<Result>.self, from: raw)
            if let error = response.error {
                let safe = error.data?.retrySafe ?? (error.code == -32602 || error.code == -32004)
                if method == .send && !safe { throw IMessageRPCError.outcomeUnknown }
                throw IMessageRPCError.providerRejected(code: error.code, retrySafe: safe)
            }
            guard let result = response.result else { throw IMessageRPCError.invalidResponse }
            return result
        } catch {
            if method == .send {
                if let known = error as? IMessageRPCError, case .providerRejected = known { throw known }
                throw IMessageRPCError.outcomeUnknown
            }
            throw (error as? IMessageRPCError) ?? .invalidResponse
        }
    }

    private func write(_ data: Data, id: String, generation current: UInt64,
                       cancellation: IMessageRPCDispatchGate, deadline: Date) async {
        guard current == generation, pending?.id == id else { return }
        if let rejection = cancellation.claim(before: deadline) {
            await failed(rejection, generation: current)
            return
        }
        pending?.dispatched = true
        do { try await transport.write(data) }
        catch { await failed(.processExited, generation: current) }
    }

    private func receive(_ bytes: Data, generation current: UInt64) async -> Bool {
        guard current == generation, started else { return false }
        for byte in bytes {
            if byte == 0x0a {
                guard !buffer.isEmpty else { await failed(.invalidResponse, generation: current); return false }
                let frame = buffer
                buffer.removeAll(keepingCapacity: true)
                guard let identity = try? JSONDecoder().decode(IMessageRPCIdentity.self, from: frame),
                      identity.id == pending?.id else {
                    await failed(.invalidResponse, generation: current); return false
                }
                timeout?.cancel(); timeout = nil
                let continuation = pending?.continuation
                pending = nil
                continuation?.resume(returning: frame)
            } else {
                guard buffer.count < (pending?.maximumResponseBytes ?? Self.maximumFrameBytes) else {
                    await failed(.frameTooLarge, generation: current); return false
                }
                buffer.append(byte)
            }
        }
        return true
    }

    private func expire(id: String, generation current: UInt64) async {
        guard current == generation, pending?.id == id else { return }
        await failed(.deadlineExceeded, generation: current)
    }

    private func cancel(id: String) async {
        guard pending?.id == id else { return }
        await failed(.cancelled, generation: generation)
    }

    private func failed(_ error: IMessageRPCError, generation current: UInt64) async {
        guard current == generation else { return }
        stopping = true
        started = false
        ready = false
        generation &+= 1
        timeout?.cancel(); timeout = nil
        buffer.removeAll(keepingCapacity: false)
        let failedRequest = pending
        pending = nil
        let cleanup = Task { [transport] in await transport.terminate() }
        cleanupTask = cleanup
        await joinCleanup(cleanup, generation: generation)
        if let request = failedRequest {
            request.continuation.resume(throwing: request.method == .send && request.dispatched ? IMessageRPCError.outcomeUnknown : error)
        }
    }

    private func joinCleanup(_ cleanup: Task<Void, Never>, generation expected: UInt64) async {
        await cleanup.value
        guard generation == expected else { return }
        cleanupTask = nil
        transportNeedsCleanup = false
        stopping = false
    }

    private func finish(_ outcome: Result<Data, IMessageRPCError>) {
        guard let request = pending else { return }
        pending = nil
        switch outcome {
        case .success(let data): request.continuation.resume(returning: data)
        case .failure(let error):
            request.continuation.resume(throwing: request.method == .send && request.dispatched ? IMessageRPCError.outcomeUnknown : error)
        }
    }

    private func validate(_ status: IMessageRPCStatus) throws {
        let advertised = Set(status.methods)
        let permitted = Set(IMessageRPCMethod.allCases.map(\.rawValue))
        let baseline = Set([IMessageRPCMethod.initialize.rawValue, IMessageRPCMethod.status.rawValue])
        guard status.protocolVersion == 1, status.adapterRevision == Self.adapterRevision,
              baseline.isSubset(of: advertised), advertised.isSubset(of: permitted),
              status.methods.count == advertised.count,
              !status.database.ready || advertised == permitted else { throw IMessageRPCError.dependencyInvalid }
    }

    private func validate(_ chat: IMessageConversation) throws {
        guard chat.id.value > 0, chat.service == "iMessage", bounded(chat.guid, maximum: 256), (!chat.available || !chat.guid.isEmpty),
              bounded(chat.name, maximum: 256), chat.participants.count <= 100,
              chat.participants.allSatisfy({ bounded($0, maximum: 256, nonempty: true) }),
              chat.accountID.map({ bounded($0, maximum: 256) }) ?? true,
              chat.accountLogin.map({ bounded($0, maximum: 256) }) ?? true else { throw IMessageRPCError.invalidResponse }
    }

    private func validate(_ message: IMessageMessage, chatID: IMessageRowID) throws {
        guard message.rowID.value > 0, message.chatID == chatID, message.service == "iMessage",
              bounded(message.guid, maximum: 256, nonempty: true), bounded(message.sender, maximum: 256),
              message.text.utf8.count <= 16 * 1024, message.attachmentCount >= 0,
              message.attachments.isEmpty, validDate(message.date),
              message.editedAt.map({ validDate($0) }) ?? true,
              message.unsentAt.map({ validDate($0) }) ?? true else { throw IMessageRPCError.invalidResponse }
    }

    private func validAccountID(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 256 &&
        !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private func bounded(_ value: String, maximum: Int, nonempty: Bool = false) -> Bool {
        value.count <= maximum && (!nonempty || !value.isEmpty)
    }

    private func validDate(_ value: String) -> Bool {
        guard value.count <= 40, value.hasSuffix("Z") else { return false }
        let formatter = ISO8601DateFormatter()
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value) != nil
    }
}

private struct ChatPageParams: Encodable, Sendable {
    let after: IMessageRowID; let upper: IMessageRowID?; let query: String; let limit: Int
    enum CodingKeys: String, CodingKey {
        case after = "after_chat_rowid", upper = "upper_chat_rowid", query, limit
    }
}
private struct CheckpointParams: Encodable, Sendable {
    let chatIDs: [IMessageRowID]; let anchors: [IMessageSourceAnchor]
    enum CodingKeys: String, CodingKey { case chatIDs = "chat_ids", anchors }
}
private struct ChatMetadataParams: Encodable, Sendable {
    let chatIDs: [IMessageRowID]
    enum CodingKeys: String, CodingKey { case chatIDs = "chat_ids" }
}
private struct ReceiveParams: Encodable, Sendable {
    let chatID: IMessageRowID; let since: IMessageRowID; let through: IMessageRowID?; let limit: Int
    enum CodingKeys: String, CodingKey { case chatID = "chat_id", since = "since_rowid", through = "through_rowid", limit }
}
private struct RecentParams: Encodable, Sendable {
    let chatID: IMessageRowID; let limit: Int
    enum CodingKeys: String, CodingKey { case chatID = "chat_id", limit }
}
private struct SendParams: Encodable, Sendable {
    let chatID: IMessageRowID; let chatGUID: String; let text: String; let expectedAccountID: String
    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id", chatGUID = "chat_guid", text, expectedAccountID = "expected_account_id"
    }
}
private struct SendResult: Decodable, Sendable {
    let submitted: Bool; let transport: String; let service: String; let chatGUID: String
    enum CodingKeys: String, CodingKey { case submitted, transport, service, chatGUID = "chat_guid" }
}

/// Synchronous cancellation fences an actor-queued write before it claims dispatch.
/// Once claimed, cancellation is conservatively an unknown external outcome.
internal final class IMessageRPCDispatchGate: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var claimed = false

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }

    func claim(before deadline: Date) -> IMessageRPCError? {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return .cancelled }
        guard Date() < deadline else { return .deadlineExceeded }
        guard !claimed else { return .invalidResponse }
        claimed = true
        return nil
    }
}
