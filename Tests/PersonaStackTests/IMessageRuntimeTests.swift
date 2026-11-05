import Foundation
import Testing
@testable import PersonaStackCore

private final class IMessageRuntimeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    private var sequence = 0
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
    func identifier() -> String { lock.withLock { sequence += 1; return "option-\(sequence)" } }
}

private actor IMessageRuntimeReplies {
    private var replies: [String: IMessageGatewayPayload] = [:]
    private(set) var order: [String] = []
    private var waiters: [String: CheckedContinuation<IMessageGatewayPayload, Never>] = [:]
    func put(_ value: IMessageGatewayPayload, id: String) {
        replies[id] = value
        order.append(id)
        waiters.removeValue(forKey: id)?.resume(returning: value)
    }
    func get(_ id: String) async -> IMessageGatewayPayload {
        if let value = replies[id] { return value }
        return await withCheckedContinuation { waiters[id] = $0 }
    }
    func contains(_ id: String) -> Bool { replies[id] != nil }
}

private actor IMessageRuntimeProvider: IMessageSetupProviding {
    enum Call: Equatable { case prerequisites, page(String, String?, String, Int), verify([String]), restore([String]) }
    private(set) var calls: [Call] = []
    private(set) var stops = 0
    private var pages: [IMessageSetupProviderPage] = []
    private var held = false
    private var pending: CheckedContinuation<Void, any Error>?
    private var entered: CheckedContinuation<Void, Never>?
    private var verified: IMessageSetupProviderVerification?
    func hold() { held = true }
    func waitUntilHeld() async {
        if pending != nil { return }
        await withCheckedContinuation { entered = $0 }
    }
    func release() { held = false; pending?.resume(); pending = nil }
    func supply(_ value: IMessageSetupProviderPage) { pages.append(value) }
    func supplyVerification(_ value: IMessageSetupProviderVerification) { verified = value }
    func prerequisites(deadline: Date) async throws -> IMessageGatewayPrerequisitesResult {
        calls.append(.prerequisites)
        if held {
            try await withCheckedThrowingContinuation {
                pending = $0; entered?.resume(); entered = nil
            }
        }
        try Task.checkCancellation()
        return .init(databaseReady: true)
    }
    func conversations(after: IMessageRowID, upper: IMessageRowID?, query: String, limit: Int,
                       deadline: Date) async throws -> IMessageSetupProviderPage {
        calls.append(.page(after.rawValue, upper?.rawValue, query, limit))
        guard !pages.isEmpty else { Issue.record("Unplanned provider page"); throw IMessageSetupProviderError.dependencyInvalid }
        return pages.removeFirst()
    }
    func verify(conversations: [IMessageConversation], account: IMessageSetupAccount,
                deadline: Date) async throws -> IMessageSetupProviderVerification {
        calls.append(.verify(conversations.map { $0.id.rawValue }))
        #expect(account == IMessageSetupAccount(accountID: "account", sourceGeneration: "source"))
        guard let verified else { Issue.record("Unplanned provider verification"); throw IMessageSetupProviderError.dependencyInvalid }
        return verified
    }
    func restore(selections: [IMessageSetupDraft.Selection], account: IMessageSetupAccount,
                 deadline: Date) async throws -> IMessageSetupProviderVerification {
        calls.append(.restore(selections.map(\.nativeChatRowID)))
        if held {
            try await withCheckedThrowingContinuation {
                pending = $0; entered?.resume(); entered = nil
            }
        }
        try Task.checkCancellation()
        guard let verified else { throw IMessageSetupProviderError.dependencyInvalid }
        return verified
    }

    func stop() {
        stops += 1
        pending?.resume(throwing: CancellationError()); pending = nil
    }
}

private func runtimeUTC(_ value: Date) -> String {
    ISO8601DateFormatter().string(from: value)
}

private struct IMessageRuntimeFixture {
    let clock = IMessageRuntimeClock()
    let provider = IMessageRuntimeProvider()
    let replies = IMessageRuntimeReplies()
    let connectionID = UUID()
    let runtime: IMessageRuntime
    let intent: IMessageRuntimeSetupIntent
    let reference = String(repeating: "A", count: 43)
    init(longIDs: Bool = false) {
        let digest = String(repeating: "C", count: 42) + "A"
        let scope = IMessageGatewaySetupScope(setupReferenceSHA256: digest, generation: 1,
            workspaceID: "workspace", userID: "human", expiresAt: runtimeUTC(clock.now().addingTimeInterval(3600)), enabled: true)
        intent = .init(localGeneration: UUID(), scope: scope)
        let clock = clock
        runtime = IMessageRuntime(installationID: "mac", provider: provider,
            referenceDigest: { $0 == String(repeating: "A", count: 43) ? digest : "invalid" },
            now: { clock.now() }, makeID: { (longIDs ? String(repeating: "x", count: 240) : "") + clock.identifier() })
    }
    func activate(consent: Bool = true) async throws {
        await runtime.bind(connectionID: connectionID)
        try await runtime.activateLocalSetup(intent)
        try await runtime.setMetadataConsent(consent, for: intent)
        #expect(await runtime.install(snapshot(), connectionID: connectionID) == .snapshotAck(.init(revision: 1)))
    }
    func snapshot(_ revision: Int64 = 1, enabled: Bool = true) -> IMessageGatewaySnapshot {
        let scope = intent.scope
        return .init(installationID: "mac", revision: revision, setupScope: .init(
            setupReferenceSHA256: scope.setupReferenceSHA256, generation: scope.generation,
            workspaceID: scope.workspaceID, userID: scope.userID, expiresAt: scope.expiresAt, enabled: enabled))
    }
    func command(_ id: String, revision: Int64 = 1, input: IMessageGatewayCommandInput = .prerequisites) -> IMessageGatewayCommand {
        .init(requestID: id, authorizationID: "authorization-\(id)", deadlineAt: runtimeUTC(clock.now().addingTimeInterval(100)),
            target: .init(installationID: "mac", workspaceID: "workspace", snapshotRevision: revision),
            caller: .init(setupSession: .init(userID: "human", setupReference: reference, setupGeneration: 1)), input: input)
    }
    func enqueue(_ command: IMessageGatewayCommand) async -> IMessageGatewayFailure? {
        let replies = replies
        return await runtime.admit(command, connectionID: connectionID) { await replies.put($0, id: command.requestID) }
    }
    func dispatch(_ command: IMessageGatewayCommand) async -> IMessageGatewayPayload {
        if let failure = await enqueue(command) { return .failure(failure) }
        return await replies.get(command.requestID)
    }
    func stop() async { await runtime.unbind(connectionID: connectionID) }
}

private func runtimeMetadata(_ id: Int64, name: String? = nil, available: Bool = true) throws -> IMessageConversation {
    .init(id: try IMessageRowID(id), guid: available ? "guid-\(id)" : "", name: available ? (name ?? "Chat \(id)") : "",
          service: available ? "iMessage" : "", isGroup: false, available: available,
          participants: available ? ["person-\(id)"] : [], accountID: nil, accountLogin: nil)
}

private func runtimePage(_ rows: [IMessageConversation], next: Int64, upper: Int64 = 2000,
                         more: Bool = true) throws -> IMessageSetupProviderPage {
    .init(page: .init(chats: rows, nextChatRowID: try IMessageRowID(next), upperChatRowID: try IMessageRowID(upper),
                     hasMore: more, stopReason: more ? .scanLimit : .caughtUp),
          account: .init(accountID: "account", sourceGeneration: "source"))
}

private func runtimePageResult(_ payload: IMessageGatewayPayload) throws -> IMessageGatewayConversationsPageResult {
    guard case .result(.conversationsPage(let result)) = payload else { Issue.record("Expected picker page"); throw IMessageSetupProviderError.dependencyInvalid }
    return result
}

@Test func iMessageRuntimeDefaultsToNoLocalAuthorityAndConsentNeverComesFromSnapshot() async throws {
    let fixture = IMessageRuntimeFixture()
    await fixture.runtime.bind(connectionID: fixture.connectionID)
    #expect(await fixture.runtime.install(fixture.snapshot(), connectionID: fixture.connectionID) != .snapshotAck(.init(revision: 1)))
    #expect(await fixture.enqueue(fixture.command("denied"))?.code == .scopeDenied)
    #expect(await fixture.provider.calls.isEmpty)
    try await fixture.activate(consent: false)
    #expect(await fixture.enqueue(fixture.command("inventory", input: .setupConversations(.init())))?.code == .scopeDenied)
    guard case .result(.prerequisites(let status)) = await fixture.dispatch(fixture.command("status")) else { Issue.record("Expected provider status"); return }
    #expect(status.protocolVersion == 1 && status.adapterRevision == 2 && status.databaseReady)
    #expect(await fixture.provider.calls == [.prerequisites])
    await fixture.stop()
}

@Test func iMessageRuntimeKeepsEightWaitersAndCountsQueueTimeInOriginalDeadline() async throws {
    let fixture = IMessageRuntimeFixture()
    try await fixture.activate()
    await fixture.provider.hold()
    #expect(await fixture.enqueue(fixture.command("active")) == nil)
    await fixture.provider.waitUntilHeld()
    for index in 0..<8 { #expect(await fixture.enqueue(fixture.command("queued-\(index)")) == nil) }
    #expect(await fixture.enqueue(fixture.command("overflow"))?.code == .busy)
    fixture.clock.advance(11)
    await fixture.runtime.reconcileDeadlines()
    for id in ["active"] + (0..<8).map({ "queued-\($0)" }) {
        guard case .failure(let failure) = await fixture.replies.get(id) else { Issue.record("Expired read succeeded"); continue }
        #expect(failure.code == .providerTimeout && failure.retrySafe)
    }
    #expect(await fixture.provider.calls == [.prerequisites])
    await fixture.stop()
}

@Test func iMessageRuntimeUnchangedNewRevisionDoesNotCancelAdmittedJob() async throws {
    let fixture = IMessageRuntimeFixture()
    try await fixture.activate()
    await fixture.provider.hold()
    #expect(await fixture.enqueue(fixture.command("original")) == nil)
    await fixture.provider.waitUntilHeld()
    #expect(await fixture.runtime.install(fixture.snapshot(2), connectionID: fixture.connectionID) == .snapshotAck(.init(revision: 2)))
    await fixture.provider.release()
    guard case .result(.prerequisites) = await fixture.replies.get("original") else { Issue.record("Unchanged scope cancelled a job"); return }
    await fixture.stop()
}

@Test func iMessageRuntimeRestrictiveCutoffRejectsOldSnapshotAndLocalWithdrawalCancelsQueuedJobs() async throws {
    let fixture = IMessageRuntimeFixture()
    try await fixture.activate()
    #expect(await fixture.runtime.install(fixture.snapshot(2, enabled: false), connectionID: fixture.connectionID) == .snapshotAck(.init(revision: 2)))
    guard case .failure(let stale) = await fixture.runtime.install(fixture.snapshot(), connectionID: fixture.connectionID) else { Issue.record("Old snapshot passed cutoff"); return }
    #expect(stale.code == .scopeDenied)
    #expect(await fixture.runtime.install(fixture.snapshot(3), connectionID: fixture.connectionID) == .snapshotAck(.init(revision: 3)))
    await fixture.provider.hold()
    #expect(await fixture.enqueue(fixture.command("active", revision: 3)) == nil)
    await fixture.provider.waitUntilHeld()
    #expect(await fixture.enqueue(fixture.command("waiting", revision: 3)) == nil)
    await fixture.runtime.withdrawLocalSetup(fixture.intent)
    for id in ["active", "waiting"] {
        guard case .failure(let error) = await fixture.replies.get(id) else { Issue.record("Withdrawn scope completed"); continue }
        #expect(error.code == .scopeDenied)
    }
    #expect(await fixture.provider.calls == [.prerequisites])
    await fixture.stop()
}

@Test func iMessageRuntimeSourceWidePagesKeepSelectedRowsAfterTwoPageEvictionAndVerifyExactly() async throws {
    let fixture = IMessageRuntimeFixture()
    try await fixture.activate()
    await fixture.provider.supply(try runtimePage([runtimeMetadata(1)], next: 1001))
    let first = try runtimePageResult(await fixture.dispatch(fixture.command("page-1", input: .setupConversations(.init(query: "person")))))
    let chosen = first.conversations[0].conversationID
    try await fixture.runtime.setSelectedConversationIDs([chosen], for: fixture.intent)
    var previous = first
    for row in [1002, 1003, 1004] {
        await fixture.provider.supply(try runtimePage([runtimeMetadata(Int64(row))], next: Int64(row)))
        previous = try runtimePageResult(await fixture.dispatch(fixture.command("page-\(row)", input: .setupConversations(
            .init(query: "person", snapshotToken: first.snapshotToken, pageToken: previous.nextPageToken)))))
    }
    #expect(await fixture.runtime.selectedConversationIDs(for: fixture.intent) == [chosen])
    let unavailable = try runtimeMetadata(1, available: false)
    await fixture.provider.supplyVerification(.init(conversations: [unavailable], liveAccount: nil))
    guard case .result(.verification(let result)) = await fixture.dispatch(fixture.command("verify", input: .verifyConversations(.init(conversationIDs: [chosen])))) else {
        Issue.record("Missing exact verification"); return
    }
    #expect(result.conversations.map(\.conversationID) == [chosen])
    #expect(!result.conversations[0].metadata.available && result.liveAccount == nil)
    #expect(await fixture.enqueue(fixture.command("foreign", input: .verifyConversations(.init(conversationIDs: ["foreign"])) )) == nil)
    guard case .failure(let denied) = await fixture.replies.get("foreign") else { Issue.record("Unknown selection accepted"); return }
    #expect(denied.code == .invalidArguments)
    #expect(await fixture.provider.calls.last == .verify(["1"]))
    await fixture.stop()
}

@Test func iMessageRuntimeInventoryExpiryNeverSlidesAndReappearingSelectedRowKeepsItsID() async throws {
    let fixture = IMessageRuntimeFixture()
    try await fixture.activate()
    let row = try runtimeMetadata(1)
    await fixture.provider.supply(try runtimePage([row], next: 1, upper: 1, more: false))
    let first = try runtimePageResult(await fixture.dispatch(fixture.command("first", input: .setupConversations(.init()))))
    try await fixture.runtime.setSelectedConversationIDs([first.conversations[0].conversationID], for: fixture.intent)
    fixture.clock.advance(250)
    await fixture.provider.supply(try runtimePage([row], next: 1, upper: 1, more: false))
    let refreshed = try runtimePageResult(await fixture.dispatch(fixture.command("refresh", input: .setupConversations(.init(query: "new")))))
    #expect(refreshed.conversations[0].conversationID == first.conversations[0].conversationID)
    fixture.clock.advance(51)
    guard case .failure(let expired) = await fixture.dispatch(fixture.command("expired", input: .verifyConversations(.init(conversationIDs: [first.conversations[0].conversationID])))) else {
        Issue.record("Selection expiry renewed"); return
    }
    #expect(expired.code == .invalidArguments)
    await fixture.stop()
}

@Test func iMessageRuntimeEmptyFilteredPageKeepsActualScanCursorAndAccountChangeFailsClosed() async throws {
    let fixture = IMessageRuntimeFixture()
    try await fixture.activate()
    await fixture.provider.supply(try runtimePage([], next: 512))
    let first = try runtimePageResult(await fixture.dispatch(fixture.command("empty", input: .setupConversations(.init()))))
    #expect(first.conversations.isEmpty && first.nextChatRowID.rawValue == "512" && first.hasMore)
    let page = try runtimePage([runtimeMetadata(513)], next: 513)
    await fixture.provider.supply(.init(page: page.page, account: .init(accountID: "changed", sourceGeneration: "source")))
    guard case .failure(let changed) = await fixture.dispatch(fixture.command("changed", input: .setupConversations(
        .init(snapshotToken: first.snapshotToken, pageToken: first.nextPageToken)))) else { Issue.record("Changed account admitted"); return }
    #expect(changed.code == .accountChanged)
    await fixture.stop()
}

@Test func iMessageRuntimeConnectionReplacementFencesOldResultWithoutReplay() async throws {
    let fixture = IMessageRuntimeFixture()
    try await fixture.activate()
    await fixture.provider.hold()
    #expect(await fixture.enqueue(fixture.command("retired")) == nil)
    await fixture.provider.waitUntilHeld()
    #expect(await fixture.runtime.install(fixture.snapshot(2), connectionID: fixture.connectionID) == .snapshotAck(.init(revision: 2)))
    let replacement = UUID()
    await fixture.runtime.bind(connectionID: replacement)
    #expect(await fixture.runtime.install(fixture.snapshot(), connectionID: replacement) == .snapshotAck(.init(revision: 1)))
    #expect(await fixture.enqueue(fixture.command("old-connection"))?.code == .scopeDenied)
    await fixture.provider.release()
    let replies = fixture.replies
    #expect(await fixture.runtime.admit(fixture.command("fresh"), connectionID: replacement) { await replies.put($0, id: "fresh") } == nil)
    guard case .result(.prerequisites) = await replies.get("fresh") else { Issue.record("Fresh connection failed"); return }
    #expect(!(await replies.contains("retired")))
    #expect(await fixture.provider.calls == [.prerequisites, .prerequisites])
    await fixture.runtime.unbind(connectionID: replacement)
}

@Test func iMessageRuntimeFIFOCompletesInAdmissionOrderWithoutConcurrentProviderReads() async throws {
    let fixture = IMessageRuntimeFixture()
    try await fixture.activate()
    await fixture.provider.hold()
    #expect(await fixture.enqueue(fixture.command("first")) == nil)
    await fixture.provider.waitUntilHeld()
    #expect(await fixture.enqueue(fixture.command("second")) == nil)
    #expect(await fixture.enqueue(fixture.command("third")) == nil)
    await fixture.provider.release()
    _ = await fixture.replies.get("third")
    #expect(await fixture.replies.order == ["first", "second", "third"])
    #expect(await fixture.provider.calls.count == 3)
    await fixture.stop()
}

@Test func iMessageRuntimeWrappingReturnsBoundedPrefixAndNeverSkipsOmittedOptions() async throws {
    let fixture = IMessageRuntimeFixture(longIDs: true)
    try await fixture.activate()
    let rows = try (1...40).map { id in
        IMessageConversation(id: try IMessageRowID(Int64(id)), guid: "guid-\(id)", name: "Chat \(id)",
            service: "iMessage", isGroup: true, available: true,
            participants: Array(repeating: String(repeating: "x", count: 256), count: 100), accountID: nil, accountLogin: nil)
    }
    #expect(try JSONEncoder().encode(rows).count + 256 < IMessageGatewayWire.maximumResultBytes)
    await fixture.provider.supply(try runtimePage(rows, next: 40, upper: 40, more: false))
    let first = try runtimePageResult(await fixture.dispatch(fixture.command("large", input: .setupConversations(.init()))))
    #expect(!first.conversations.isEmpty && first.conversations.count < rows.count)
    #expect(first.hasMore && first.stopReason == .outputLimit)
    #expect(first.nextChatRowID == first.conversations.last?.metadata.id)
    #expect(first.nextChatRowID.value < 40)
    #expect(try JSONEncoder().encode(IMessageGatewaySetupResult.conversationsPage(first)).count <= IMessageGatewayWire.maximumResultBytes)
    let remaining = rows.filter { $0.id > first.nextChatRowID }
    await fixture.provider.supply(try runtimePage(remaining, next: 40, upper: 40, more: false))
    let last = try runtimePageResult(await fixture.dispatch(fixture.command("remaining", input: .setupConversations(
        .init(snapshotToken: first.snapshotToken, pageToken: first.nextPageToken)))))
    #expect(first.conversations.map { $0.metadata.id } + last.conversations.map { $0.metadata.id } == rows.map(\.id))
    #expect(!last.hasMore)
    await fixture.stop()
}

@Test(arguments: ["account", "source", "guid"])
func iMessageRuntimeVerificationCannotSubstituteLiveAccountSourceOrSelectedIdentity(change: String) async throws {
    let fixture = IMessageRuntimeFixture()
    try await fixture.activate()
    let original = try runtimeMetadata(1)
    await fixture.provider.supply(try runtimePage([original], next: 1, upper: 1, more: false))
    let page = try runtimePageResult(await fixture.dispatch(fixture.command("page", input: .setupConversations(.init()))))
    let id = page.conversations[0].conversationID
    try await fixture.runtime.setSelectedConversationIDs([id], for: fixture.intent)
    let row = change == "guid" ? IMessageConversation(id: original.id, guid: "substitute-guid", name: original.name,
        service: original.service, isGroup: original.isGroup, available: true, participants: original.participants,
        accountID: nil, accountLogin: nil) : original
    await fixture.provider.supplyVerification(.init(conversations: [row], liveAccount: .init(
        accountID: change == "account" ? "foreign-account" : "account",
        sourceGeneration: change == "source" ? "foreign-source" : "source", chatGUIDs: [row.guid])))
    guard case .failure(let failure) = await fixture.dispatch(fixture.command("verify", input: .verifyConversations(.init(conversationIDs: [id])))) else {
        Issue.record("Substituted proof accepted"); return
    }
    #expect(failure.code == .accountChanged)
    #expect(await fixture.enqueue(fixture.command("blocked"))?.code == .scopeDenied)
    #expect(await fixture.runtime.selectedConversationIDs(for: fixture.intent).isEmpty)
    await fixture.stop()
}


@Test func iMessageRuntimeRetainsOnlyNativeSelectionAcrossReconnectWithoutRenewingExpiry() async throws {
    let fixture = IMessageRuntimeFixture()
    try await fixture.activate()
    await fixture.provider.supply(try runtimePage([runtimeMetadata(1), runtimeMetadata(2)], next: 2))
    let page = try runtimePageResult(await fixture.dispatch(fixture.command("page", input: .setupConversations(.init()))))
    try await fixture.runtime.setSelectedConversationIDs(Array(page.conversations.map(\.conversationID).reversed()), for: fixture.intent)
    let before = try await fixture.runtime.retainedSelection(for: fixture.intent)
    await fixture.runtime.unbindAndDrain(connectionID: fixture.connectionID)
    let replacement = UUID()
    await fixture.runtime.bind(connectionID: replacement)
    let retained = try await fixture.runtime.retainedSelection(for: fixture.intent)
    #expect(retained.conversations == before.conversations)
    #expect(retained.expiresAt == before.expiresAt)
    #expect(retained.account == before.account)
    fixture.clock.advance(301)
    await #expect(throws: (any Error).self) { try await fixture.runtime.retainedSelection(for: fixture.intent) }
    await fixture.runtime.drain()
}

@Test func iMessageRuntimeDraftRestorationRequiresFreshConsentAndMintsNewOpaqueIDs() async throws {
    let fixture = IMessageRuntimeFixture()
    let choices = try [IMessageSetupDraft.Selection(nativeChatRowID: "2", expectedGUID: "guid-2"),
                       IMessageSetupDraft.Selection(nativeChatRowID: "1", expectedGUID: "guid-1")]
    let account = IMessageSetupAccount(accountID: "account", sourceGeneration: "source")
    await #expect(throws: (any Error).self) {
        try await fixture.runtime.restoreSelection(choices, account: account, originalExpiresAt: fixture.clock.now().addingTimeInterval(90), for: fixture.intent)
    }
    #expect(await fixture.provider.calls.isEmpty)
    try await fixture.activate()
    await fixture.provider.supplyVerification(.init(conversations: [try runtimeMetadata(2), try runtimeMetadata(1)],
        liveAccount: .init(accountID: "account", sourceGeneration: "source", chatGUIDs: ["guid-2", "guid-1"])))
    let expiry = fixture.clock.now().addingTimeInterval(90)
    let restored = try await fixture.runtime.restoreSelection(choices, account: account, originalExpiresAt: expiry, for: fixture.intent)
    #expect(restored.conversations.map { $0.metadata.id.rawValue } == ["2", "1"])
    #expect(restored.conversations.map(\.conversationID) == ["option-1", "option-2"])
    #expect(restored.expiresAt == expiry)
    #expect(await fixture.provider.calls == [.restore(["2", "1"])])
    await fixture.runtime.drain()
}

@Test(arguments: ["account", "source", "guid", "unavailable"])
func iMessageRuntimeRestorationRejectsChangedEvidenceWithoutRetainingAuthority(fault: String) async throws {
    let fixture = IMessageRuntimeFixture()
    try await fixture.activate()
    let choice = try IMessageSetupDraft.Selection(nativeChatRowID: "1", expectedGUID: "guid-1")
    await fixture.provider.supplyVerification(.init(conversations: [try runtimeMetadata(fault == "guid" ? 2 : 1, available: fault != "unavailable")],
        liveAccount: .init(accountID: fault == "account" ? "other" : "account", sourceGeneration: fault == "source" ? "other" : "source", chatGUIDs: ["guid-1"])))
    await #expect(throws: (any Error).self) {
        try await fixture.runtime.restoreSelection([choice], account: .init(accountID: "account", sourceGeneration: "source"),
            originalExpiresAt: fixture.clock.now().addingTimeInterval(90), for: fixture.intent)
    }
    #expect(await fixture.runtime.selectedConversationIDs(for: fixture.intent).isEmpty)
    await fixture.runtime.drain()
}

@Test func iMessageRuntimeDrainJoinsRestorationAndPermanentlyDeniesRetiredSession() async throws {
    let fixture = IMessageRuntimeFixture()
    try await fixture.activate()
    await fixture.provider.hold()
    let operation = Task {
        try await fixture.runtime.restoreSelection([IMessageSetupDraft.Selection(nativeChatRowID: "1", expectedGUID: "guid-1")],
            account: .init(accountID: "account", sourceGeneration: "source"), originalExpiresAt: fixture.clock.now().addingTimeInterval(90), for: fixture.intent)
    }
    await fixture.provider.waitUntilHeld()
    operation.cancel()
    await fixture.runtime.drain()
    await #expect(throws: (any Error).self) { try await operation.value }
    await #expect(throws: IMessageSetupProviderError.accountChanged) { try await fixture.runtime.activateLocalSetup(fixture.intent) }
    #expect(await fixture.provider.stops > 0)
}
