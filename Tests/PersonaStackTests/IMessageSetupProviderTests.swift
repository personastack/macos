import Foundation
import Testing
@testable import PersonaStackCore
@testable import PersonaStack

private actor SetupProviderAccountFixture: IMessageSetupAccountReading {
    private(set) var prepares = 0
    private(set) var clears = 0
    private(set) var currentReads = 0
    private(set) var selectedReads: [([String], String?, Bool)] = []
    private let selectedGate: SetupApprovalGate?
    private let selectedAccount: String
    private let selectedSource: String
    init(selectedAccount: String = "live-account", selectedSource: String = "native-source", selectedGate: SetupApprovalGate? = nil) {
        self.selectedAccount = selectedAccount; self.selectedSource = selectedSource; self.selectedGate = selectedGate
    }
    func prepareProviderConnection(_ client: IMessageRPCClient) async throws { prepares += 1; await client.stop() }
    func clearProviderBinding() async { clears += 1; await selectedGate?.release() }
    func validateProviderConnection() throws {}
    func observeCurrentAccount() throws -> IMessageCurrentAccountObservation {
        currentReads += 1
        return .init(accountID: "live-account", sourceGeneration: "native-source")
    }
    func observe(chatGUIDs: [String], expectedAccountID: String?, requestAutomation: Bool) async throws -> IMessageLiveAccountObservation {
        selectedReads.append((chatGUIDs, expectedAccountID, requestAutomation))
        await selectedGate?.pause()
        return .init(accountID: selectedAccount, sourceGeneration: selectedSource, chatGUIDs: chatGUIDs)
    }
}

private actor SetupApprovalGate {
    private var entered = false
    private var released = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        enteredWaiter?.resume(); enteredWaiter = nil
        if !released { await withCheckedContinuation { waiting = $0 } }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { enteredWaiter = $0 } }
    }
    func release() { released = true; waiting?.resume(); waiting = nil }
}

private actor SetupApprovalCurrent {
    private var current = true
    func validate(_ consent: IMessageSetupFinalConsent) -> Bool { current }
    func invalidate() { current = false }
}

private enum SetupApprovalCheckpointFault { case wrongGUID, reversed, unavailable, zeroTailGUID, missingTailGUID }

enum SetupProviderMetadataFault: Equatable, Sendable {
    case timeout, malformed, oversized, processExit
}

private actor SetupProviderTransportFixture: IMessageRPCTransport {
    private var bytes = Data()
    private var receiver: CheckedContinuation<Data, any Error>?
    private var exited = false
    private var metadataFailed = false
    private let metadataFault: SetupProviderMetadataFault?
    private let availableIDs: Set<String>
    private let metadataGate: SetupApprovalGate?
    private let checkpointGate: SetupApprovalGate?
    private let checkpointFault: SetupApprovalCheckpointFault?
    private(set) var checkpointChatIDs: [[String]] = []
    private(set) var checkpointAnchorCounts: [Int] = []
    private(set) var methods: [String] = []
    private(set) var launches = 0
    private(set) var terminations = 0
    let changedGUID: Bool
    let adapterRevision: Int
    init(changedGUID: Bool = false, adapterRevision: Int = 2, metadataFault: SetupProviderMetadataFault? = nil,
         availableIDs: Set<String> = ["42"], metadataGate: SetupApprovalGate? = nil,
         checkpointGate: SetupApprovalGate? = nil, checkpointFault: SetupApprovalCheckpointFault? = nil) {
        self.changedGUID = changedGUID; self.adapterRevision = adapterRevision; self.metadataFault = metadataFault
        self.availableIDs = availableIDs; self.metadataGate = metadataGate; self.checkpointGate = checkpointGate; self.checkpointFault = checkpointFault
    }
    func launch() { launches += 1; exited = false }
    func terminate() async {
        terminations += 1; exited = true; bytes.removeAll()
        receiver?.resume(returning: Data()); receiver = nil
        await metadataGate?.release(); await checkpointGate?.release()
    }
    func read(maximumBytes: Int) async throws -> Data {
        if exited { return Data() }
        if !bytes.isEmpty { let result = bytes.prefix(maximumBytes); bytes.removeFirst(result.count); return Data(result) }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func write(_ data: Data) async throws {
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let method = try #require(object["method"] as? String)
        let id = try #require(object["id"] as? String)
        methods.append(method)
        let result: [String: Any]
        switch method {
        case "personastack.initialize", "personastack.status":
            result = ["protocol_version": 1, "personastack_adapter_revision": adapterRevision,
                "database": ["ready": true], "methods": IMessageRPCMethod.allCases.map(\.rawValue)]
        case "personastack.chats.page":
            result = ["chats": [metadata("42")], "next_chat_rowid": "42", "upper_chat_rowid": "42", "has_more": false, "stop_reason": "caught_up"]
        case "personastack.chatMetadata":
            if let metadataFault, !metadataFailed {
                metadataFailed = true
                switch metadataFault {
                case .timeout: break
                case .malformed: emit(Data("{bad-json}\n".utf8))
                case .oversized: emit(Data(repeating: 0x78, count: IMessageRPCClient.maximumChatMetadataResultBytes + 512))
                case .processExit:
                    exited = true
                    receiver?.resume(returning: Data()); receiver = nil
                }
                return
            }
            let parameters = try #require(object["params"] as? [String: Any])
            let ids = try #require(parameters["chat_ids"] as? [String])
            await metadataGate?.pause()
            guard !exited else { throw IMessageRPCError.processExited }
            result = ["chats": ids.map { metadata($0) }]
        case "personastack.source_checkpoint":
            let parameters = try #require(object["params"] as? [String: Any])
            #expect(Set(parameters.keys) == ["chat_ids", "anchors"])
            let ids = try #require(parameters["chat_ids"] as? [String])
            let anchors = try #require(parameters["anchors"] as? [[String: String]])
            checkpointChatIDs.append(ids); checkpointAnchorCounts.append(anchors.count)
            await checkpointGate?.pause()
            guard !exited else { throw IMessageRPCError.processExited }
            var chats = ids.map { id -> [String: Any] in
                ["chat_id": id, "guid": checkpointFault == .wrongGUID ? "foreign" : guid(id), "service": "iMessage",
                 "available": checkpointFault != .unavailable, "tail_rowid": checkpointFault == .zeroTailGUID ? "0" : "9007199254740993",
                 "tail_guid": checkpointFault == .missingTailGUID ? "" : "private-tail", "account_id": "sqlite-hint", "anchor_matches": true]
            }
            if checkpointFault == .reversed { chats.reverse() }
            result = ["adapter_revision": 2, "source_high_water": "9223372036854775807", "observed_at": "2026-11-05T00:00:00.123456789Z", "chats": chats]
        default:
            Issue.record("Setup adapter requested a body, send or unknown provider operation")
            throw IMessageRPCError.invalidArguments
        }
        var response = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
        response.append(0x0a)
        emit(response)
    }
    private func emit(_ data: Data) {
        bytes.append(data)
        if let receiver {
            self.receiver = nil
            let chunk = bytes.prefix(8192)
            bytes.removeFirst(chunk.count)
            receiver.resume(returning: Data(chunk))
        }
    }
    private func metadata(_ id: String) -> [String: Any] {
        let available = availableIDs.contains(id)
        return ["id": id, "guid": available ? (changedGUID ? "replacement-guid" : guid(id)) : "",
            "name": available ? "Selected" : "", "service": available ? "iMessage" : "", "is_group": false,
            "available": available, "participants": available ? ["person@example.invalid"] : []]
    }
    private func guid(_ id: String) -> String { id == "42" ? "chosen-guid" : "chosen-guid-\(id)" }
}

private func setupProviderMetadata(_ id: Int64, available: Bool = true) throws -> IMessageConversation {
    .init(id: try IMessageRowID(id), guid: available ? (id == 42 ? "chosen-guid" : "chosen-guid-\(id)") : "", name: available ? "Selected" : "",
        service: available ? "iMessage" : "", isGroup: false, available: available,
        participants: available ? ["person@example.invalid"] : [], accountID: nil, accountLogin: nil)
}

@Test func iMessageSetupProviderUsesCurrentAccountForInventoryAndOneSelectedBatchForVerification() async throws {
    let accounts = SetupProviderAccountFixture()
    let transport = SetupProviderTransportFixture()
    let provider = IMessageSetupProvider(client: IMessageRPCClient(transport: transport), accounts: accounts)
    let deadline = Date().addingTimeInterval(10)
    let status = try await provider.prerequisites(deadline: deadline)
    #expect(status.protocolVersion == 1 && status.adapterRevision == 2 && status.databaseReady)
    #expect(await accounts.currentReads == 0)
    let page = try await provider.conversations(after: IMessageRowID(0), upper: nil, query: "", limit: 50, deadline: deadline)
    #expect(page.account == IMessageSetupAccount(accountID: "live-account", sourceGeneration: "native-source"))
    let verified = try await provider.verify(conversations: [setupProviderMetadata(42), setupProviderMetadata(43, available: false)],
        account: page.account, deadline: deadline)
    #expect(verified.conversations.map { $0.id.rawValue } == ["42", "43"])
    #expect(!verified.conversations[1].available)
    #expect(verified.liveAccount?.chatGUIDs == ["chosen-guid"])
    #expect(await accounts.currentReads == 1)
    let selected = await accounts.selectedReads
    #expect(selected.count == 1 && selected[0].0 == ["chosen-guid"])
    #expect(selected[0].1 == "live-account" && !selected[0].2)
    #expect(await accounts.prepares == 1)
    #expect(await transport.launches == 1)
    #expect(await transport.methods == ["personastack.initialize", "personastack.status", "personastack.chats.page", "personastack.status", "personastack.chatMetadata"])
    await provider.stop()
}

@Test func iMessageSetupProviderKeepsAllMissingSelectionsExplicitWithoutInventingAccountEvidence() async throws {
    let accounts = SetupProviderAccountFixture()
    let provider = IMessageSetupProvider(client: IMessageRPCClient(transport: SetupProviderTransportFixture()), accounts: accounts)
    let result = try await provider.verify(conversations: [setupProviderMetadata(43, available: false)],
        account: .init(accountID: "live-account", sourceGeneration: "native-source"), deadline: Date().addingTimeInterval(10))
    #expect(result.conversations.count == 1 && !result.conversations[0].available && result.liveAccount == nil)
    #expect(await accounts.currentReads == 0)
    #expect(await accounts.selectedReads.isEmpty)
    await provider.stop()
}

@Test func iMessageSetupProviderRejectsChangedNativeIdentityBeforeSelectedAccountObservation() async throws {
    let accounts = SetupProviderAccountFixture()
    let provider = IMessageSetupProvider(client: IMessageRPCClient(transport: SetupProviderTransportFixture(changedGUID: true)), accounts: accounts)
    await #expect(throws: IMessageSetupProviderError.accountChanged) {
        try await provider.verify(conversations: [setupProviderMetadata(42)],
            account: .init(accountID: "live-account", sourceGeneration: "native-source"), deadline: Date().addingTimeInterval(10))
    }
    #expect(await accounts.selectedReads.isEmpty)
    await provider.stop()
}

@Test func iMessageSetupProviderExpiredWorkHasNoProviderOrAccountSideEffects() async throws {
    let accounts = SetupProviderAccountFixture()
    let transport = SetupProviderTransportFixture()
    let provider = IMessageSetupProvider(client: IMessageRPCClient(transport: transport), accounts: accounts)
    await #expect(throws: IMessageSetupProviderError.providerTimeout) { try await provider.prerequisites(deadline: .distantPast) }
    #expect(await accounts.prepares == 0)
    #expect(await transport.launches == 0)
    #expect(await transport.methods.isEmpty)
    await provider.stop()
}

@Test func iMessageSetupProviderMapsWrongAdapterToFiniteSafeFailure() async throws {
    let provider = IMessageSetupProvider(client: IMessageRPCClient(transport: SetupProviderTransportFixture(adapterRevision: 1)), accounts: SetupProviderAccountFixture())
    await #expect(throws: IMessageSetupProviderError.dependencyInvalid) { try await provider.prerequisites(deadline: Date().addingTimeInterval(10)) }
    await provider.stop()
}


@Test(arguments: [SetupProviderMetadataFault.timeout, .malformed, .oversized, .processExit])
func iMessageSetupProviderTerminalMetadataFailureResetsBeforeTheNextExplicitRequest(fault: SetupProviderMetadataFault) async throws {
    let accounts = SetupProviderAccountFixture()
    let transport = SetupProviderTransportFixture(metadataFault: fault)
    let timeout: TimeInterval = fault == .timeout ? 0.2 : 2
    let client = IMessageRPCClient(transport: transport, readTimeoutSeconds: timeout, sendTimeoutSeconds: 45)
    let provider = IMessageSetupProvider(client: client, accounts: accounts)
    let expected: IMessageSetupProviderError
    switch fault {
    case .timeout: expected = .providerTimeout
    case .oversized: expected = .payloadTooLarge
    case .malformed, .processExit: expected = .dependencyInvalid
    }
    #expect(IMessageRPCClient.chatMetadataTimeoutSeconds < IMessageRuntime.commandLifetime)
    await #expect(throws: expected) {
        try await provider.verify(conversations: [setupProviderMetadata(42)],
            account: .init(accountID: "live-account", sourceGeneration: "native-source"),
            deadline: Date().addingTimeInterval(IMessageRuntime.commandLifetime))
    }
    // The first operation has returned only after native binding and child cleanup.
    #expect(await accounts.prepares == 1)
    #expect(await accounts.clears == 1)
    #expect(await accounts.selectedReads.isEmpty)
    #expect(await transport.launches == 1)
    #expect(await transport.terminations >= 1)
    #expect(await transport.methods == ["personastack.initialize", "personastack.chatMetadata"])

    // A new call represents separately authorized intent. The failed operation was not replayed.
    let recovered = try await provider.verify(conversations: [setupProviderMetadata(42)],
        account: .init(accountID: "live-account", sourceGeneration: "native-source"),
        deadline: Date().addingTimeInterval(IMessageRuntime.commandLifetime))
    #expect(recovered.liveAccount?.accountID == "live-account")
    #expect(recovered.liveAccount?.sourceGeneration == "native-source")
    #expect(recovered.liveAccount?.chatGUIDs == ["chosen-guid"])
    #expect(await accounts.prepares == 2)
    #expect(await accounts.clears == 1)
    #expect(await accounts.selectedReads.count == 1)
    #expect(await transport.launches == 2)
    #expect(await transport.methods == ["personastack.initialize", "personastack.chatMetadata",
        "personastack.initialize", "personastack.chatMetadata"])
    await provider.stop()
}

private func setupFinalApprovalConsent(_ ids: [Int64] = [42, 44], confirmedAt: Date = Date(), deadline: Date? = nil) throws -> IMessageSetupFinalConsent {
    let intent = IMessageRuntimeSetupIntent(localGeneration: UUID(), scope: .init(setupReferenceSHA256: String(repeating: "A", count: 43),
        generation: 3, workspaceID: "workspace", userID: "human", expiresAt: "2030-01-01T00:00:00Z", enabled: true))
    let rows = try ids.map { id in IMessageGatewaySetupConversation(conversationID: "option-\(id)", metadata: try setupProviderMetadata(id)) }
    return try .init(intent: intent, installationID: "installation", environmentIdentity: "app|gateway|mcp", conversations: rows,
        account: .init(accountID: "live-account", sourceGeneration: "native-source"), readEnabled: true, sendEnabled: true,
        selectionAndCapabilitiesConfirmed: true, confirmedAt: confirmedAt, deadline: deadline ?? confirmedAt.addingTimeInterval(10))
}

@Test func iMessageFinalApprovalRefreshesThirtyTwoSelectionsWithOneAccountProofAndExactCheckpoint() async throws {
    let ids = (42..<74).map(Int64.init)
    let consent = try setupFinalApprovalConsent(ids)
    let accounts = SetupProviderAccountFixture()
    let transport = SetupProviderTransportFixture(availableIDs: Set(ids.map(String.init)))
    let provider = IMessageSetupProvider(client: IMessageRPCClient(transport: transport), accounts: accounts)
    let current = SetupApprovalCurrent()
    let evidence = try await provider.approvalEvidence(for: consent, deadline: Date().addingTimeInterval(10)) { await current.validate($0) }
    #expect(evidence.verification.conversations.map(\.conversationID) == consent.conversations.map(\.conversationID))
    #expect(evidence.verification.conversations.map(\.metadata.id) == consent.conversations.map(\.metadata.id))
    #expect(evidence.verification.liveAccount?.sourceGeneration == "native-source")
    #expect(evidence.checkpoint.sourceHighWater.rawValue == "9223372036854775807")
    #expect(evidence.checkpoint.chats.allSatisfy { $0.tailRowID.rawValue == "9007199254740993" })
    #expect(evidence.readEnabled && evidence.sendEnabled)
    #expect(await accounts.currentReads == 0)
    let batches = await accounts.selectedReads
    #expect(batches.count == 1 && batches[0].0 == consent.conversations.map(\.metadata.guid))
    #expect(batches[0].1 == consent.account.accountID && !batches[0].2)
    #expect(await transport.checkpointChatIDs == [ids.map(String.init)])
    #expect(await transport.checkpointAnchorCounts == [0])
    #expect(await transport.methods == ["personastack.initialize", "personastack.chatMetadata", "personastack.source_checkpoint"])
    let encoded = String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self)
    #expect(!encoded.contains("anchor_matches") && !encoded.contains("sqlite-hint") && !encoded.contains("account_generation"))
    await provider.stop()
}

@Test func iMessageFinalApprovalRejectsWithdrawnIntentBeforeProviderAccess() async throws {
    let consent = try setupFinalApprovalConsent()
    let accounts = SetupProviderAccountFixture()
    let transport = SetupProviderTransportFixture(availableIDs: ["42", "44"])
    let provider = IMessageSetupProvider(client: IMessageRPCClient(transport: transport), accounts: accounts)
    await #expect(throws: IMessageSetupApprovalError.scopeChanged) {
        try await provider.approvalEvidence(for: consent, deadline: Date().addingTimeInterval(10)) { _ in false }
    }
    #expect(await transport.methods.isEmpty)
    #expect(await transport.launches == 0)
    #expect(await accounts.prepares == 0)
    #expect(await accounts.selectedReads.isEmpty)
}

@Test func iMessageFinalApprovalFencesChangedIntentAfterMetadataBeforeLiveAccount() async throws {
    let gate = SetupApprovalGate(), current = SetupApprovalCurrent()
    let consent = try setupFinalApprovalConsent()
    let accounts = SetupProviderAccountFixture()
    let transport = SetupProviderTransportFixture(availableIDs: ["42", "44"], metadataGate: gate)
    let provider = IMessageSetupProvider(client: IMessageRPCClient(transport: transport), accounts: accounts)
    let work = Task { try await provider.approvalEvidence(for: consent, deadline: Date().addingTimeInterval(10)) { await current.validate($0) } }
    await gate.waitUntilEntered()
    await current.invalidate()
    await gate.release()
    await #expect(throws: IMessageSetupApprovalError.scopeChanged) { try await work.value }
    #expect(await accounts.selectedReads.isEmpty)
    #expect(await transport.checkpointChatIDs.isEmpty)
    #expect(await transport.terminations == 1)
}

@Test func iMessageFinalApprovalFencesChangedIntentAfterAccountBeforeCheckpoint() async throws {
    let gate = SetupApprovalGate(), current = SetupApprovalCurrent()
    let consent = try setupFinalApprovalConsent()
    let accounts = SetupProviderAccountFixture(selectedGate: gate)
    let transport = SetupProviderTransportFixture(availableIDs: ["42", "44"])
    let provider = IMessageSetupProvider(client: IMessageRPCClient(transport: transport), accounts: accounts)
    let work = Task { try await provider.approvalEvidence(for: consent, deadline: Date().addingTimeInterval(10)) { await current.validate($0) } }
    await gate.waitUntilEntered()
    await current.invalidate()
    await gate.release()
    await #expect(throws: IMessageSetupApprovalError.scopeChanged) { try await work.value }
    #expect(await accounts.selectedReads.count == 1)
    #expect(await transport.checkpointChatIDs.isEmpty)
}

@Test func iMessageFinalApprovalProviderGenerationChangeCannotRestartTheStaleOperation() async throws {
    let gate = SetupApprovalGate()
    let consent = try setupFinalApprovalConsent()
    let accounts = SetupProviderAccountFixture()
    let transport = SetupProviderTransportFixture(availableIDs: ["42", "44"], metadataGate: gate)
    let provider = IMessageSetupProvider(client: IMessageRPCClient(transport: transport), accounts: accounts)
    let work = Task { try await provider.approvalEvidence(for: consent, deadline: Date().addingTimeInterval(10)) { _ in true } }
    await gate.waitUntilEntered()
    await provider.stop()
    await #expect(throws: (any Error).self) { try await work.value }
    #expect(await transport.launches == 1)
    #expect(await accounts.selectedReads.isEmpty)
    #expect(await transport.checkpointChatIDs.isEmpty)
}

@Test(arguments: [true, false])
func iMessageFinalApprovalAccountAndSourceMustMatchBeforeCheckpoint(accountChanged: Bool) async throws {
    let accounts = SetupProviderAccountFixture(selectedAccount: accountChanged ? "foreign" : "live-account",
        selectedSource: accountChanged ? "native-source" : "foreign-source")
    let transport = SetupProviderTransportFixture(availableIDs: ["42", "44"])
    let provider = IMessageSetupProvider(client: IMessageRPCClient(transport: transport), accounts: accounts)
    let consent = try setupFinalApprovalConsent()
    await #expect(throws: IMessageSetupProviderError.accountChanged) {
        try await provider.approvalEvidence(for: consent, deadline: Date().addingTimeInterval(10)) { _ in true }
    }
    #expect(await transport.checkpointChatIDs.isEmpty)
}

@Test func iMessageFinalApprovalPreservesUnavailableSelectionWithoutAccountOrCheckpointReads() async throws {
    let accounts = SetupProviderAccountFixture()
    let transport = SetupProviderTransportFixture()
    let provider = IMessageSetupProvider(client: IMessageRPCClient(transport: transport), accounts: accounts)
    let consent = try setupFinalApprovalConsent()
    await #expect(throws: IMessageSetupApprovalError.selectionUnavailable) {
        try await provider.approvalEvidence(for: consent, deadline: Date().addingTimeInterval(10)) { _ in true }
    }
    #expect(await accounts.selectedReads.isEmpty)
    #expect(await transport.checkpointChatIDs.isEmpty)
}

@Test(arguments: [SetupApprovalCheckpointFault.wrongGUID, .reversed, .unavailable, .zeroTailGUID, .missingTailGUID])
private func iMessageFinalApprovalRejectsNoncorrelatedCheckpoint(fault: SetupApprovalCheckpointFault) async throws {
    let transport = SetupProviderTransportFixture(availableIDs: ["42", "44"], checkpointFault: fault)
    let provider = IMessageSetupProvider(client: IMessageRPCClient(transport: transport), accounts: SetupProviderAccountFixture())
    let consent = try setupFinalApprovalConsent()
    await #expect(throws: IMessageSetupApprovalError.invalidEvidence) {
        try await provider.approvalEvidence(for: consent, deadline: Date().addingTimeInterval(10)) { _ in true }
    }
    #expect(await transport.methods == ["personastack.initialize", "personastack.chatMetadata", "personastack.source_checkpoint"])
}

@Test func iMessageFinalApprovalOriginalDeadlineStopsHeldCheckpointWithoutSliding() async throws {
    let gate = SetupApprovalGate()
    let now = Date()
    let consent = try setupFinalApprovalConsent(confirmedAt: now.addingTimeInterval(-9.7), deadline: now.addingTimeInterval(100))
    let transport = SetupProviderTransportFixture(availableIDs: ["42", "44"], checkpointGate: gate)
    let provider = IMessageSetupProvider(client: IMessageRPCClient(transport: transport), accounts: SetupProviderAccountFixture())
    let start = ContinuousClock.now
    await #expect(throws: IMessageSetupProviderError.providerTimeout) {
        try await provider.approvalEvidence(for: consent, deadline: now.addingTimeInterval(100)) { _ in true }
    }
    #expect(ContinuousClock.now - start < .seconds(2))
    #expect(await transport.checkpointChatIDs == [["42", "44"]])
    #expect(await transport.terminations == 1)
}

@Test func iMessageFinalApprovalCancellationJoinsCheckpointAndNeverReturnsLateEvidence() async throws {
    let gate = SetupApprovalGate()
    let consent = try setupFinalApprovalConsent()
    let transport = SetupProviderTransportFixture(availableIDs: ["42", "44"], checkpointGate: gate)
    let accounts = SetupProviderAccountFixture()
    let provider = IMessageSetupProvider(client: IMessageRPCClient(transport: transport), accounts: accounts)
    let work = Task { try await provider.approvalEvidence(for: consent, deadline: Date().addingTimeInterval(10)) { _ in true } }
    await gate.waitUntilEntered()
    work.cancel()
    await #expect(throws: CancellationError.self) { try await work.value }
    #expect(await transport.terminations == 1)
    #expect(await accounts.clears == 1)
}
