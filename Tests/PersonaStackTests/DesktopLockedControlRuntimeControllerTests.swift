import Foundation
@testable import PersonaStack
import PersonaStackCore
import Testing

@MainActor
private final class LockedRuntimeControllerFixture {
    var now = ContinuousClock.now
    var monotonicNow: UInt64 = 50_000_000_000
    var actualUnlocked = false
    var inputs: DesktopLockedControlRuntimeController.Inputs
    var prepareCount = 0
    var prepareHook: (@MainActor (DesktopControlCommandExecutor.LeaseSnapshot, UUID, Int32) async throws -> Bool)?
    var beginHook: (@MainActor (DesktopLockedControlGrant, Int32) async throws -> DesktopCrashSupervisorControlStatus)?
    var factoryCount = 0
    var prepareContinuation: CheckedContinuation<Bool, Error>?
    let client = FakeLockedRuntimeTransport()
    var controller: DesktopLockedControlRuntimeController!

    init() {
        let lease = Self.lease(now: now)
        inputs = Self.inputs(lease: lease)
        let operations = DesktopLockedControlRuntimeController.Operations(
            inputs: { [unowned self] in self.inputs },
            actualSessionIsUnlocked: { [unowned self] in self.actualUnlocked },
            prepareGUI: { [unowned self] lease, connection, pid in
                self.prepareCount += 1
                if let prepareHook { return try await prepareHook(lease, connection, pid) }
                self.setLock(.unlocked, guiReady: true)
                return true
            },
            now: { [unowned self] in self.now },
            monotonicNowNanoseconds: { [unowned self] in self.monotonicNow },
            sleep: { try await Task.sleep(for: $0) })
        controller = DesktopLockedControlRuntimeController(
            transportFactory: { [unowned self] in self.factoryCount += 1; return self.client },
            operations: operations)
        client.beginHook = { [unowned self] grant, pid in
            if let beginHook { return try await beginHook(grant, pid) }
            #expect(grant.connectionID == UUID(uuidString: "00000000-0000-0000-0000-000000000101"))
            #expect(pid == 4242)
            self.setLock(.unlocked)
            return Self.status(.controlling)
        }
    }

    static func lease(now: ContinuousClock.Instant, token: UUID = UUID()) -> DesktopControlCommandExecutor.LeaseSnapshot {
        .init(token: token, installationID: "installation", workspaceID: "workspace", configID: "config",
              personaID: "persona", runID: "run", generation: 7, configVersion: 9,
              expires: now + .seconds(80), hardExpires: now + .seconds(1_800))
    }

    static func inputs(lease: DesktopControlCommandExecutor.LeaseSnapshot?, connectionID: UUID? = connection,
                       console: DesktopLockedControlSupervisor.Console? = nil,
                       consentGranted: Bool = true, driverPID: Int32 = 4242,
                       guiReady: Bool = false) -> DesktopLockedControlRuntimeController.Inputs {
        .init(lease: lease, connectionID: connectionID,
              console: console ?? .init(userID: 501, sessionID: "7", lock: .locked),
              consentGranted: consentGranted, driverPID: driverPID, guiReady: guiReady)
    }

    static let connection = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!

    func setLock(_ lock: DesktopControlSessionLock.Snapshot, guiReady: Bool? = nil) {
        let current = inputs
        inputs = Self.inputs(lease: current.lease, connectionID: current.connectionID,
            console: .init(userID: current.console.userID, sessionID: current.console.sessionID, lock: lock),
            consentGranted: current.consentGranted, driverPID: current.driverPID,
            guiReady: guiReady ?? current.guiReady)
        actualUnlocked = lock == .unlocked
    }
}

@MainActor
private final class FakeLockedRuntimeTransport: DesktopLockedControlRuntimeTransport {
    var onConnectionLost: (@MainActor @Sendable () -> Void)?
    var events: [String] = []
    var sentGrant: DesktopLockedControlGrant?
    var sentDriverPID: Int32?
    var beginHook: (@MainActor (DesktopLockedControlGrant, Int32) async throws -> DesktopCrashSupervisorControlStatus)?
    var heartbeatStatus = LockedRuntimeControllerFixture.status(.controlling)
    var heartbeatHook: (@MainActor () async -> DesktopCrashSupervisorControlStatus)?
    var endStatus = LockedRuntimeControllerFixture.status(.idle)
    var beginEntered = false
    var beginContinuation: CheckedContinuation<DesktopCrashSupervisorControlStatus, Error>?
    var onInvalidate: (@MainActor () -> Void)?

    func connect() async throws { events.append("connect") }

    func begin(grant: DesktopLockedControlGrant, ownedCuaPID: Int32) async throws -> DesktopCrashSupervisorControlStatus {
        events.append("begin")
        beginEntered = true
        sentGrant = grant
        sentDriverPID = ownedCuaPID
        if let beginHook { return try await beginHook(grant, ownedCuaPID) }
        return LockedRuntimeControllerFixture.status(.controlling)
    }

    func status() async throws -> DesktopCrashSupervisorControlStatus {
        events.append("status")
        return heartbeatStatus
    }

    func heartbeat(grant: DesktopLockedControlGrant, ownedCuaPID: Int32) async throws -> DesktopCrashSupervisorControlStatus {
        events.append("heartbeat")
        #expect(grant == sentGrant)
        #expect(ownedCuaPID == sentDriverPID)
        if let heartbeatHook { return await heartbeatHook() }
        return heartbeatStatus
    }

    func end() async throws -> DesktopCrashSupervisorControlStatus {
        events.append("end")
        return endStatus
    }

    func invalidate() {
        events.append("invalidate")
        onInvalidate?()
    }

    func loseConnection() { onConnectionLost?() }
}

private extension LockedRuntimeControllerFixture {
    static func status(_ state: DesktopCrashSupervisorControlState,
                       result: DesktopCrashSupervisorControlStatus.Result = .accepted,
                       mayStillUnlock: Bool = false) -> DesktopCrashSupervisorControlStatus {
        .init(result: result, state: state, mayStillUnlock: mayStillUnlock)
    }
}

@Suite @MainActor
struct DesktopLockedControlRuntimeControllerTests {
    @Test func ordinaryRelockSuspendsGUIUntilSupervisorAndDriverAreReady() async throws {
        let fixture = LockedRuntimeControllerFixture()
        try await fixture.controller.begin()
        let grant = fixture.client.sentGrant
        fixture.setLock(.locked, guiReady: false)
        fixture.client.heartbeatStatus = LockedRuntimeControllerFixture.status(.preparing, mayStillUnlock: true)
        #expect(!fixture.controller.permitsExecution)
        #expect(fixture.controller.state == .recovering)
        await fixture.controller.observeNow()
        #expect(fixture.controller.state == .recovering)
        #expect(!fixture.client.events.contains("end"))
        fixture.setLock(.unlocked)
        fixture.client.heartbeatStatus = LockedRuntimeControllerFixture.status(.controlling)
        await fixture.controller.observeNow()
        #expect(fixture.controller.state == .controlling)
        #expect(fixture.controller.permitsExecution)
        #expect(fixture.prepareCount == 2)
        #expect(fixture.client.sentGrant == grant)
        #expect(fixture.client.events.filter { $0 == "begin" }.count == 1)
        #expect(await fixture.controller.stop())
    }

    @Test(arguments: [true, false]) func lockArrivingDuringHeartbeatPreservesRecovery(preparingReply: Bool) async throws {
        let fixture = LockedRuntimeControllerFixture()
        try await fixture.controller.begin()
        fixture.client.heartbeatHook = {
            fixture.setLock(.locked, guiReady: false)
            if !preparingReply { fixture.controller.observeOrdinaryLock() }
            return LockedRuntimeControllerFixture.status(preparingReply ? .preparing : .controlling,
                                                          mayStillUnlock: preparingReply)
        }
        await fixture.controller.observeNow()
        #expect(fixture.controller.state == .recovering)
        #expect(!fixture.controller.permitsExecution)
        #expect(!fixture.client.events.contains("end"))
        fixture.client.heartbeatHook = nil
        fixture.setLock(.unlocked)
        await fixture.controller.observeNow()
        #expect(fixture.controller.permitsExecution)
        #expect(fixture.prepareCount == 2)
        #expect(await fixture.controller.stop())
    }

    @Test func fastRelockAndUnlockStillRechecksGUI() async throws {
        let fixture = LockedRuntimeControllerFixture()
        try await fixture.controller.begin()
        fixture.controller.observeOrdinaryLock()
        // The supervisor has already unlocked by the next console sample.
        fixture.setLock(.unlocked, guiReady: false)
        #expect(!fixture.controller.permitsExecution)
        await fixture.controller.observeNow()
        #expect(fixture.controller.permitsExecution)
        #expect(fixture.prepareCount == 2)
        #expect(await fixture.controller.stop())
    }

    @Test func terminalSupervisorStateAfterRelockNeverRearms() async throws {
        let fixture = LockedRuntimeControllerFixture()
        try await fixture.controller.begin()
        fixture.setLock(.locked, guiReady: false)
        fixture.client.heartbeatStatus = LockedRuntimeControllerFixture.status(.idle)
        await fixture.controller.observeNow()
        #expect(fixture.controller.state == .idle)
        #expect(!fixture.controller.permitsExecution)
        #expect(fixture.client.events.filter { $0 == "begin" }.count == 1)
    }

    @Test func revokedAuthorityWhileRecoveringStillEndsSession() async throws {
        let fixture = LockedRuntimeControllerFixture()
        try await fixture.controller.begin()
        fixture.setLock(.locked, guiReady: false)
        #expect(!fixture.controller.permitsExecution)
        fixture.inputs = LockedRuntimeControllerFixture.inputs(lease: fixture.inputs.lease, consentGranted: false)
        await fixture.controller.observeNow()
        #expect(fixture.controller.state == .idle)
        #expect(fixture.client.events.contains("end"))
        #expect(fixture.client.events.filter { $0 == "begin" }.count == 1)
    }

    @Test func constructionIsInertAndGrantUsesCapturedHardExpiry() async throws {
        let fixture = LockedRuntimeControllerFixture()
        #expect(fixture.factoryCount == 0)
        #expect(fixture.client.events.isEmpty)

        try await fixture.controller.begin()

        let grant = try #require(fixture.client.sentGrant)
        #expect(grant.connectionID == LockedRuntimeControllerFixture.connection)
        #expect(grant.leaseToken == fixture.inputs.lease?.token)
        #expect(grant.expiresAtMonotonicNanoseconds == fixture.monotonicNow + 1_800_000_000_000)
        #expect(fixture.client.sentDriverPID == 4242)
        #expect(fixture.client.events == ["connect", "begin"])
        #expect(fixture.controller.state == .controlling)
        #expect(fixture.controller.permitsExecution)

        #expect(await fixture.controller.stop())
        #expect(fixture.client.events.suffix(2).elementsEqual(["end", "invalidate"]))
        #expect(!fixture.controller.permitsExecution)
    }

    @Test func changedLeaseOrConnectionAfterBeginCannotStartGUIControl() async {
        let fixture = LockedRuntimeControllerFixture()
        fixture.client.beginHook = { [unowned fixture] _, _ in
            let current = fixture.inputs
            fixture.inputs = LockedRuntimeControllerFixture.inputs(
                lease: LockedRuntimeControllerFixture.lease(now: fixture.now),
                connectionID: UUID(), console: current.console, consentGranted: current.consentGranted,
                driverPID: current.driverPID, guiReady: current.guiReady)
            fixture.setLock(.unlocked)
            return LockedRuntimeControllerFixture.status(.controlling)
        }

        await #expect(throws: DesktopLockedControlRuntimeController.Failure.invalidScope) {
            try await fixture.controller.begin()
        }

        #expect(fixture.prepareCount == 0)
        #expect(fixture.client.events.contains("invalidate"))
        #expect(fixture.client.events.last == "invalidate")
        #expect(!fixture.controller.permitsExecution)
    }

    @Test func changedConsentDuringGuiPreparationCannotPermitExecution() async {
        let fixture = LockedRuntimeControllerFixture()
        fixture.prepareHook = { [unowned fixture] _, _, _ in
            fixture.setLock(.unlocked, guiReady: true)
            let current = fixture.inputs
            fixture.inputs = LockedRuntimeControllerFixture.inputs(
                lease: current.lease, connectionID: current.connectionID, console: current.console,
                consentGranted: false, driverPID: current.driverPID, guiReady: current.guiReady)
            return true
        }

        await #expect(throws: DesktopLockedControlRuntimeController.Failure.invalidScope) {
            try await fixture.controller.begin()
        }

        #expect(fixture.controller.state == .needsAttention)
        #expect(fixture.client.events.contains("invalidate"))
        #expect(!fixture.controller.permitsExecution)
    }

    @Test func cancellationDuringGuiPreparationCannotPermitExecution() async {
        let fixture = LockedRuntimeControllerFixture()
        fixture.prepareHook = { [unowned fixture] _, _, _ in
            fixture.setLock(.unlocked, guiReady: true)
            withUnsafeCurrentTask { $0?.cancel() }
            return true
        }

        await #expect(throws: CancellationError.self) {
            try await fixture.controller.begin()
        }

        #expect(fixture.controller.state == .needsAttention)
        #expect(fixture.client.events.contains("invalidate"))
        #expect(fixture.client.events.last == "invalidate")
        #expect(!fixture.controller.permitsExecution)
    }

    @Test func heartbeatRechecksLeaseAndConsentBeforeSending() async throws {
        let fixture = LockedRuntimeControllerFixture()
        try await fixture.controller.begin()
        fixture.inputs = LockedRuntimeControllerFixture.inputs(
            lease: nil, connectionID: fixture.inputs.connectionID, console: fixture.inputs.console,
            consentGranted: fixture.inputs.consentGranted, driverPID: fixture.inputs.driverPID,
            guiReady: fixture.inputs.guiReady)

        await fixture.controller.observeNow()

        #expect(!fixture.client.events.contains("heartbeat"))
        #expect(fixture.client.events.suffix(2).elementsEqual(["end", "invalidate"]))
        #expect(!fixture.controller.permitsExecution)
    }

    @Test func nonControllingHeartbeatRevokesExecution() async throws {
        let fixture = LockedRuntimeControllerFixture()
        try await fixture.controller.begin()
        fixture.client.heartbeatStatus = LockedRuntimeControllerFixture.status(.needsAttention, mayStillUnlock: true)

        await fixture.controller.observeNow()

        #expect(fixture.client.events.contains("heartbeat"))
        #expect(fixture.client.events.contains("end"))
        #expect(fixture.client.events.last == "invalidate")
        #expect(!fixture.controller.permitsExecution)
    }

    @Test func connectionLossSynchronouslyDropsPermitAndInvalidatesTransport() async throws {
        let fixture = LockedRuntimeControllerFixture()
        try await fixture.controller.begin()

        fixture.client.loseConnection()

        #expect(fixture.controller.state == .needsAttention)
        #expect(await fixture.controller.stop() == false)
        #expect(fixture.controller.state == .needsAttention)
        #expect(!fixture.controller.permitsExecution)
        #expect(fixture.client.events.last == "invalidate")
    }

    @Test func heartbeatKeepsSupervisorAliveDuringGuiPreparation() async throws {
        let fixture = LockedRuntimeControllerFixture()
        fixture.prepareHook = { [unowned fixture] _, _, _ in
            try await withCheckedThrowingContinuation { continuation in
                fixture.prepareContinuation = continuation
            }
        }
        let beginTask = Task { try await fixture.controller.begin() }
        while fixture.prepareCount == 0 { await Task.yield() }

        await fixture.controller.observeNow()
        fixture.setLock(.unlocked, guiReady: true)
        fixture.prepareContinuation?.resume(returning: true)
        try await beginTask.value

        #expect(fixture.client.events.contains("heartbeat"))
        #expect(fixture.controller.state == .controlling)
        #expect(fixture.controller.permitsExecution)
        #expect(await fixture.controller.stop())
    }

    @Test func stopInvalidatesAnInFlightBeginWithoutWaitingForItsQueue() async throws {
        let fixture = LockedRuntimeControllerFixture()
        fixture.client.beginHook = { [unowned fixture] _, _ in
            try await withCheckedThrowingContinuation { continuation in
                fixture.client.beginContinuation = continuation
            }
        }
        fixture.client.onInvalidate = { [unowned fixture] in
            fixture.client.beginContinuation?.resume(throwing: DesktopCrashSupervisorControlIPCError.invalidated)
            fixture.client.beginContinuation = nil
        }
        let beginTask = Task { try await fixture.controller.begin() }
        while !fixture.client.beginEntered { await Task.yield() }

        let stopped = await fixture.controller.stop()
        let beginFailed = (try? await beginTask.value) == nil

        #expect(!stopped)
        #expect(beginFailed)
        #expect(fixture.client.events.suffix(1).elementsEqual(["invalidate"]))
        #expect(!fixture.client.events.contains("end"))
        #expect(fixture.controller.state == .needsAttention)
        #expect(await fixture.controller.stop() == false)
        #expect(fixture.controller.state == .needsAttention)
        #expect(!fixture.controller.permitsExecution)
    }

    @Test func stopDuringGuiPreparationInvalidatesBeforeReturning() async throws {
        let fixture = LockedRuntimeControllerFixture()
        fixture.prepareHook = { [unowned fixture] _, _, _ in
            try await withCheckedThrowingContinuation { continuation in
                fixture.prepareContinuation = continuation
            }
        }
        let beginTask = Task { try await fixture.controller.begin() }
        while fixture.prepareCount == 0 { await Task.yield() }

        let stopped = await fixture.controller.stop()

        #expect(!stopped)
        #expect(fixture.controller.state == .needsAttention)
        #expect(await fixture.controller.stop() == false)
        #expect(fixture.controller.state == .needsAttention)
        #expect(fixture.client.events.last == "invalidate")
        #expect(!fixture.client.events.contains("end"))
        #expect(!fixture.controller.permitsExecution)

        fixture.prepareContinuation?.resume(returning: true)
        await #expect(throws: DesktopLockedControlRuntimeController.Failure.invalidScope) {
            try await beginTask.value
        }
    }
}

@Test @MainActor
func desktopLockedRuntimeStopPublishesAuthorityLossBeforeAsyncCleanup() async throws {
    let fixture = LockedRuntimeControllerFixture()
    try await fixture.controller.begin()
    var observed: [DesktopLockedControlRuntimeController.State] = []
    fixture.controller.onStateChange = { observed.append($0) }
    fixture.controller.requestStop()
    #expect(observed.first == .stopping)
    #expect(!fixture.controller.permitsExecution)
    #expect(await fixture.controller.stop())
    #expect(observed.last == .idle)
}
