#if canImport(PersonaStackCore)
import Foundation
import PersonaStackCore
import Testing
@testable import IMessageBridgeProbe

private let backendTarget = ProbeTarget(
    conversationID: "42", accountID: "public-account", sourceGeneration: "source-1", displayName: "Test contact"
)

private struct CheckpointFixture: Sendable {
    var highWater = "100"
    var tailRow = "80"
    var tailGUID = "synthetic-guid"
    var anchorMatches: Bool? = true
}

private actor ScriptedProbeTransport: IMessageRPCTransport {
    struct Anchor: Decodable, Equatable {
        let chatID: String
        let rowID: String
        let guid: String
        enum CodingKeys: String, CodingKey { case chatID = "chat_id", rowID = "rowid", guid }
    }
    private struct Params: Decodable {
        let anchors: [Anchor]?
        let expectedAccountID: String?
        enum CodingKeys: String, CodingKey { case anchors, expectedAccountID = "expected_account_id" }
    }
    private struct Request: Decodable { let id: String; let method: String; let params: Params }
    private var frames: [Data] = []
    private var reader: CheckedContinuation<Data, Error>?
    private var closed = false
    private var checkpoints: [CheckpointFixture]
    private var checkpointHoldCountdown: Int?
    private var checkpointHold: (started: CoreGate, wait: CoreGate)?
    private var sendHold: (started: CoreGate, wait: CoreGate)?
    private var failingMethod: String?
    private(set) var launchCount = 0
    private(set) var readCount = 0
    private(set) var methods: [String] = []
    private(set) var checkpointAnchors: [[Anchor]] = []
    private(set) var terminateCount = 0

    init(checkpoints: [CheckpointFixture] = [CheckpointFixture()]) {
        self.checkpoints = checkpoints
    }

    func launch() { launchCount += 1; closed = false }

    func read(maximumBytes: Int) async throws -> Data {
        readCount += 1
        if !frames.isEmpty { return frames.removeFirst() }
        if closed { return Data() }
        return try await withCheckedThrowingContinuation { reader = $0 }
    }

    func write(_ data: Data) async throws {
        let request = try JSONDecoder().decode(Request.self, from: data)
        methods.append(request.method)
        if request.method == failingMethod {
            failingMethod = nil
            throw IMessageRPCError.processExited
        }
        let result: String
        switch request.method {
        case "personastack.initialize", "personastack.status":
            result = #"{"protocol_version":1,"personastack_adapter_revision":2,"database":{"ready":true},"methods":["personastack.initialize","personastack.status","personastack.send","personastack.chats.page","personastack.chatMetadata","personastack.source_checkpoint","personastack.receive_page","personastack.recent_messages"]}"#
        case "personastack.source_checkpoint":
            let anchors = request.params.anchors ?? []
            checkpointAnchors.append(anchors)
            if let countdown = checkpointHoldCountdown {
                checkpointHoldCountdown = countdown - 1
                if countdown == 1, let checkpointHold {
                    await checkpointHold.started.release()
                    await checkpointHold.wait.wait()
                    guard !closed else { throw IMessageRPCError.processExited }
                }
            }
            let fixture = checkpoints.count > 1 ? checkpoints.removeFirst() : checkpoints[0]
            let anchorField: String
            if !anchors.isEmpty, let matches = fixture.anchorMatches {
                anchorField = ",\"anchor_matches\":\(matches ? "true" : "false")"
            } else { anchorField = "" }
            result = """
                {"adapter_revision":2,"source_high_water":"\(fixture.highWater)","observed_at":"2026-11-04T00:00:00Z","chats":[{"chat_id":"42","guid":"iMessage;-;selected","service":"iMessage","available":true,"tail_rowid":"\(fixture.tailRow)","tail_guid":"\(fixture.tailGUID)","account_id":"database-only-id","account_login":"synthetic"\(anchorField)}]}
                """
        case "personastack.recent_messages":
            result = #"{"messages":[{"rowid":"80","guid":"synthetic-guid","chat_id":"42","text":"Synthetic test message","is_from_me":false,"date":"2026-11-04T00:00:00Z","sender":"synthetic","service":"iMessage","text_truncated":false,"attachment_count":0,"attachments":[]}],"truncated":false,"stop_reason":"caught_up"}"#
        case "personastack.send":
            guard request.params.expectedAccountID == "public-account" else { throw ProbeFailure.scopeMismatch }
            if let sendHold {
                await sendHold.started.release()
                await sendHold.wait.wait()
                guard !closed else { throw IMessageRPCError.processExited }
            }
            result = #"{"submitted":true,"transport":"applescript","service":"iMessage","chat_guid":"iMessage;-;selected"}"#
        default:
            throw ProbeFailure.actionNotAllowed
        }
        let frame = Data("{\"jsonrpc\":\"2.0\",\"id\":\"\(request.id)\",\"result\":\(result)}\n".utf8)
        if let reader {
            self.reader = nil
            reader.resume(returning: frame)
        } else {
            frames.append(frame)
        }
    }

    func terminate() async {
        terminateCount += 1
        closed = true
        frames.removeAll()
        reader?.resume(returning: Data())
        reader = nil
        await checkpointHold?.wait.release()
        await sendHold?.wait.release()
    }

    func holdCheckpoint(number: Int, started: CoreGate, wait: CoreGate) {
        checkpointHoldCountdown = number
        checkpointHold = (started, wait)
    }

    func holdSend(started: CoreGate, wait: CoreGate) { sendHold = (started, wait) }

    func isClosed() -> Bool { closed }
    func failNext(_ method: String) { failingMethod = method }
}

private actor CoreGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
    func isReleased() -> Bool { released }
}

private actor LiveAccountSequence {
    private var observations: [ProbeLiveAccount]
    init(_ observations: [ProbeLiveAccount]) { self.observations = observations }
    func observe(_ requestAutomation: Bool) -> ProbeLiveAccount {
        if observations.count > 1 { return observations.removeFirst() }
        return observations[0]
    }
    func replace(_ observation: ProbeLiveAccount) { observations = [observation] }
}

private func liveAccount(chatGUID: String = "iMessage;-;selected", generation: String = "source-1") -> ProbeLiveAccount {
    ProbeLiveAccount(accountID: "public-account", sourceGeneration: generation, liveChatGUID: chatGUID)
}

@Test func firstCheckpointIsOnlyMetadataBaseline() async throws {
    let transport = ScriptedProbeTransport()
    let client = IMessageRPCClient(transport: transport)
    let backend = CoreProbeBackend(client: client, target: backendTarget) { _ in liveAccount() }
    let probe = ProbeCoordinator(backend: backend, target: backendTarget)
    let evidence = await probe.checkPrerequisites()
    #expect(evidence.phase == .readyToRead)
    #expect(!evidence.observedCheckpointContinuityVerified)
    #expect(evidence.continuityScope == "same_probe_session")
    #expect(await transport.methods == ["personastack.initialize", "personastack.source_checkpoint"])
    #expect(await transport.checkpointAnchors == [[]])
    await client.stop()
}

@Test func sourceAccountIdentifierDoesNotHaveToEqualPublicLiveAccountIdentifier() async throws {
    let transport = ScriptedProbeTransport()
    let client = IMessageRPCClient(transport: transport)
    let backend = CoreProbeBackend(client: client, target: backendTarget) { _ in liveAccount() }
    _ = try await backend.readiness(requestAutomation: false)
    let result = try await backend.inspect(backendTarget)
    #expect(result.messagesObserved == 1)
    #expect(result.continuityVerified)
    #expect(await transport.methods == ["personastack.initialize", "personastack.source_checkpoint", "personastack.source_checkpoint", "personastack.recent_messages", "personastack.source_checkpoint"])
    let anchors = await transport.checkpointAnchors
    #expect(anchors.count == 3 && anchors[0].isEmpty)
    #expect(anchors[1] == [.init(chatID: "42", rowID: "80", guid: "synthetic-guid")])
    #expect(anchors[2] == anchors[1])
    await client.stop()
}

@Test func wrongLiveConversationStopsBeforeAnyMessageBodyRead() async throws {
    let transport = ScriptedProbeTransport()
    let client = IMessageRPCClient(transport: transport)
    let backend = CoreProbeBackend(client: client, target: backendTarget) { _ in liveAccount(chatGUID: "iMessage;-;different") }
    await #expect(throws: ProbeFailure.scopeMismatch) { _ = try await backend.readiness(requestAutomation: false) }
    #expect(await transport.methods == ["personastack.initialize", "personastack.source_checkpoint"])
    #expect(await transport.terminateCount == 1)
}

@Test func changedLiveConversationDuringCheckpointStopsBeforeAnyMessageBodyRead() async throws {
    let transport = ScriptedProbeTransport()
    let client = IMessageRPCClient(transport: transport)
    let live = LiveAccountSequence([liveAccount(), liveAccount(), liveAccount(chatGUID: "iMessage;-;different")])
    let backend = CoreProbeBackend(client: client, target: backendTarget) { request in await live.observe(request) }
    await #expect(throws: ProbeFailure.identityChanged) { _ = try await backend.readiness(requestAutomation: false) }
    #expect(await transport.methods == ["personastack.initialize", "personastack.source_checkpoint"])
    #expect(await transport.terminateCount == 1)
}

@Test func highWaterRollbackStopsBeforeAnyMessageBodyRead() async throws {
    let transport = ScriptedProbeTransport(checkpoints: [CheckpointFixture(), CheckpointFixture(highWater: "99")])
    let client = IMessageRPCClient(transport: transport)
    let backend = CoreProbeBackend(client: client, target: backendTarget) { _ in liveAccount() }
    _ = try await backend.readiness(requestAutomation: false)
    await #expect(throws: ProbeFailure.continuityUnavailable) { _ = try await backend.inspect(backendTarget) }
    #expect(await transport.methods == ["personastack.initialize", "personastack.source_checkpoint", "personastack.source_checkpoint"])
    #expect(await transport.terminateCount == 1)
}

@Test(arguments: [false, true]) func changedOrMissingAnchorStopsBeforeAnyMessageBodyRead(missing: Bool) async throws {
    let changed = CheckpointFixture(highWater: "101", tailRow: "81", tailGUID: "new-guid", anchorMatches: missing ? nil : false)
    let transport = ScriptedProbeTransport(checkpoints: [CheckpointFixture(), changed])
    let client = IMessageRPCClient(transport: transport)
    let backend = CoreProbeBackend(client: client, target: backendTarget) { _ in liveAccount() }
    _ = try await backend.readiness(requestAutomation: false)
    await #expect(throws: ProbeFailure.continuityUnavailable) { _ = try await backend.inspect(backendTarget) }
    #expect(await transport.methods.filter { $0 == "personastack.recent_messages" }.isEmpty)
    #expect(await transport.terminateCount == 1)
}

@Test func sourceGenerationChangeStopsOldProviderBeforeBodyRead() async throws {
    let transport = ScriptedProbeTransport()
    let client = IMessageRPCClient(transport: transport)
    let live = LiveAccountSequence([liveAccount()])
    let backend = CoreProbeBackend(client: client, target: backendTarget) { request in await live.observe(request) }
    _ = try await backend.readiness(requestAutomation: false)
    await live.replace(liveAccount(generation: "source-2"))
    await #expect(throws: ProbeFailure.identityChanged) { _ = try await backend.inspect(backendTarget) }
    #expect(await transport.methods == ["personastack.initialize", "personastack.source_checkpoint"])
    #expect(await transport.terminateCount == 1)
    await #expect(throws: ProbeFailure.identityChanged) { _ = try await backend.readiness(requestAutomation: false) }
    #expect(await transport.methods == ["personastack.initialize", "personastack.source_checkpoint"])
    #expect(await transport.launchCount == 1)
}

@Test(arguments: ["personastack.status", "personastack.recent_messages"])
func terminalProbeRPCFailureRequiresANewExplicitCheckAndPreservesCheckpoint(method: String) async throws {
    let transport = ScriptedProbeTransport()
    let client = IMessageRPCClient(transport: transport)
    let backend = CoreProbeBackend(client: client, target: backendTarget) { _ in liveAccount() }
    let probe = ProbeCoordinator(backend: backend, target: backendTarget)
    #expect(await probe.checkPrerequisites().phase == .readyToRead)
    await transport.failNext(method)
    #expect(await probe.readSelectedConversation().phase == .needsAttention)
    let failedMethods = await transport.methods
    #expect(failedMethods.last == method)
    #expect(await transport.launchCount == 1)
    #expect(await transport.terminateCount == 1)
    #expect(await transport.isClosed())
    #expect(!failedMethods.contains("personastack.send"))

    // This distinct user action is the first allowed fresh launch. It still
    // carries the prior exact source anchor rather than replacing the baseline.
    #expect(await probe.checkPrerequisites().phase == .readyToRead)
    #expect(await transport.launchCount == 2)
    let anchors = await transport.checkpointAnchors
    #expect(anchors.last == [.init(chatID: "42", rowID: "80", guid: "synthetic-guid")])
    let afterRetry = await transport.methods
    #expect(afterRetry.filter { $0 == "personastack.initialize" }.count == 2)
    #expect(afterRetry.filter { $0 == "personastack.recent_messages" }.count == (method == "personastack.recent_messages" ? 1 : 0))
    #expect(!afterRetry.contains("personastack.send"))
    #expect(await probe.readSelectedConversation().phase == .readyToSend)
    #expect(!(await transport.methods.contains("personastack.send")))
    _ = await probe.cancel()
}

@Test func terminalProbeSendFailureRemainsUnknownAndCannotReplayOrRelaunch() async throws {
    let transport = ScriptedProbeTransport()
    let client = IMessageRPCClient(transport: transport)
    let backend = CoreProbeBackend(client: client, target: backendTarget) { _ in liveAccount() }
    let probe = ProbeCoordinator(backend: backend, target: backendTarget)
    #expect(await probe.checkPrerequisites().phase == .readyToRead)
    #expect(await probe.readSelectedConversation().phase == .readyToSend)
    await transport.failNext("personastack.send")
    #expect(await probe.sendOneConfirmedTestMessage().phase == .outcomeUnknown)
    #expect(await transport.isClosed())
    #expect(await transport.terminateCount == 1)
    let afterFailure = await transport.methods
    #expect(afterFailure.filter { $0 == "personastack.send" }.count == 1)
    #expect(await probe.checkPrerequisites().phase == .outcomeUnknown)
    #expect(await probe.sendOneConfirmedTestMessage().phase == .outcomeUnknown)
    #expect(await transport.methods == afterFailure)
    #expect(await transport.launchCount == 1)
    _ = await probe.cancel()
}

@Test func coordinatorCancelDuringBackendPrechecksSendsNoMutationAndJoinsProviderCleanup() async throws {
    let transport = ScriptedProbeTransport()
    let client = IMessageRPCClient(transport: transport)
    let backend = CoreProbeBackend(client: client, target: backendTarget) { _ in liveAccount() }
    let probe = ProbeCoordinator(backend: backend, target: backendTarget)
    #expect(await probe.checkPrerequisites().phase == .readyToRead)
    #expect(await probe.readSelectedConversation().phase == .readyToSend)
    let started = CoreGate(), gate = CoreGate()
    // The first checkpoint belongs to send's readiness recheck. Hold the
    // second one inside backend.send, after the coordinator handed it intent.
    await transport.holdCheckpoint(number: 2, started: started, wait: gate)
    let sending = Task { await probe.sendOneConfirmedTestMessage() }
    await started.wait()
    #expect(await probe.cancel().phase == .cancelled)
    #expect(await sending.value.phase == .cancelled)
    #expect(await transport.methods.filter { $0 == "personastack.send" }.isEmpty)
    #expect(await transport.isClosed())
    #expect(await transport.terminateCount >= 1)
    _ = await probe.sendOneConfirmedTestMessage()
    #expect(await transport.methods.filter { $0 == "personastack.send" }.isEmpty)
}

@Test func coordinatorCancelAfterMutationDispatchReturnsUnknownAndJoinsProviderCleanup() async throws {
    let transport = ScriptedProbeTransport()
    let client = IMessageRPCClient(transport: transport)
    let backend = CoreProbeBackend(client: client, target: backendTarget) { _ in liveAccount() }
    let probe = ProbeCoordinator(backend: backend, target: backendTarget)
    #expect(await probe.checkPrerequisites().phase == .readyToRead)
    #expect(await probe.readSelectedConversation().phase == .readyToSend)
    let started = CoreGate(), gate = CoreGate()
    await transport.holdSend(started: started, wait: gate)
    let sending = Task { await probe.sendOneConfirmedTestMessage() }
    await started.wait()
    #expect(await probe.cancel().phase == .outcomeUnknown)
    #expect(await sending.value.phase == .outcomeUnknown)
    #expect(await transport.methods.filter { $0 == "personastack.send" }.count == 1)
    #expect(await transport.isClosed())
    #expect(await transport.terminateCount >= 1)
}

@Test func coordinatorCancelBeforeFirstLaunchRejectsLateAccountCallbackAndJoinsCleanup() async {
    let callbackStarted = CoreGate(), callbackGate = CoreGate()
    let callbackFinished = CoreGate()
    let cancellationFinished = CoreGate()
    let transport = ScriptedProbeTransport()
    let client = IMessageRPCClient(transport: transport)
    let backend = CoreProbeBackend(client: client, target: backendTarget) { _ in
        await callbackStarted.release()
        // Deliberately ignore cancellation to model a late system callback.
        await callbackGate.wait()
        await callbackFinished.release()
        return liveAccount()
    }
    let probe = ProbeCoordinator(backend: backend, target: backendTarget)
    let checking = Task { await probe.checkPrerequisites() }
    await callbackStarted.wait()
    let cancelling = Task {
        let evidence = await probe.cancel()
        let joinedCallback = await callbackFinished.isReleased()
        await cancellationFinished.release()
        return (evidence, joinedCallback)
    }
    let deadline = Date().addingTimeInterval(1)
    while await probe.snapshot().phase != .cancelled && Date() < deadline { await Task.yield() }
    #expect(await probe.snapshot().phase == .cancelled)
    // Public cancellation must still be joining the held operation, rather
    // than returning early and allowing its late callback to launch a child.
    #expect(!(await cancellationFinished.isReleased()))
    await callbackGate.release()
    let (cancelledEvidence, joinedCallback) = await cancelling.value
    #expect(cancelledEvidence.phase == .cancelled)
    #expect(joinedCallback)
    #expect(await checking.value.phase == .cancelled)
    #expect(await cancellationFinished.isReleased())
    #expect(await transport.launchCount == 0)
    #expect(await transport.readCount == 0)
    #expect(await transport.methods.isEmpty)
    #expect(await transport.terminateCount == 0)
}
#endif
