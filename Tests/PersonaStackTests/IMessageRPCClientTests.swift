import Foundation
import Testing
@testable import PersonaStackCore

private actor IMessageFakeTransport: IMessageRPCTransport {
    enum Mode: Sendable { case partialLaunchFailure, metadataOversized, metadataLongUTF8, metadataUnavailableHint, metadataReversed, metadataMissing, metadataDuplicate, metadataForeign, metadataInvalidUnavailable, metadataWrongService, metadataNoResponse, missingMetadataMethod, normal, noStatus, bareSend, writeFailure, wrongChat, malformed, oldReceipt, wrongReceiptText, noReceipt, holdSend, oversized, incompatible, delayedLaunch, delayedTerminate, upstreamMethods, lateReceipt, incompleteReceipt, holdCheckpoint }
    let mode: Mode
    private var queued: [Data] = []
    private var waiting: CheckedContinuation<Data, Error>?
    private(set) var writes: [Data] = []
    private(set) var stopped = 0
    private(set) var launched = 0
    private var lastSentText: String?
    private var sendWaiter: CheckedContinuation<Void, Never>?
    private var launchWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var launchEntered = false
    private var terminationWaiter: CheckedContinuation<Void, Never>?
    private var terminateRelease: CheckedContinuation<Void, Never>?
    private var terminationEntered = false
    private(set) var activeChild = false
    private var receiptReadCount = 0
    private var checkpointWaiter: CheckedContinuation<Void, Never>?
    private var heldCheckpoint: Data?
    init(mode: Mode = .normal) { self.mode = mode }
    func launch() async throws {
        launched += 1
        if mode == .delayedLaunch {
            launchEntered = true
            await withCheckedContinuation { continuation in
                releaseWaiter = continuation
                launchWaiter?.resume(); launchWaiter = nil
            }
        }
        activeChild = true
        if mode == .partialLaunchFailure { throw IMessageRPCError.processExited }
    }
    func waitForLaunch() async {
        if launchEntered { return }
        await withCheckedContinuation { launchWaiter = $0 }
    }
    func releaseLaunch() { releaseWaiter?.resume(); releaseWaiter = nil }
    func read(maximumBytes: Int) async throws -> Data {
        guard activeChild else { throw IMessageRPCError.notStarted }
        if !queued.isEmpty { return queued.removeFirst() }
        guard waiting == nil else { throw IMessageRPCError.invalidResponse }
        return try await withCheckedThrowingContinuation { waiting = $0 }
    }
    func write(_ data: Data) throws {
        writes.append(data)
        let request = try JSONDecoder().decode(Request.self, from: data)
        if mode == .writeFailure && request.method == "personastack.send" { throw IMessageRPCError.processExited }
        if mode == .noStatus && request.method == "personastack.status" { return }
        if mode == .metadataNoResponse && request.method == "personastack.chatMetadata" { return }
        if mode == .metadataOversized && request.method == "personastack.chatMetadata" {
            emit(Data(repeating: 0x78, count: IMessageRPCClient.maximumChatMetadataResultBytes + 512)); return
        }
        if request.method == "personastack.send" {
            lastSentText = request.params?.text
            sendWaiter?.resume(); sendWaiter = nil
            if mode == .holdSend { return }
        }
        if mode == .oversized && request.method == "personastack.status" {
            emit(Data(repeating: 0x78, count: IMessageRPCClient.maximumFrameBytes + 1)); return
        }
        if mode == .noReceipt && request.method == "personastack.receive_page" { return }
        if mode == .malformed && request.method == "personastack.status" {
            emit(Data("{bad-json}\n".utf8)); return
        }
        let result: String
        switch request.method {
        case "personastack.initialize", "personastack.status":
            let methodNames = mode == .upstreamMethods ? ["initialize", "status", "send"] : IMessageRPCMethod.allCases.map(\.rawValue)
                .filter { mode != .missingMetadataMethod || $0 != "personastack.chatMetadata" }
            let methods = String(decoding: try JSONEncoder().encode(methodNames), as: UTF8.self)
            if mode == .incompatible {
                result = "{\"protocol_version\":1,\"personastack_adapter_revision\":1,\"database\":{\"ready\":true},\"methods\":\(methods)}"
                break
            }
            result = "{\"protocol_version\":1,\"personastack_adapter_revision\":2,\"database\":{\"ready\":true},\"methods\":\(methods)}"
        case "personastack.chatMetadata":
            var ids = request.params?.chatIDs ?? []
            if mode == .metadataReversed { ids.reverse() }
            if mode == .metadataMissing { ids = Array(ids.dropLast()) }
            if mode == .metadataDuplicate, let first = ids.first { ids = Array(repeating: first, count: ids.count) }
            if mode == .metadataForeign { ids = ["99"] }
            let rows = ids.map { id in
                if id == "42" {
                    let service = mode == .metadataWrongService ? "SMS" : "iMessage"
                    let name = mode == .metadataLongUTF8 ? String(repeating: "é", count: 256) : "Test"
                    return "{\"id\":\"\(id)\",\"guid\":\"iMessage;+;group\",\"name\":\"\(name)\",\"service\":\"\(service)\",\"is_group\":true,\"available\":true,\"participants\":[\"test@example.invalid\"]}"
                }
                let name = mode == .metadataInvalidUnavailable ? "invented metadata" : ""
                let hint = mode == .metadataUnavailableHint ? ",\"account_id\":\"invented\"" : ""
                return "{\"id\":\"\(id)\",\"guid\":\"\",\"name\":\"\(name)\",\"service\":\"\",\"is_group\":false,\"available\":false,\"participants\":[]\(hint)}"
            }
            result = "{\"chats\":[" + rows.joined(separator: ",") + "]}"
        case "personastack.chats.page":
            result = #"{"chats":[{"id":"42","guid":"iMessage;+;group","name":"Test","service":"iMessage","is_group":true,"available":true,"participants":["test@example.invalid"]}],"next_chat_rowid":"42","upper_chat_rowid":"42","has_more":false,"stop_reason":"caught_up"}"#
        case "personastack.source_checkpoint":
            result = #"{"adapter_revision":2,"source_high_water":"9007199254740992","chats":[{"chat_id":"42","guid":"iMessage;+;group","service":"iMessage","available":true,"tail_rowid":"0","tail_guid":""}],"observed_at":"2026-11-04T00:00:00Z"}"#
        case "personastack.receive_page":
            receiptReadCount += 1
            if mode == .lateReceipt && receiptReadCount == 1 {
                result = #"{"messages":[],"next_rowid":"9007199254740992","has_more":false,"stop_reason":"caught_up"}"#
                break
            }
            let chat = mode == .wrongChat ? "99" : "42"
            let text = mode == .wrongReceiptText ? "different" : (lastSentText ?? "Test")
            let encodedText = String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
            let messageGUID = lastSentText == nil ? "event-1" : "outgoing-1"
            let fromMe = lastSentText == nil ? "false" : "true"
            let rowID = mode == .oldReceipt ? "9007199254740992" : "9007199254740993"
            let stopReason = mode == .incompleteReceipt ? "scan_limit" : "caught_up"
            result = "{\"messages\":[{\"rowid\":\"\(rowID)\",\"guid\":\"\(messageGUID)\",\"chat_id\":\"\(chat)\",\"text\":\(encodedText),\"is_from_me\":\(fromMe),\"date\":\"2026-11-04T00:00:00Z\",\"sender\":\"test@example.invalid\",\"service\":\"iMessage\",\"text_truncated\":false,\"attachment_count\":0,\"attachments\":[]}],\"next_rowid\":\"\(rowID)\",\"has_more\":false,\"stop_reason\":\"\(stopReason)\"}"
        case "personastack.send":
            result = mode == .bareSend ? #"{"ok":true,"transport":"applescript"}"# : #"{"submitted":true,"transport":"applescript","service":"iMessage","chat_guid":"iMessage;+;group"}"#
        default: throw IMessageRPCError.invalidArguments
        }
        let response = Data("{\"jsonrpc\":\"2.0\",\"id\":\"\(request.id)\",\"result\":\(result)}\n".utf8)
        if mode == .holdCheckpoint && request.method == "personastack.source_checkpoint" {
            heldCheckpoint = response
            checkpointWaiter?.resume(); checkpointWaiter = nil
            return
        }
        emit(response)
    }
    func terminate() async {
        if mode == .delayedTerminate && !terminationEntered {
            terminationEntered = true
            await withCheckedContinuation { continuation in
                terminateRelease = continuation
                terminationWaiter?.resume(); terminationWaiter = nil
            }
        }
        activeChild = false
        stopped += 1
        queued.removeAll()
        waiting?.resume(returning: Data())
        waiting = nil
    }
    func waitForCheckpoint() async {
        if heldCheckpoint != nil { return }
        await withCheckedContinuation { checkpointWaiter = $0 }
    }
    func releaseCheckpoint() {
        if let heldCheckpoint { emit(heldCheckpoint) }
        heldCheckpoint = nil
    }
    func waitForTermination() async {
        if terminationEntered { return }
        await withCheckedContinuation { terminationWaiter = $0 }
    }
    func releaseTermination() { terminateRelease?.resume(); terminateRelease = nil }
    func waitForSend() async {
        if lastSentText != nil { return }
        await withCheckedContinuation { sendWaiter = $0 }
    }
    private func emit(_ data: Data) {
        for start in stride(from: 0, to: data.count, by: 8192) {
            let chunk = Data(data[start..<min(start + 8192, data.count)])
            if let continuation = waiting { waiting = nil; continuation.resume(returning: chunk) }
            else { queued.append(chunk) }
        }
    }
    private struct Request: Decodable {
        struct Params: Decodable {
            let text: String?
            let chatIDs: [String]?
            enum CodingKeys: String, CodingKey { case text, chatIDs = "chat_ids" }
        }
        let id: String; let method: String; let params: Params?
    }
}

@Test func iMessageRPCClientNegotiatesPinnedAdapterAndUsesFiniteScopedMethods() async throws {
    let transport = IMessageFakeTransport()
    let client = IMessageRPCClient(transport: transport)
    let status = try await client.start()
    #expect(status.adapterRevision == 2)
    #expect(status.methods.contains("personastack.chatMetadata"))
    let page = try await client.conversations(after: IMessageRowID(0))
    #expect(page.chats.first?.id.value == 42)
    let received = try await client.receivePage(chatID: IMessageRowID(42), since: IMessageRowID(9_007_199_254_740_992))
    #expect(received.nextRowID.value == 9_007_199_254_740_993)
    #expect(received.messages.first?.guid == "event-1")
    await client.stop()
    #expect(await transport.stopped == 1)
}

@Test func iMessageRPCClientReadsExactOrderedMetadataWithoutListingOrReadingMessages() async throws {
    let transport = IMessageFakeTransport()
    let client = IMessageRPCClient(transport: transport)
    _ = try await client.start()
    let ids = try [IMessageRowID(43), IMessageRowID(42), IMessageRowID(9_007_199_254_740_993)]
    let metadata = try await client.chatMetadata(chatIDs: ids)
    #expect(metadata.chats.map(\.id) == ids)
    #expect(metadata.chats.map(\.available) == [false, true, false])
    #expect(metadata.chats[0].guid.isEmpty)
    #expect(metadata.chats[0].service.isEmpty)
    let writes = await transport.writes
    #expect(writes.count == 2)
    let request = try #require(JSONSerialization.jsonObject(with: writes[1]) as? [String: Any])
    #expect(request["method"] as? String == "personastack.chatMetadata")
    let params = try #require(request["params"] as? [String: Any])
    #expect(Set(params.keys) == ["chat_ids"])
    #expect(params["chat_ids"] as? [String] == ids.map(\.rawValue))
    await client.stop()
}

@Test func iMessageRPCClientRejectsInvalidMetadataSelectionsWithoutProviderCalls() async throws {
    let transport = IMessageFakeTransport()
    let client = IMessageRPCClient(transport: transport)
    _ = try await client.start()
    let tooMany = try (1...33).map { try IMessageRowID(Int64($0)) }
    for ids in [[], [try IMessageRowID(0)], [try IMessageRowID(42), try IMessageRowID(42)], tooMany] {
        await #expect(throws: IMessageRPCError.invalidArguments) { try await client.chatMetadata(chatIDs: ids) }
    }
    #expect(await transport.writes.count == 1)
    await client.stop()
}

@Test func iMessageRPCClientRejectsIncompleteReorderedOrUntruthfulMetadata() async throws {
    for mode in [IMessageFakeTransport.Mode.metadataReversed, .metadataMissing, .metadataDuplicate, .metadataForeign,
                 .metadataInvalidUnavailable, .metadataWrongService, .metadataUnavailableHint, .metadataLongUTF8] {
        let transport = IMessageFakeTransport(mode: mode)
        let client = IMessageRPCClient(transport: transport)
        _ = try await client.start()
        await #expect(throws: IMessageRPCError.invalidResponse) {
            try await client.chatMetadata(chatIDs: [IMessageRowID(42), IMessageRowID(43)])
        }
        #expect(await transport.writes.count == 2)
        await client.stop()
    }
}

@Test func iMessageRPCClientRequiresTheRevisionTwoMetadataCatalog() async {
    let transport = IMessageFakeTransport(mode: .missingMetadataMethod)
    let client = IMessageRPCClient(transport: transport)
    await #expect(throws: IMessageRPCError.dependencyInvalid) { try await client.start() }
    #expect(await transport.writes.count == 1)
    #expect(await transport.stopped == 1)
}

@Test func iMessageRPCClientBoundsMetadataDeadlineAndOutputWithoutRetry() async throws {
    for mode in [IMessageFakeTransport.Mode.metadataNoResponse, .metadataOversized] {
        let transport = IMessageFakeTransport(mode: mode)
        let client = IMessageRPCClient(transport: transport, readTimeoutSeconds: mode == .metadataNoResponse ? 0.02 : 2, sendTimeoutSeconds: 1)
        _ = try await client.start()
        let error: IMessageRPCError = mode == .metadataNoResponse ? .deadlineExceeded : .frameTooLarge
        await #expect(throws: error) { try await client.chatMetadata(chatIDs: [IMessageRowID(42)]) }
        #expect(await transport.writes.count == 2)
        #expect(await transport.stopped == 1)
        await client.stop()
    }
}

@Test func iMessageRPCClientUsesOnlyThePrivateExactChatSendContract() async throws {
    let transport = IMessageFakeTransport()
    let client = IMessageRPCClient(transport: transport)
    _ = try await client.start()
    let receipt = try await client.send(chatID: IMessageRowID(42), text: "exact text\nsecond line", expectedAccountID: "account-1")
    #expect(receipt.rowID == 9_007_199_254_740_993)
    let writes = await transport.writes
    let send = try #require(writes.first(where: { String(decoding: $0, as: UTF8.self).contains("\"method\":\"personastack.send\"") }))
    let object = try #require(JSONSerialization.jsonObject(with: send) as? [String: Any])
    let params = try #require(object["params"] as? [String: Any])
    #expect(object["method"] as? String == "personastack.send")
    #expect(Set(params.keys) == ["chat_id", "chat_guid", "text", "expected_account_id"])
    #expect(params["chat_id"] as? String == "42")
    #expect(params["chat_guid"] as? String == "iMessage;+;group")
    #expect(params["expected_account_id"] as? String == "account-1")
    #expect(params["text"] as? String == "exact text\nsecond line")
    #expect(writes.count == 4)
    await client.stop()
}

@Test func iMessageRPCClientNeverConfirmsBareSendSuccessOrRetriesWriteFailure() async throws {
    for mode in [IMessageFakeTransport.Mode.bareSend, .writeFailure] {
        let transport = IMessageFakeTransport(mode: mode)
        let client = IMessageRPCClient(transport: transport)
        _ = try await client.start()
        await #expect(throws: IMessageRPCError.outcomeUnknown) {
            try await client.send(chatID: IMessageRowID(42), text: "test", expectedAccountID: "account-1")
        }
        #expect(await transport.writes.count == 3)
        await client.stop()
    }
}

@Test func iMessageRPCClientRejectsForeignChatResponsesBeforeReturningContent() async throws {
    let transport = IMessageFakeTransport(mode: .wrongChat)
    let client = IMessageRPCClient(transport: transport)
    _ = try await client.start()
    await #expect(throws: IMessageRPCError.invalidResponse) {
        try await client.receivePage(chatID: IMessageRowID(42), since: IMessageRowID(0))
    }
    await client.stop()
}

@Test func iMessageRPCClientRejectsInvalidArgumentsWithoutProviderCalls() async throws {
    let transport = IMessageFakeTransport()
    let client = IMessageRPCClient(transport: transport)
    _ = try await client.start()
    await #expect(throws: IMessageRPCError.invalidArguments) {
        try await client.send(chatID: IMessageRowID(42), text: "  \n", expectedAccountID: "account-1")
    }
    await #expect(throws: IMessageRPCError.invalidArguments) {
        try await client.sourceCheckpoint(chatIDs: [IMessageRowID(42), IMessageRowID(42)])
    }
    await #expect(throws: IMessageRPCError.invalidArguments) {
        try await client.conversations(after: IMessageRowID(0), query: String(repeating: "a", count: 129))
    }
    #expect(await transport.writes.count == 1)
    await client.stop()
}

@Test func iMessageRPCClientBoundsReadTimeoutAndReapsTransport() async throws {
    let transport = IMessageFakeTransport(mode: .noStatus)
    let client = IMessageRPCClient(transport: transport, readTimeoutSeconds: 0.02, sendTimeoutSeconds: 0.02)
    _ = try await client.start()
    await #expect(throws: IMessageRPCError.deadlineExceeded) { try await client.status() }
    #expect(await transport.stopped == 1)
    await #expect(throws: IMessageRPCError.notStarted) { try await client.status() }
}

@Test func iMessageRPCClientRejectsMalformedChildOutput() async throws {
    let transport = IMessageFakeTransport(mode: .malformed)
    let client = IMessageRPCClient(transport: transport)
    _ = try await client.start()
    await #expect(throws: IMessageRPCError.invalidResponse) { try await client.status() }
    #expect(await transport.stopped == 1)
}

@Test func iMessageRPCClientRequiresANewExactLocalRowBeforeConfirmingSend() async throws {
    for mode in [IMessageFakeTransport.Mode.oldReceipt, .wrongReceiptText, .noReceipt, .incompleteReceipt] {
        let transport = IMessageFakeTransport(mode: mode)
        let client = IMessageRPCClient(transport: transport, readTimeoutSeconds: 0.05, sendTimeoutSeconds: 0.1)
        _ = try await client.start()
        await #expect(throws: IMessageRPCError.outcomeUnknown) {
            try await client.send(chatID: IMessageRowID(42), text: "test", expectedAccountID: "account-1")
        }
        let writes = await transport.writes
        #expect(writes.filter { String(decoding: $0, as: UTF8.self).contains("\"method\":\"personastack.send\"") }.count == 1)
        await client.stop()
    }
}

@Test func iMessageRPCClientSerializesAndNeverReplaysACancelledStartedSend() async throws {
    let transport = IMessageFakeTransport(mode: .holdSend)
    let client = IMessageRPCClient(transport: transport)
    _ = try await client.start()
    let send = Task { try await client.send(chatID: IMessageRowID(42), text: "test", expectedAccountID: "account-1") }
    await transport.waitForSend()
    await #expect(throws: IMessageRPCError.busy) {
        try await client.send(chatID: IMessageRowID(42), text: "second", expectedAccountID: "account-1")
    }
    send.cancel()
    await #expect(throws: IMessageRPCError.outcomeUnknown) { try await send.value }
    _ = try await client.start()
    let writes = await transport.writes
    #expect(writes.filter { String(decoding: $0, as: UTF8.self).contains("\"method\":\"personastack.send\"") }.count == 1)
    await client.stop()
}

@Test func iMessageRPCClientBoundsAFrameAcrossManyReadChunks() async throws {
    let transport = IMessageFakeTransport(mode: .oversized)
    let client = IMessageRPCClient(transport: transport)
    _ = try await client.start()
    await #expect(throws: IMessageRPCError.frameTooLarge) { try await client.status() }
    #expect(await transport.stopped == 1)
}

@Test func iMessageRPCClientRejectsAnUnpinnedAdapterBeforeAnyProtectedRead() async throws {
    let transport = IMessageFakeTransport(mode: .incompatible)
    let client = IMessageRPCClient(transport: transport)
    await #expect(throws: IMessageRPCError.dependencyInvalid) { try await client.start() }
    #expect(await transport.writes.count == 1)
    #expect(await transport.stopped == 1)
}

@Test func iMessageRPCClientStopJoinsAnInFlightLaunchBeforeTerminating() async throws {
    for _ in 0..<10 {
        let transport = IMessageFakeTransport(mode: .delayedLaunch)
        let client = IMessageRPCClient(transport: transport)
        let starting = Task { try await client.start() }
        await transport.waitForLaunch()
        let stopping = Task { await client.stop() }
        await Task.yield()
        await transport.releaseLaunch()
        await stopping.value
        _ = try? await starting.value
        #expect(await transport.activeChild == false)
        #expect(await transport.stopped == 1)
    }
}

@Test func iMessageRPCClientEveryStopCallerWaitsForTheSameCleanup() async throws {
    for _ in 0..<10 {
        let transport = IMessageFakeTransport(mode: .delayedTerminate)
        let client = IMessageRPCClient(transport: transport)
        _ = try await client.start()
        let first = Task { await client.stop() }
        await transport.waitForTermination()
        await #expect(throws: IMessageRPCError.alreadyStarted) { try await client.start() }
        let second = Task { () -> Bool in
            await client.stop()
            return await transport.activeChild
        }
        await Task.yield()
        await transport.releaseTermination()
        await first.value
        #expect(await second.value == false)
        #expect(await transport.stopped == 1)
        _ = try await client.start()
        await client.stop()
    }
}

@Test func iMessageRPCClientCompletedStopIsIdempotentAndRestartOwnsFreshCleanup() async throws {
    let transport = IMessageFakeTransport()
    let client = IMessageRPCClient(transport: transport)
    await client.stop()
    #expect(await transport.stopped == 0)
    _ = try await client.start()
    #expect(await transport.activeChild)
    await client.stop()
    #expect(await transport.activeChild == false)
    await client.stop()
    await client.stop()
    #expect(await transport.stopped == 1)
    _ = try await client.start()
    #expect(await transport.activeChild)
    #expect(await transport.launched == 2)
    await client.stop()
    #expect(await transport.activeChild == false)
    #expect(await transport.stopped == 2)
}

@Test func iMessageRPCClientThrowingPartialLaunchJoinsCleanupBeforeReturningFailure() async {
    let transport = IMessageFakeTransport(mode: .partialLaunchFailure)
    let client = IMessageRPCClient(transport: transport)
    await #expect(throws: IMessageRPCError.processExited) { try await client.start() }
    #expect(await transport.activeChild == false)
    #expect(await transport.stopped == 1)
    await client.stop()
    #expect(await transport.stopped == 1)
}

@Test func iMessageRPCClientCleanDeallocationCannotTerminateANewTransportOwner() async throws {
    let transport = IMessageFakeTransport()
    var retired: IMessageRPCClient? = IMessageRPCClient(transport: transport)
    _ = try await retired?.start()
    await retired?.stop()
    let replacement = IMessageRPCClient(transport: transport)
    _ = try await replacement.start()
    weak var released = retired
    retired = nil
    for _ in 0..<10 { await Task.yield() }
    #expect(released == nil)
    _ = try await replacement.status()
    #expect(await transport.activeChild)
    #expect(await transport.stopped == 1)
    await replacement.stop()
    #expect(await transport.stopped == 2)
}

@Test func iMessageRPCClientRejectsAnUpstreamPrivateBridgeCatalog() async throws {
    let transport = IMessageFakeTransport(mode: .upstreamMethods)
    let client = IMessageRPCClient(transport: transport)
    await #expect(throws: IMessageRPCError.dependencyInvalid) { try await client.start() }
    #expect(await transport.writes.count == 1)
}

@Test func iMessageRPCClientMayPollAReadReceiptButNeverRepeatsThePrivateSend() async throws {
    let transport = IMessageFakeTransport(mode: .lateReceipt)
    let client = IMessageRPCClient(transport: transport)
    _ = try await client.start()
    let receipt = try await client.send(chatID: IMessageRowID(42), text: "test", expectedAccountID: "account-1")
    #expect(receipt.messageGUID == "outgoing-1")
    let writes = await transport.writes
    #expect(writes.filter { String(decoding: $0, as: UTF8.self).contains("\"method\":\"personastack.send\"") }.count == 1)
    #expect(writes.filter { String(decoding: $0, as: UTF8.self).contains("\"method\":\"personastack.receive_page\"") }.count == 2)
    await client.stop()
}

@Test func iMessageRPCClientRequiresABoundedControlFreeApprovedAccountBeforeReads() async throws {
    let transport = IMessageFakeTransport()
    let client = IMessageRPCClient(transport: transport)
    _ = try await client.start()
    for invalid in ["", "   ", "account\nother", "account\t", String(repeating: "é", count: 129)] {
        await #expect(throws: IMessageRPCError.invalidArguments) {
            try await client.send(chatID: IMessageRowID(42), text: "test", expectedAccountID: invalid)
        }
    }
    #expect(await transport.writes.count == 1)
    await client.stop()
}

@Test func iMessageRPCClientCancellationBeforeCheckpointAcceptanceNeverSends() async throws {
    let transport = IMessageFakeTransport(mode: .holdCheckpoint)
    let client = IMessageRPCClient(transport: transport)
    _ = try await client.start()
    let sending = Task {
        try await client.send(chatID: IMessageRowID(42), text: "test", expectedAccountID: "account-1")
    }
    await transport.waitForCheckpoint()
    sending.cancel()
    await transport.releaseCheckpoint()
    do { _ = try await sending.value; Issue.record("Cancelled setup dispatched a send") }
    catch is CancellationError { }
    catch let failure as IMessageRPCError { #expect(failure == .cancelled) }
    let writes = await transport.writes
    #expect(!writes.contains { String(decoding: $0, as: UTF8.self).contains("\"method\":\"personastack.send\"") })
    await client.stop()
}

@Test func iMessageRPCDispatchGateDeniesCancellationAndExpiryBeforeWrite() {
    let cancelled = IMessageRPCDispatchGate()
    cancelled.cancel()
    #expect(cancelled.claim(before: Date().addingTimeInterval(5)) == .cancelled)
    let expired = IMessageRPCDispatchGate()
    #expect(expired.claim(before: Date().addingTimeInterval(-1)) == .deadlineExceeded)
    let once = IMessageRPCDispatchGate()
    #expect(once.claim(before: Date().addingTimeInterval(5)) == nil)
    #expect(once.claim(before: Date().addingTimeInterval(5)) == .invalidResponse)
}
