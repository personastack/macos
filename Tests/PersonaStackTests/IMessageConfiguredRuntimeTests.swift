import Foundation
import Testing
@testable import PersonaStackCore

@Test(arguments: ["version", "workspace", "account", "source", "cutoff", "paused"])
func iMessageConfiguredSemanticScopeRejectsChangedAuthority(fault: String) throws {
    let scope = try configuredFixtureScope(paused: fault == "paused")
    #expect(!IMessageConfiguredGatewayValidation.matches(scope, configID: "config", workspaceID: fault == "workspace" ? "other" : "workspace",
        configVersion: fault == "version" ? 3 : 2, accountGeneration: fault == "account" ? "other" : "account",
        sourceGeneration: fault == "source" ? "other" : "source", revision: fault == "cutoff" ? 0 : 3))
}

@Test func iMessageConfiguredReadAndSendAreIndependentAndOnlySelectedIDsCanExecute() throws {
    let sendOnly = try configuredFixtureScope(read: false)
    try IMessageConfiguredGatewayValidation.validate(.sendMessage(.init(integrationID: "config", conversationID: "chat", clientRequestID: "intent", text: "hello")), in: sendOnly)
    #expect(throws: (any Error).self) { try IMessageConfiguredGatewayValidation.validate(.recentMessages(.init(integrationID: "config", conversationID: "chat")), in: sendOnly) }
    #expect(throws: (any Error).self) { try IMessageConfiguredGatewayValidation.validate(.sendMessage(.init(integrationID: "config", conversationID: "foreign", clientRequestID: "intent", text: "hello")), in: sendOnly) }
    let readOnly = try configuredFixtureScope(send: false)
    try IMessageConfiguredGatewayValidation.validate(.conversation(.init(integrationID: "config", conversationID: "chat")), in: readOnly)
    #expect(throws: (any Error).self) { try IMessageConfiguredGatewayValidation.validate(.sendMessage(.init(integrationID: "config", conversationID: "chat", clientRequestID: "intent", text: "hello")), in: readOnly) }
}

@Test func iMessageConfiguredResultRequiresWholeSelectedScopeAndExactSendKey() throws {
    let scope = try configuredFixtureScope()
    #expect(throws: (any Error).self) {
        try IMessageConfiguredGatewayValidation.validate(.conversations(.init(conversations: [])), for: .conversations(.init(integrationID: "config")), scope: scope, deadline: configuredFixtureDeadline)
    }
    let request = IMessageGatewaySendMessageInput(integrationID: "config", conversationID: "chat", clientRequestID: "intent", text: "hello")
    let receipt = IMessageGatewaySendMessageResult(conversationID: "chat", clientRequestID: "other", messageID: "guid", confirmedAt: configuredFixtureDeadline)
    #expect(throws: (any Error).self) { try IMessageConfiguredGatewayValidation.validate(.sendMessage(receipt), for: .sendMessage(request), scope: scope, deadline: configuredFixtureDeadline) }
}

@Test func iMessageConfiguredCheckpointPreservesExplicitFalseAnchorAndRejectsForeignEvidence() throws {
    let scope = try configuredFixtureScope()
    let anchor = IMessageGatewaySourceAnchor(conversationID: "chat", rowID: try IMessageRowID(1), guid: "old-guid")
    let request = IMessageGatewaySourceCheckpointInput(conversationIDs: ["chat"], anchors: [anchor])
    let row = IMessageGatewaySourceCheckpointConversation(conversationID: "chat", chatGUID: "", available: false, tailRowID: try IMessageRowID(0), tailGUID: "", anchorMatches: false)
    let value = IMessageGatewaySourceCheckpointResult(accountID: "public-account", sourceGeneration: "source", sourceHighWater: try IMessageRowID(Int64.max), observedAt: configuredFixtureDeadline, conversations: [row])
    try IMessageConfiguredGatewayValidation.validate(.sourceCheckpoint(value), for: .sourceCheckpoint(request), scope: scope, deadline: configuredFixtureDeadline)
    let encoded = try JSONEncoder().encode(value)
    #expect(String(decoding: encoded, as: UTF8.self).contains("\"anchor_matches\":false"))
    let foreign = IMessageGatewaySourceCheckpointResult(accountID: "foreign", sourceGeneration: "source", sourceHighWater: value.sourceHighWater, observedAt: value.observedAt, conversations: value.conversations)
    #expect(throws: (any Error).self) { try IMessageConfiguredGatewayValidation.validate(.sourceCheckpoint(foreign), for: .sourceCheckpoint(request), scope: scope, deadline: configuredFixtureDeadline) }
}

private final class ConfiguredRuntimeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}
actor ConfiguredRuntimeGate {
    private var waiting: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    private var started = false
    func pause() async {
        started = true; entered?.resume(); entered = nil
        await withCheckedContinuation { waiting = $0 }
    }
    func wait() async { if !started { await withCheckedContinuation { entered = $0 } } }
    func release() { waiting?.resume(); waiting = nil }
}
private actor ConfiguredRuntimeReplies {
    private var values: [String: IMessageGatewayPayload] = [:]
    private var waiting: [String: CheckedContinuation<IMessageGatewayPayload, Never>] = [:]
    func put(_ value: IMessageGatewayPayload, id: String) { values[id] = value; waiting.removeValue(forKey: id)?.resume(returning: value) }
    func get(_ id: String) async -> IMessageGatewayPayload {
        if let value = values[id] { return value }
        return await withCheckedContinuation { waiting[id] = $0 }
    }
}
private actor ConfiguredRuntimeProvider: IMessageSetupProviding {
    let gate: ConfiguredRuntimeGate?
    let sendFails: Bool
    private(set) var calls: [String] = []
    private(set) var deadlines: [Date] = []
    private(set) var stops = 0
    init(gate: ConfiguredRuntimeGate? = nil, sendFails: Bool = false) { self.gate = gate; self.sendFails = sendFails }
    func prerequisites(deadline: Date) throws -> IMessageGatewayPrerequisitesResult { Issue.record("Configured job used setup"); throw IMessageSetupProviderError.dependencyInvalid }
    func conversations(after: IMessageRowID, upper: IMessageRowID?, query: String, limit: Int, deadline: Date) throws -> IMessageSetupProviderPage { Issue.record("Configured job used setup inventory"); throw IMessageSetupProviderError.dependencyInvalid }
    func verify(conversations: [IMessageConversation], account: IMessageSetupAccount, deadline: Date) throws -> IMessageSetupProviderVerification { throw IMessageSetupProviderError.dependencyInvalid }
    func executeConfigured(_ input: IMessageGatewayConfiguredInput, scope: IMessageGatewayConfigScope, deadline: Date,
                           validateCurrent: @escaping @Sendable () async throws -> Bool) async throws -> IMessageGatewayConfiguredResult {
        calls.append(input.operationRawValue)
        deadlines.append(deadline)
        if calls.count == 1 { await gate?.pause() }
        try Task.checkCancellation()
        guard try await validateCurrent() else { throw IMessageSetupProviderError.accountChanged }
        switch input {
        case .status: return .status(.init(state: .connected))
        case .receivePage(let request):
            return .receivePage(.init(sourceGeneration: scope.sourceGeneration, sourceHighWater: try IMessageRowID(1000), messages: [],
                nextRowID: try IMessageRowID(request.after.value + 1), hasMore: true, stopReason: .scanLimit))
        case .sendMessage(let request):
            if sendFails { throw IMessageSetupProviderError.busy }
            return .sendMessage(.init(conversationID: request.conversationID, clientRequestID: request.clientRequestID, messageID: "confirmed-guid",
                confirmedAt: ISO8601DateFormatter().string(from: Date())))
        default: Issue.record("Unplanned configured operation"); throw IMessageSetupProviderError.dependencyInvalid
        }
    }
    func stop() async { stops += 1; await gate?.release() }
}
private actor ConfiguredRuntimeAuthority {
    private var snapshots: [Int64: IMessageGatewaySnapshot]
    let gate: ConfiguredRuntimeGate?
    let denied: Bool
    private(set) var commands: [String] = []
    init(snapshot: IMessageGatewaySnapshot, gate: ConfiguredRuntimeGate? = nil, denied: Bool = false) {
        self.snapshots = [snapshot.revision: snapshot]; self.gate = gate; self.denied = denied
    }
    func authorize(_ command: IMessageGatewayCommand, connectionID: UUID, deadline: Date) async throws -> IMessageGatewaySnapshot {
        commands.append(command.requestID)
        await gate?.pause()
        if denied { throw IMessageConfiguredAuthorizationError.denied(.scopeDenied) }
        guard let snapshot = snapshots[command.target.snapshotRevision] else { throw IMessageConfiguredAuthorizationError.denied(.scopeDenied) }
        return snapshot
    }
    func add(_ snapshot: IMessageGatewaySnapshot) { snapshots[snapshot.revision] = snapshot }
}
private struct ConfiguredRuntimeFixture {
    let clock: ConfiguredRuntimeClock
    let provider: ConfiguredRuntimeProvider
    let authority: ConfiguredRuntimeAuthority
    let replies = ConfiguredRuntimeReplies()
    let runtime: IMessageRuntime
    let connectionID = UUID()
    let scope: IMessageGatewayConfigScope
    let snapshot: IMessageGatewaySnapshot
    init(providerGate: ConfiguredRuntimeGate? = nil, authorityGate: ConfiguredRuntimeGate? = nil, denied: Bool = false, sendFails: Bool = false) throws {
        let clock = ConfiguredRuntimeClock(); self.clock = clock
        let scope = try configuredFixtureScope(); self.scope = scope
        snapshot = .init(installationID: "mac", revision: 3, configs: [scope])
        let authority = ConfiguredRuntimeAuthority(snapshot: snapshot, gate: authorityGate, denied: denied); self.authority = authority
        let provider = ConfiguredRuntimeProvider(gate: providerGate, sendFails: sendFails); self.provider = provider
        runtime = IMessageRuntime(installationID: "mac", provider: provider, referenceDigest: { _ in "unused" }, textDigest: { text in text == "hello" ? String(repeating: "a", count: 64) : "" },
            authorizeConfigured: { command, connectionID, deadline in try await authority.authorize(command, connectionID: connectionID, deadline: deadline) }, now: { clock.now() })
    }
    func activate() async {
        await runtime.bind(connectionID: connectionID)
        await runtime.setConfiguredPolicy(enabled: true)
        #expect(await runtime.install(snapshot, connectionID: connectionID) == .snapshotAck(.init(revision: 3)))
    }
    func command(_ id: String, input: IMessageGatewayConfiguredInput = .status(.init(integrationID: "config")), stream: Bool = false, revision: Int64 = 3, version: Int64 = 2, human: Bool = false) -> IMessageGatewayCommand {
        let caller = stream ? IMessageGatewayCaller(streamAssignment: .init(managerID: "manager", streamID: "stream", assignmentFence: 1))
            : IMessageGatewayCaller(personaMCP: .init(principalID: "principal", personaID: "persona", bindingVersion: 1))
        let send: Bool
        if case .sendMessage = input { send = true } else { send = false }
        return .init(requestID: id, authorizationID: "grant-\(id)", deadlineAt: ISO8601DateFormatter().string(from: clock.now().addingTimeInterval(send ? 45 : 10)),
            target: .init(installationID: "mac", workspaceID: "workspace", snapshotRevision: revision, configID: "config", configVersion: version, accountGeneration: "account", sourceGeneration: "source"),
            caller: human ? .init(humanAction: .init(userID: "human", action: send ? .testSend : .check,
                conversationID: send ? "chat" : nil, textSHA256: send ? String(repeating: "a", count: 64) : nil)) : caller, input: .configured(input), sendAttemptID: send ? "attempt-\(id)" : nil)
    }
    func enqueue(_ command: IMessageGatewayCommand) async -> IMessageGatewayFailure? {
        let replies = replies
        return await runtime.admit(command, connectionID: connectionID) { await replies.put($0, id: command.requestID) }
    }
    func send(_ id: String) -> IMessageGatewayCommand {
        command(id, input: .sendMessage(.init(integrationID: "config", conversationID: "chat", clientRequestID: "key-\(id)", text: "hello")))
    }
}

@Test func iMessageConfiguredRuntimeDeniesBeforeProviderWhenFinalAuthorityRejects() async throws {
    let fixture = try ConfiguredRuntimeFixture(denied: true)
    await fixture.activate()
    #expect(await fixture.enqueue(fixture.send("denied")) == nil)
    guard case .failure(let failure) = await fixture.replies.get("denied") else { Issue.record("Denied send succeeded"); return }
    #expect(failure.retrySafe && failure.clientRequestID == "key-denied")
    #expect(await fixture.provider.calls.isEmpty)
    #expect(await fixture.authority.commands == ["denied"])
    await fixture.runtime.drain()
}

@Test func iMessageConfiguredRuntimeLocalPauseDuringFinalAuthorityNeverInvokesProvider() async throws {
    let gate = ConfiguredRuntimeGate()
    let fixture = try ConfiguredRuntimeFixture(authorityGate: gate)
    await fixture.activate()
    #expect(await fixture.enqueue(fixture.send("paused")) == nil)
    await gate.wait()
    await fixture.runtime.setConfiguredPolicy(enabled: false)
    await gate.release()
    guard case .failure(let failure) = await fixture.replies.get("paused") else { Issue.record("Paused send succeeded"); return }
    #expect(failure.retrySafe && failure.clientRequestID == "key-paused")
    #expect(await fixture.provider.calls.isEmpty)
    await fixture.runtime.drain()
}

@Test(arguments: [false, true]) func iMessageConfiguredRuntimeEveryFailureAfterProviderInvocationStaysUnknown(cancel: Bool) async throws {
    let gate = cancel ? ConfiguredRuntimeGate() : nil
    let fixture = try ConfiguredRuntimeFixture(providerGate: gate, sendFails: true)
    await fixture.activate()
    #expect(await fixture.enqueue(fixture.send("possible")) == nil)
    if let gate {
        await gate.wait()
        await fixture.runtime.setConfiguredPolicy(enabled: false)
    }
    guard case .failure(let failure) = await fixture.replies.get("possible") else { Issue.record("Busy mutation path succeeded"); return }
    #expect(failure.code == .outcomeUnknown && !failure.retrySafe && failure.clientRequestID == "key-possible")
    #expect(await fixture.provider.calls == ["imessage_send_message"])
    await fixture.runtime.drain()
}

@Test func iMessageConfiguredRuntimeQueuedSendExpiresWithoutFinalAuthorizationOrProvider() async throws {
    let gate = ConfiguredRuntimeGate()
    let fixture = try ConfiguredRuntimeFixture(providerGate: gate)
    await fixture.activate()
    #expect(await fixture.enqueue(fixture.command("active")) == nil)
    await gate.wait()
    #expect(await fixture.enqueue(fixture.send("queued")) == nil)
    fixture.clock.advance(46)
    await fixture.runtime.reconcileDeadlines()
    guard case .failure(let failure) = await fixture.replies.get("queued") else { Issue.record("Expired send succeeded"); return }
    #expect(failure.retrySafe && failure.code == .providerTimeout)
    #expect(await fixture.authority.commands == ["active"])
    #expect(await fixture.provider.calls == ["imessage_status"])
    await fixture.runtime.drain()
}

@Test func iMessageConfiguredRuntimeGivesReceiveATurnAfterThreeInteractiveReads() async throws {
    let gate = ConfiguredRuntimeGate()
    let fixture = try ConfiguredRuntimeFixture(providerGate: gate)
    await fixture.activate()
    #expect(await fixture.enqueue(fixture.command("first")) == nil)
    await gate.wait()
    for id in ["second", "third", "fourth"] { #expect(await fixture.enqueue(fixture.command(id)) == nil) }
    let receive = fixture.command("receive", input: .receivePage(.init(conversationID: "chat", after: try IMessageRowID(0))), stream: true)
    #expect(await fixture.enqueue(receive) == nil)
    await gate.release()
    for id in ["first", "second", "third", "receive", "fourth"] { _ = await fixture.replies.get(id) }
    #expect(await fixture.provider.calls == ["imessage_status", "imessage_status", "imessage_status", "imessage_receive_page", "imessage_status"])
    await fixture.runtime.drain()
}

@Test func iMessageConfiguredRuntimeKeepsOriginalGrantsForCompatibleSameConfigJobs() async throws {
    let gate = ConfiguredRuntimeGate()
    let fixture = try ConfiguredRuntimeFixture(providerGate: gate)
    await fixture.activate()
    #expect(await fixture.enqueue(fixture.command("first", input: .receivePage(.init(conversationID: "chat", after: try IMessageRowID(0))), stream: true)) == nil)
    await gate.wait()
    let next = IMessageGatewaySnapshot(installationID: "mac", revision: 4, configs: [fixture.scope])
    await fixture.authority.add(next)
    #expect(await fixture.runtime.install(next, connectionID: fixture.connectionID) == .snapshotAck(.init(revision: 4)))
    #expect(await fixture.enqueue(fixture.command("second", revision: 4)) == nil)
    await gate.release()
    for id in ["first", "second"] {
        guard case .result(.configured) = await fixture.replies.get(id) else { Issue.record("Compatible grant was canceled"); continue }
    }
    #expect(await fixture.authority.commands == ["first", "second"])
    #expect(await fixture.provider.calls == ["imessage_receive_page", "imessage_status"])
    await fixture.runtime.drain()
}

@Test func iMessageConfiguredRuntimeNewConfigVersionFencesAnAdmittedOriginalGrant() async throws {
    let gate = ConfiguredRuntimeGate()
    let fixture = try ConfiguredRuntimeFixture(authorityGate: gate)
    await fixture.activate()
    #expect(await fixture.enqueue(fixture.send("old")) == nil)
    await gate.wait()
    let changed = IMessageGatewaySnapshot(installationID: "mac", revision: 4, configs: [try configuredFixtureScope(version: 3)])
    #expect(await fixture.runtime.install(changed, connectionID: fixture.connectionID) == .snapshotAck(.init(revision: 4)))
    await gate.release()
    guard case .failure(let failure) = await fixture.replies.get("old") else { Issue.record("Superseded send executed"); return }
    #expect(failure.retrySafe && failure.code == .scopeDenied)
    #expect(await fixture.provider.calls.isEmpty)
    #expect(await fixture.enqueue(fixture.send("stale"))?.code == .scopeDenied)
    await fixture.runtime.drain()
}

@Test func iMessageConfiguredRuntimeHumanJobsRequireExactLiveNativeConfirmation() async throws {
    let fixture = try ConfiguredRuntimeFixture()
    await fixture.activate()
    let input = IMessageGatewayConfiguredInput.sendMessage(.init(integrationID: "config", conversationID: "chat", clientRequestID: "human-key", text: "hello"))
    let command = fixture.command("human", input: input, human: true)
    #expect(await fixture.enqueue(command)?.retrySafe == true)
    let generation = UUID()
    try await fixture.runtime.registerHumanAction(command, localGeneration: generation, confirmed: true,
        deadline: IMessageGatewayWire.utcDate(command.deadlineAt))
    await fixture.runtime.withdrawHumanActions(localGeneration: generation)
    #expect(await fixture.enqueue(command)?.code == .scopeDenied)
    #expect(await fixture.authority.commands.isEmpty)
    #expect(await fixture.provider.calls.isEmpty)
    try await fixture.runtime.registerHumanAction(command, localGeneration: UUID(), confirmed: true,
        deadline: IMessageGatewayWire.utcDate(command.deadlineAt))
    #expect(await fixture.enqueue(command) == nil)
    guard case .result(.configured(.sendMessage(let receipt))) = await fixture.replies.get("human") else { Issue.record("Confirmed human send failed"); return }
    #expect(receipt.clientRequestID == "human-key")
    #expect(await fixture.enqueue(command)?.code == .scopeDenied)
    await fixture.runtime.drain()
}

@Test func iMessageConfiguredRuntimeBoundsWaitersAndNeverRunsDuplicateAttempt() async throws {
    let gate = ConfiguredRuntimeGate()
    let fixture = try ConfiguredRuntimeFixture(providerGate: gate)
    await fixture.activate()
    let first = fixture.send("first")
    #expect(await fixture.enqueue(first) == nil)
    await gate.wait()
    let duplicate = await fixture.enqueue(first)
    #expect(duplicate?.code == .requestInProgress && duplicate?.retrySafe == false && duplicate?.clientRequestID == "key-first")
    for number in 1...8 { #expect(await fixture.enqueue(fixture.send("queued-\(number)")) == nil) }
    let overflow = await fixture.enqueue(fixture.send("overflow"))
    #expect(overflow?.code == .busy && overflow?.retrySafe == true)
    await fixture.runtime.setConfiguredPolicy(enabled: false)
    for number in 1...8 {
        guard case .failure(let value) = await fixture.replies.get("queued-\(number)") else { Issue.record("Canceled waiter executed"); continue }
        #expect(value.retrySafe)
    }
    guard case .failure(let firstFailure) = await fixture.replies.get("first") else { Issue.record("Canceled active send succeeded"); return }
    #expect(firstFailure.code == .outcomeUnknown && !firstFailure.retrySafe)
    #expect(await fixture.provider.calls == ["imessage_send_message"])
    #expect(await fixture.authority.commands == ["first"])
    await fixture.runtime.drain()
}


@Test func iMessageConfiguredRuntimeSetupMetadataConsentCannotRevokeOrBroadenConfiguredWork() async throws {
    let gate = ConfiguredRuntimeGate()
    let fixture = try ConfiguredRuntimeFixture(providerGate: gate)
    await fixture.activate()
    #expect(await fixture.enqueue(fixture.command("active")) == nil)
    await gate.wait()
    let originalStops = await fixture.provider.stops
    let setup = IMessageGatewaySetupScope(setupReferenceSHA256: String(repeating: "A", count: 43), generation: 1,
        workspaceID: "workspace", userID: "human", expiresAt: ISO8601DateFormatter().string(from: fixture.clock.now().addingTimeInterval(300)), enabled: true)
    let intent = IMessageRuntimeSetupIntent(localGeneration: UUID(), scope: setup)
    try await fixture.runtime.activateLocalSetup(intent)
    try await fixture.runtime.setMetadataConsent(true, for: intent)
    #expect(await fixture.runtime.install(.init(installationID: "mac", revision: 100, setupScope: setup), connectionID: fixture.connectionID) == .snapshotAck(.init(revision: 100)))
    await fixture.runtime.withdrawLocalSetup(intent)
    let next = IMessageGatewaySnapshot(installationID: "mac", revision: 4, configs: [fixture.scope])
    await fixture.authority.add(next)
    #expect(await fixture.runtime.install(next, connectionID: fixture.connectionID) == .snapshotAck(.init(revision: 4)))
    #expect(await fixture.enqueue(fixture.command("new", revision: 4)) == nil)
    await gate.release()
    for id in ["active", "new"] {
        guard case .result(.configured(.status)) = await fixture.replies.get(id) else { Issue.record("Independent setup canceled configured work"); continue }
    }
    #expect(await fixture.provider.stops == originalStops)
    await fixture.runtime.drain()
}

@Test func iMessageConfiguredRuntimePhysicalConnectionLossNeverReplaysAnOldCommand() async throws {
    let gate = ConfiguredRuntimeGate()
    let fixture = try ConfiguredRuntimeFixture(authorityGate: gate)
    await fixture.activate()
    #expect(await fixture.enqueue(fixture.send("old-physical")) == nil)
    await gate.wait()
    await fixture.runtime.unbind(connectionID: fixture.connectionID)
    await gate.release()
    await fixture.runtime.setExecutionAvailable(false)
    let fresh = UUID()
    await fixture.runtime.bind(connectionID: fresh)
    #expect(await fixture.runtime.install(fixture.snapshot, connectionID: fresh) == .snapshotAck(.init(revision: 3)))
    #expect(await fixture.runtime.admit(fixture.send("asleep"), connectionID: fresh, reply: { _ in Issue.record("Sleeping command executed") })?.retrySafe == true)
    await fixture.runtime.setExecutionAvailable(true)
    #expect(await fixture.enqueue(fixture.send("old-frame"))?.code == .scopeDenied)
    #expect(await fixture.provider.calls.isEmpty)
    await fixture.runtime.drain()
}

@Test(arguments: ["hash", "confirmation", "expiry"])
func iMessageConfiguredRuntimeRejectsUnconfirmedChangedOrExpiredHumanPreview(fault: String) async throws {
    let fixture = try ConfiguredRuntimeFixture()
    await fixture.activate()
    let input = IMessageGatewayConfiguredInput.sendMessage(.init(integrationID: "config", conversationID: "chat", clientRequestID: "human-key", text: "hello"))
    var command = fixture.command("human", input: input, human: true)
    if fault == "hash" {
        let raw = String(decoding: try JSONEncoder().encode(command), as: UTF8.self)
            .replacingOccurrences(of: String(repeating: "a", count: 64), with: String(repeating: "b", count: 64))
        command = try IMessageConfiguredGatewayValidation.decode(IMessageGatewayCommand.self, from: Data(raw.utf8))
    }
    let deadline = try IMessageGatewayWire.utcDate(command.deadlineAt)
    if fault == "expiry" { fixture.clock.advance(46) }
    let expected = command
    await #expect(throws: IMessageSetupProviderError.accountChanged) {
        try await fixture.runtime.registerHumanAction(expected, localGeneration: UUID(), confirmed: fault != "confirmation", deadline: deadline)
    }
    #expect(await fixture.enqueue(command)?.code == .scopeDenied)
    #expect(await fixture.authority.commands.isEmpty)
    #expect(await fixture.provider.calls.isEmpty)
    await fixture.runtime.drain()
}

@Test(arguments: ["earlier", "equal", "later", "expired"])
func iMessageHumanReceiptDeadlineCanTightenButNeverExtendIssuedCommand(bound: String) async throws {
    let fixture = try ConfiguredRuntimeFixture()
    await fixture.activate()
    let command = fixture.command("native-deadline", human: true)
    let issued = try IMessageGatewayWire.utcDate(command.deadlineAt)
    let receipt = bound == "earlier" ? issued.addingTimeInterval(-1)
        : (bound == "later" ? issued.addingTimeInterval(1) : (bound == "expired" ? fixture.clock.now() : issued))
    if bound == "later" || bound == "expired" {
        await #expect(throws: IMessageSetupProviderError.accountChanged) {
            try await fixture.runtime.registerHumanAction(command, localGeneration: UUID(), confirmed: true, deadline: receipt)
        }
        #expect(await fixture.enqueue(command)?.code == .scopeDenied)
    } else {
        try await fixture.runtime.registerHumanAction(command, localGeneration: UUID(), confirmed: true, deadline: receipt)
        #expect(await fixture.enqueue(command) == nil)
        guard case .result(.configured(.status)) = await fixture.replies.get(command.requestID) else { Issue.record("Valid tightened receipt failed"); return }
        #expect(await fixture.provider.deadlines == [receipt])
    }
    await fixture.runtime.drain()
}

@Test func iMessageQueuedHumanExpiryNeverReachesFinalAuthorizationOrProvider() async throws {
    let gate = ConfiguredRuntimeGate()
    let fixture = try ConfiguredRuntimeFixture(providerGate: gate)
    await fixture.activate()
    #expect(await fixture.enqueue(fixture.command("first")) == nil)
    await gate.wait()
    let send = fixture.command("queued-human", input: .sendMessage(.init(integrationID: "config", conversationID: "chat", clientRequestID: "one-key", text: "hello")), human: true)
    try await fixture.runtime.registerHumanAction(send, localGeneration: UUID(), confirmed: true, deadline: fixture.clock.now().addingTimeInterval(1))
    #expect(await fixture.enqueue(send) == nil)
    fixture.clock.advance(2)
    await fixture.runtime.reconcileDeadlines()
    guard case .failure(let failure) = await fixture.replies.get(send.requestID) else { Issue.record("Expired native intent dispatched"); return }
    #expect(failure.retrySafe && failure.clientRequestID == "one-key")
    #expect(await fixture.authority.commands == ["first"])
    #expect(await fixture.provider.calls == ["imessage_status"])
    await gate.release()
    _ = await fixture.replies.get("first")
    await fixture.runtime.drain()
}

@Test func iMessageActiveHumanProviderBudgetUsesOriginalStricterNativeExpiry() async throws {
    let gate = ConfiguredRuntimeGate()
    let fixture = try ConfiguredRuntimeFixture(providerGate: gate)
    await fixture.activate()
    let send = fixture.command("active-human", input: .sendMessage(.init(integrationID: "config", conversationID: "chat", clientRequestID: "one-key", text: "hello")), human: true)
    let expiry = fixture.clock.now().addingTimeInterval(2)
    try await fixture.runtime.registerHumanAction(send, localGeneration: UUID(), confirmed: true, deadline: expiry)
    #expect(await fixture.enqueue(send) == nil)
    await gate.wait()
    #expect(await fixture.provider.deadlines == [expiry])
    fixture.clock.advance(3)
    await fixture.runtime.reconcileDeadlines()
    guard case .failure(let failure) = await fixture.replies.get(send.requestID) else { Issue.record("Expired active provider returned success"); return }
    #expect(!failure.retrySafe && failure.code == .outcomeUnknown)
    #expect(await fixture.provider.calls == ["imessage_send_message"])
    await fixture.runtime.drain()
}
