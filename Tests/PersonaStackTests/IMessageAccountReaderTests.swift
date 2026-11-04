import Foundation
import PersonaStackCore
import Testing
@testable import PersonaStack

private actor AccountPermissionGate {
    private var waiting: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    private var active = false
    func pause() async {
        active = true
        await withCheckedContinuation { continuation in
            waiting = continuation
            entered?.resume(); entered = nil
        }
    }
    func waitUntilEntered() async {
        if active { return }
        await withCheckedContinuation { entered = $0 }
    }
    func release() { waiting?.resume(); waiting = nil }
}

private final class AccountEnvironmentFixture: IMessageAccountEnvironment, @unchecked Sendable {
    private let lock = NSLock()
    private var identity = IMessageSourceFileIdentity(volumeUUID: "volume", file: "source-1", birth: Date(timeIntervalSince1970: 1))
    private var permissions: [(String, Bool)] = []
    private var generations: [(IMessageSourceFileIdentity, String)] = []
    let running: Bool
    let allowed: Bool
    let installed: Bool
    let permissionGate: AccountPermissionGate?
    let changeSourceDuringPermission: Bool
    init(running: Bool = true, allowed: Bool = true, installed: Bool = true,
         permissionGate: AccountPermissionGate? = nil, changeSourceDuringPermission: Bool = false) {
        self.running = running; self.allowed = allowed; self.installed = installed
        self.permissionGate = permissionGate; self.changeSourceDuringPermission = changeSourceDuringPermission
    }
    var permissionRequests: [(String, Bool)] { lock.withLock { permissions } }
    var generationRequests: [(IMessageSourceFileIdentity, String)] { lock.withLock { generations } }
    func messagesBundleID() -> String? { installed ? "com.apple.MobileSMS" : nil }
    func messagesRunning(bundleID: String) async -> Bool { running }
    func permissionAllowed(bundleID: String, requestAutomation: Bool) async -> Bool {
        lock.withLock { permissions.append((bundleID, requestAutomation)) }
        if let permissionGate { await permissionGate.pause() }
        if changeSourceDuringPermission { rotateSource() }
        return allowed
    }
    func rotateSource() {
        lock.withLock { identity = IMessageSourceFileIdentity(volumeUUID: "volume", file: "source-2", birth: identity.birth) }
    }
    func sourceIdentity() throws -> IMessageSourceFileIdentity { lock.withLock { identity } }
    func sourceGeneration(identity: IMessageSourceFileIdentity, accountID: String) throws -> String {
        lock.withLock { generations.append((identity, accountID)) }
        return identity.file + ":" + accountID
    }
}

private final class AccountProcessFixture: CuaProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private var invocations: [(URL, [String])] = []
    private var held: Bool
    private var output: CuaProcessResult
    private var finished = false
    private let afterRun: @Sendable () -> Void
    init(held: Bool = false, status: Int32 = 0, stdout: Data = Data("public-account\n".utf8),
         stderr: Data = Data(), afterRun: @escaping @Sendable () -> Void = {}) {
        self.held = held; self.output = CuaProcessResult(status: status, stdout: stdout, stderr: stderr)
        self.afterRun = afterRun
    }
    var calls: [(URL, [String])] { lock.withLock { invocations } }
    var stopped: Bool { lock.withLock { finished } }
    func setAccount(_ account: String) {
        lock.withLock { output = CuaProcessResult(status: 0, stdout: Data((account + "\n").utf8), stderr: Data()) }
    }
    func release() { lock.withLock { held = false } }
    private func waitForEntry() -> Bool {
        entered.wait(timeout: .now() + 2) == .success
    }
    func waitUntilEntered() async -> Bool {
        await Task.detached { self.waitForEntry() }.value
    }
    func run(_ executable: URL, arguments: [String]) throws -> CuaProcessResult {
        lock.withLock { invocations.append((executable, arguments)); finished = false }
        entered.signal()
        defer { lock.withLock { finished = true } }
        while lock.withLock({ held }) {
            try Task.checkCancellation()
            Thread.sleep(forTimeInterval: 0.001)
        }
        try Task.checkCancellation()
        afterRun()
        return lock.withLock { output }
    }
}

private actor AccountUnstartedTransport: IMessageRPCTransport {
    func launch() throws { throw IMessageRPCError.invalidArguments }
    func read(maximumBytes: Int) throws -> Data { throw IMessageRPCError.invalidArguments }
    func write(_ data: Data) throws { throw IMessageRPCError.invalidArguments }
    func terminate() {}
}

private func boundAccountReader(environment: AccountEnvironmentFixture, process: AccountProcessFixture) async throws -> IMessageAccountReader {
    let reader = IMessageAccountReader(environment: environment, process: process)
    try await reader.prepareProviderConnection(IMessageRPCClient(transport: AccountUnstartedTransport()))
    return reader
}

@Test func iMessageAccountReaderUsesOneFixedBatchForAllThirtyTwoChatsAndSingleChat() async throws {
    let environment = AccountEnvironmentFixture()
    let process = AccountProcessFixture()
    let reader = try await boundAccountReader(environment: environment, process: process)
    let guids = (1...32).map { "iMessage;+;chat-\($0)" }
    let batch = try await reader.observe(chatGUIDs: guids, expectedAccountID: "public-account")
    #expect(batch.chatGUIDs == guids)
    #expect(batch.accountID == "public-account")
    #expect(batch.sourceGeneration == "source-1:public-account")
    #expect(process.calls.count == 1)
    #expect(environment.permissionRequests.map(\.1) == [false])
    #expect(environment.permissionRequests.first?.0 == "com.apple.MobileSMS")
    let single = try await reader.observe(chatGUIDs: [guids[0]], requestAutomation: true)
    #expect(single.chatGUIDs == [guids[0]])
    #expect(single.sourceGeneration == batch.sourceGeneration)
    let calls = process.calls
    #expect(calls.count == 2)
    #expect(calls[0].0.path == "/usr/bin/osascript")
    #expect(calls[0].1[0] == "-e")
    #expect(Array(calls[0].1.dropFirst(2)) == guids)
    #expect(Array(calls[1].1.dropFirst(2)) == [guids[0]])
    #expect(calls[0].1[1] == calls[1].1[1])
    #expect(calls[0].1[1].contains("repeat with requestedGUID in argv"))
    #expect(calls[0].1[1].contains("commonAccountID is not observedAccountID"))
    #expect(calls[0].1[1].contains("/System/Applications/Messages.app"))
    #expect(environment.permissionRequests.map(\.1) == [false, true])
    #expect(environment.generationRequests.map(\.1) == ["public-account", "public-account"])
    #expect(IMessageAccountReader.processTimeoutSeconds == 5)
    #expect(IMessageAccountReader.maximumOutputBytes == 4096)
}

@Test func iMessageAccountReaderPassesUntrustedGuidAsDataWithoutScriptInterpolation() async throws {
    let process = AccountProcessFixture()
    let reader = try await boundAccountReader(environment: AccountEnvironmentFixture(), process: process)
    let guid = "iMessage;+;\" & do shell script \"untrusted\""
    let observed = try await reader.observe(chatGUIDs: [guid])
    #expect(observed.chatGUIDs == [guid])
    #expect(process.calls[0].1.last == guid)
    #expect(!process.calls[0].1[1].contains(guid))
}

@Test func iMessageAccountReaderRejectsInvalidSelectionsBeforePermissionsOrProcess() async throws {
    let environment = AccountEnvironmentFixture()
    let process = AccountProcessFixture()
    let reader = try await boundAccountReader(environment: environment, process: process)
    for guids in [[], [""], ["-e"], ["chat\nsecond"], [String(repeating: "é", count: 129)],
                  ["same", "same"], (1...33).map { "chat-\($0)" }] {
        await #expect(throws: IMessageAccountError.selectedAccountUnavailable) { try await reader.observe(chatGUIDs: guids) }
    }
    await #expect(throws: IMessageAccountError.selectedAccountUnavailable) {
        try await reader.observe(chatGUIDs: ["chat"], expectedAccountID: "account\nsecond")
    }
    #expect(environment.permissionRequests.isEmpty)
    #expect(process.calls.isEmpty)
}

@Test(arguments: ["missing", "stopped", "denied"])
func iMessageAccountReaderNeverLaunchesBeforeRunningAndPermissionChecks(state: String) async throws {
    let environment = AccountEnvironmentFixture(running: state != "stopped", allowed: state != "denied", installed: state != "missing")
    let process = AccountProcessFixture()
    let reader = try await boundAccountReader(environment: environment, process: process)
    let expected: IMessageAccountError = state == "denied" ? .automationRequired : .messagesNotRunning
    await #expect(throws: expected) { try await reader.observe(chatGUIDs: ["chat"]) }
    #expect(process.calls.isEmpty)
    #expect(environment.permissionRequests.map(\.1) == (state == "denied" ? [false] : []))
    #expect(environment.generationRequests.isEmpty)
}

@Test(arguments: ["unavailable\n", "", "public-account\nsecond\n", "\n", String(repeating: "a", count: 257)])
func iMessageAccountReaderRejectsUnprovedMixedOrMalformedAccountOutput(value: String) async throws {
    let environment = AccountEnvironmentFixture()
    let process = AccountProcessFixture(stdout: Data(value.utf8))
    let reader = try await boundAccountReader(environment: environment, process: process)
    await #expect(throws: IMessageAccountError.selectedAccountUnavailable) {
        try await reader.observe(chatGUIDs: ["chat-1", "chat-2"])
    }
    #expect(environment.generationRequests.isEmpty)
}

@Test func iMessageAccountReaderRejectsFailedOversizedOrNonUtf8ProcessResults() async throws {
    let outcomes = [CuaProcessResult(status: 1, stdout: Data("public-account\n".utf8), stderr: Data()),
        CuaProcessResult(status: 0, stdout: Data([0xff]), stderr: Data()),
        CuaProcessResult(status: 0, stdout: Data(repeating: 0x20, count: 4097), stderr: Data()),
        CuaProcessResult(status: 0, stdout: Data("public-account\n".utf8), stderr: Data(count: 4097))]
    for outcome in outcomes {
        let environment = AccountEnvironmentFixture()
        let process = AccountProcessFixture(status: outcome.status, stdout: outcome.stdout, stderr: outcome.stderr)
        let reader = try await boundAccountReader(environment: environment, process: process)
        await #expect(throws: IMessageAccountError.selectedAccountUnavailable) { try await reader.observe(chatGUIDs: ["chat"]) }
        #expect(environment.generationRequests.isEmpty)
    }
}

@Test func iMessageAccountReaderPinsTheExactLiveAccountUntilFreshProviderBinding() async throws {
    let environment = AccountEnvironmentFixture()
    let process = AccountProcessFixture()
    let reader = try await boundAccountReader(environment: environment, process: process)
    _ = try await reader.observe(chatGUIDs: ["chat"])
    process.setAccount("another-account")
    await #expect(throws: IMessageAccountError.sourceChanged) { try await reader.observe(chatGUIDs: ["chat"]) }
    #expect(environment.generationRequests.count == 1)
    try await reader.prepareProviderConnection(IMessageRPCClient(transport: AccountUnstartedTransport()))
    await #expect(throws: IMessageAccountError.sourceChanged) {
        try await reader.observe(chatGUIDs: ["chat"], expectedAccountID: "public-account")
    }
    let rebound = try await reader.observe(chatGUIDs: ["chat"], expectedAccountID: "another-account")
    #expect(rebound.accountID == "another-account")
}

@Test func iMessageAccountReaderRejectsSourceChangesBeforeAndAfterTheBatch() async throws {
    for duringPermission in [false, true] {
        let environment = AccountEnvironmentFixture(changeSourceDuringPermission: duringPermission)
        let process = AccountProcessFixture(afterRun: { if !duringPermission { environment.rotateSource() } })
        let reader = try await boundAccountReader(environment: environment, process: process)
        await #expect(throws: IMessageAccountError.sourceChanged) { try await reader.observe(chatGUIDs: ["chat"]) }
        #expect(process.calls.count == (duringPermission ? 0 : 1))
        #expect(environment.generationRequests.isEmpty)
    }
}

@Test func iMessageAccountReaderCancellationDuringPermissionCannotLaunchACommand() async throws {
    let gate = AccountPermissionGate()
    let environment = AccountEnvironmentFixture(permissionGate: gate)
    let process = AccountProcessFixture()
    let reader = try await boundAccountReader(environment: environment, process: process)
    let observation = Task { try await reader.observe(chatGUIDs: ["chat"]) }
    await gate.waitUntilEntered()
    observation.cancel()
    await gate.release()
    await #expect(throws: CancellationError.self) { try await observation.value }
    #expect(process.calls.isEmpty)
    #expect(environment.generationRequests.isEmpty)
}

@Test func iMessageAccountReaderCancellationJoinsTheOwnedCommandBeforeReturning() async throws {
    let environment = AccountEnvironmentFixture()
    let process = AccountProcessFixture(held: true)
    let reader = try await boundAccountReader(environment: environment, process: process)
    let observation = Task { try await reader.observe(chatGUIDs: ["chat"]) }
    #expect(await process.waitUntilEntered())
    observation.cancel()
    await #expect(throws: CancellationError.self) { try await observation.value }
    #expect(process.stopped)
    #expect(environment.generationRequests.isEmpty)
}

@Test func iMessageAccountReaderFencesOverlappingAndClearedProviderObservations() async throws {
    let environment = AccountEnvironmentFixture()
    let process = AccountProcessFixture(held: true)
    let reader = try await boundAccountReader(environment: environment, process: process)
    let observation = Task { try await reader.observe(chatGUIDs: ["chat"]) }
    #expect(await process.waitUntilEntered())
    await #expect(throws: IMessageRPCError.busy) { try await reader.observe(chatGUIDs: ["other-chat"]) }
    await reader.clearProviderBinding()
    process.release()
    await #expect(throws: IMessageAccountError.sourceChanged) { try await observation.value }
    #expect(process.calls.count == 1)
    #expect(environment.generationRequests.isEmpty)
}

@Test func iMessageCurrentAccountObservationUsesFixedPublicAccountInventoryWithoutChats() async throws {
    let environment = AccountEnvironmentFixture()
    let process = AccountProcessFixture()
    let reader = try await boundAccountReader(environment: environment, process: process)
    let current = try await reader.observeCurrentAccount()
    #expect(current == IMessageCurrentAccountObservation(accountID: "public-account", sourceGeneration: "source-1:public-account"))
    #expect(process.calls.count == 1)
    #expect(process.calls[0].0.path == "/usr/bin/osascript")
    #expect(process.calls[0].1.count == 2)
    let script = process.calls[0].1[1]
    #expect(script.contains("repeat with candidateAccount in accounts"))
    #expect(script.contains("(count of observedAccountIDs) is not 1"))
    #expect(script.contains("service type of candidateAccount"))
    #expect(script.contains("enabled of candidateAccount"))
    #expect(script.contains("connection status of candidateAccount"))
    #expect(!script.contains("get chat") && !script.contains("do shell script"))
    #expect(environment.permissionRequests.map(\.1) == [false])
    let selected = try await reader.observe(chatGUIDs: ["chosen"], expectedAccountID: current.accountID)
    #expect(selected.sourceGeneration == current.sourceGeneration)
    #expect(selected.chatGUIDs == ["chosen"])
}

@Test(arguments: ["missing", "stopped", "denied"])
func iMessageCurrentAccountObservationNeverLaunchesOrRequestsPermission(state: String) async throws {
    let environment = AccountEnvironmentFixture(running: state != "stopped", allowed: state != "denied", installed: state != "missing")
    let process = AccountProcessFixture()
    let reader = try await boundAccountReader(environment: environment, process: process)
    await #expect(throws: state == "denied" ? IMessageAccountError.automationRequired : .messagesNotRunning) {
        try await reader.observeCurrentAccount()
    }
    #expect(process.calls.isEmpty)
    #expect(environment.permissionRequests.map(\.1) == (state == "denied" ? [false] : []))
}

@Test(arguments: ["unavailable\n", "", "first-account\nsecond-account\n"])
func iMessageCurrentAccountObservationRejectsNoMixedOrAmbiguousAccount(value: String) async throws {
    let environment = AccountEnvironmentFixture()
    let reader = try await boundAccountReader(environment: environment, process: AccountProcessFixture(stdout: Data(value.utf8)))
    await #expect(throws: IMessageAccountError.selectedAccountUnavailable) { try await reader.observeCurrentAccount() }
    #expect(environment.generationRequests.isEmpty)
}

@Test func iMessageCurrentAccountObservationPinsSelectedBatchAndFencesSourceReplacement() async throws {
    let environment = AccountEnvironmentFixture()
    let process = AccountProcessFixture()
    let reader = try await boundAccountReader(environment: environment, process: process)
    _ = try await reader.observeCurrentAccount()
    process.setAccount("other-account")
    await #expect(throws: IMessageAccountError.sourceChanged) {
        try await reader.observe(chatGUIDs: ["chosen"], expectedAccountID: "public-account")
    }
    environment.rotateSource()
    await #expect(throws: IMessageAccountError.sourceChanged) { try await reader.observeCurrentAccount() }
    #expect(environment.generationRequests.count == 1)
}

@Test func iMessageCurrentAccountObservationSharesTheExclusiveCancellableObservationLane() async throws {
    let environment = AccountEnvironmentFixture()
    let process = AccountProcessFixture(held: true)
    let reader = try await boundAccountReader(environment: environment, process: process)
    let current = Task { try await reader.observeCurrentAccount() }
    #expect(await process.waitUntilEntered())
    await #expect(throws: IMessageRPCError.busy) { try await reader.observe(chatGUIDs: ["chosen"]) }
    current.cancel()
    await #expect(throws: CancellationError.self) { try await current.value }
    #expect(process.stopped)
    #expect(environment.generationRequests.isEmpty)
    #expect(environment.permissionRequests.map(\.1) == [false])
}
