import Foundation
import Testing
@testable import PersonaStackCore
@testable import PersonaStack

private actor SetupProviderAccountFixture: IMessageSetupAccountReading {
    private(set) var prepares = 0
    private(set) var clears = 0
    private(set) var currentReads = 0
    private(set) var selectedReads: [([String], String?, Bool)] = []
    func prepareProviderConnection(_ client: IMessageRPCClient) async throws { prepares += 1; await client.stop() }
    func clearProviderBinding() { clears += 1 }
    func validateProviderConnection() throws {}
    func observeCurrentAccount() throws -> IMessageCurrentAccountObservation {
        currentReads += 1
        return .init(accountID: "live-account", sourceGeneration: "native-source")
    }
    func observe(chatGUIDs: [String], expectedAccountID: String?, requestAutomation: Bool) throws -> IMessageLiveAccountObservation {
        selectedReads.append((chatGUIDs, expectedAccountID, requestAutomation))
        return .init(accountID: "live-account", sourceGeneration: "native-source", chatGUIDs: chatGUIDs)
    }
}

enum SetupProviderMetadataFault: Equatable, Sendable {
    case timeout, malformed, oversized, processExit
}

private actor SetupProviderTransportFixture: IMessageRPCTransport {
    private var bytes = Data()
    private var receiver: CheckedContinuation<Data, any Error>?
    private var exited = false
    private var metadataFailed = false
    private let metadataFault: SetupProviderMetadataFault?
    private(set) var methods: [String] = []
    private(set) var launches = 0
    private(set) var terminations = 0
    let changedGUID: Bool
    let adapterRevision: Int
    init(changedGUID: Bool = false, adapterRevision: Int = 2, metadataFault: SetupProviderMetadataFault? = nil) {
        self.changedGUID = changedGUID; self.adapterRevision = adapterRevision; self.metadataFault = metadataFault
    }
    func launch() { launches += 1; exited = false }
    func terminate() {
        terminations += 1; exited = true; bytes.removeAll()
        receiver?.resume(returning: Data()); receiver = nil
    }
    func read(maximumBytes: Int) async throws -> Data {
        if exited { return Data() }
        if !bytes.isEmpty { let result = bytes.prefix(maximumBytes); bytes.removeFirst(result.count); return Data(result) }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func write(_ data: Data) throws {
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
            result = ["chats": ids.map { metadata($0) }]
        default:
            Issue.record("Setup adapter requested a body, send, checkpoint or unknown provider operation")
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
        let available = id == "42"
        return ["id": id, "guid": available ? (changedGUID ? "replacement-guid" : "chosen-guid") : "",
            "name": available ? "Selected" : "", "service": available ? "iMessage" : "", "is_group": false,
            "available": available, "participants": available ? ["person@example.invalid"] : []]
    }
}

private func setupProviderMetadata(_ id: Int64, available: Bool = true) throws -> IMessageConversation {
    .init(id: try IMessageRowID(id), guid: available ? "chosen-guid" : "", name: available ? "Selected" : "",
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
