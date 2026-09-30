import Foundation
import PersonaStackCore
import Testing
@testable import PersonaStack

extension DesktopControlPowerAssertion {
    static func testFixture() -> DesktopControlPowerAssertion {
        .init(create: { 1 }, release: { $0 == 1 })
    }
}

private final class PowerFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var nextID: UInt32 = 1
    private var active: Set<UInt32> = []
    private var creates = 0
    private var releases: [UInt32] = []
    private var creationAllowed = true
    private var releaseFailures = 0
    private var unexpected = 0

    var snapshot: (creates: Int, releases: [UInt32], active: Set<UInt32>, unexpected: Int) {
        lock.withLock { (creates, releases, active, unexpected) }
    }

    func denyCreation(_ denied: Bool) { lock.withLock { creationAllowed = !denied } }
    func failNextRelease() { lock.withLock { releaseFailures += 1 } }

    func assertion() -> DesktopControlPowerAssertion {
        .init(create: { [self] in
            lock.withLock {
                creates += 1
                guard creationAllowed else { return nil }
                let id = nextID
                nextID += 1
                active.insert(id)
                return id
            }
        }, release: { [self] id in
            lock.withLock {
                releases.append(id)
                guard active.contains(id) else { unexpected += 1; return false }
                if releaseFailures > 0 { releaseFailures -= 1; return false }
                active.remove(id)
                return true
            }
        })
    }
}

private struct PowerInstallerFixture: DesktopControlDriverInstalling {
    func validateOrInstall(repair: Bool,
        commitManagedInstall: (@MainActor @Sendable (URL, URL, Bool) throws -> Void)?) async throws -> CuaDriverInstallation {
        Issue.record("Power cleanup unexpectedly requested installation")
        throw CuaDriverInstallError.invalidLayout
    }
}

private struct PowerCredentialsFixture: DesktopControlCredentialStoring {
    func save(_ installation: DesktopControlInstallation) throws { Issue.record("Unexpected credential save") }
    func load() throws -> DesktopControlInstallation? { Issue.record("Unexpected credential read"); return nil }
    func delete() throws { Issue.record("Unexpected credential delete") }
}

private actor PowerCleanupGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@Suite @MainActor
struct DesktopControlPowerAssertionTests {
    private func owner(persona: String = "persona", version: Int64 = 1) -> DesktopControlTarget {
        .init(installationID: "install", workspaceID: "workspace", configID: "config",
              personaID: persona, runID: "run", generation: 1, configVersion: version)
    }

    private func frame(_ operation: String, _ target: DesktopControlTarget,
                       token: String? = nil) -> DesktopControlFrame {
        .init(type: "command", requestID: UUID().uuidString, target: target, operation: operation,
              arguments: .object(token.map { ["control_token": .string($0)] } ?? [:]),
              deadlineAt: Date().addingTimeInterval(30))
    }

    private func acquire(_ executor: DesktopControlCommandExecutor, _ target: DesktopControlTarget) async throws -> String {
        let response = await executor.handle(frame("desktop_control_acquire", target), proxy: nil)
        let result = try #require(response.result)
        guard case .object(let values) = result, case .string(let token)? = values["control_token"] else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        return token
    }

    @Test func assertionRenewalIsIdempotentAndFailedReleaseRetainsItsExactID() {
        let fixture = PowerFixture()
        let assertion = fixture.assertion()
        #expect(assertion.acquire() && assertion.acquire())
        #expect(fixture.snapshot.creates == 1)
        fixture.failNextRelease()
        #expect(!assertion.relinquish() && assertion.isHeld)
        #expect(assertion.relinquish() && !assertion.isHeld)
        #expect(assertion.relinquish())
        #expect(fixture.snapshot.releases == [1, 1])
        #expect(fixture.snapshot.active.isEmpty && fixture.snapshot.unexpected == 0)
    }

    @Test func creationFailureAndZeroIDCannotBecomeHeld() {
        let fixture = PowerFixture()
        fixture.denyCreation(true)
        let assertion = fixture.assertion()
        #expect(!assertion.acquire() && !assertion.isHeld)
        #expect(assertion.relinquish())
        #expect(fixture.snapshot.releases.isEmpty && fixture.snapshot.active.isEmpty)
        let zero = DesktopControlPowerAssertion(create: { 0 }, release: { _ in
            Issue.record("An invalid assertion ID was released")
            return false
        })
        #expect(!zero.acquire() && !zero.isHeld)
    }

    @Test func ownerDeallocationReleasesOnlyItsAssertion() {
        let fixture = PowerFixture()
        var assertion: DesktopControlPowerAssertion? = fixture.assertion()
        #expect(assertion?.acquire() == true)
        assertion = nil
        #expect(fixture.snapshot.releases == [1] && fixture.snapshot.active.isEmpty)
        #expect(fixture.snapshot.unexpected == 0)
    }

    @Test func explicitSetupProbeDoesNotReleaseConcurrentTaskAssertion() {
        let fixture = PowerFixture()
        let task = fixture.assertion()
        #expect(task.acquire())
        #expect(DesktopControlPowerAssertion.verifyAvailability(makeAssertion: fixture.assertion))
        #expect(task.isHeld && fixture.snapshot.active == [1])
        #expect(fixture.snapshot.creates == 2 && fixture.snapshot.releases == [2])
        #expect(task.relinquish())
        #expect(fixture.snapshot.releases == [2, 1] && fixture.snapshot.unexpected == 0)
    }

    @Test func incompleteSetupProbeCannotReportAvailable() {
        let fixture = PowerFixture()
        fixture.denyCreation(true)
        #expect(!DesktopControlPowerAssertion.verifyAvailability(makeAssertion: fixture.assertion))
        #expect(fixture.snapshot.releases.isEmpty)
        fixture.denyCreation(false)
        fixture.failNextRelease()
        #expect(!DesktopControlPowerAssertion.verifyAvailability(makeAssertion: fixture.assertion))
        #expect(fixture.snapshot.releases == [1, 1] && fixture.snapshot.active.isEmpty)
    }

    @Test func leaseRenewalRivalsAndBadReleaseCannotReplaceOrReleasePower() async throws {
        let fixture = PowerFixture()
        let executor = DesktopControlCommandExecutor(powerAssertion: fixture.assertion())
        let target = owner()
        let token = try await acquire(executor, target)
        #expect(try await acquire(executor, target) == token)
        let rival = await executor.handle(frame("desktop_control_acquire", owner(persona: "rival")), proxy: nil)
        #expect(rival.errorCode == "desktop_busy")
        let badRelease = await executor.handle(frame("desktop_control_release", target, token: "wrong"), proxy: nil)
        #expect(badRelease.errorCode == "desktop_control_required")
        let foreignRelease = await executor.handle(frame("desktop_control_release", owner(persona: "rival"), token: token), proxy: nil)
        #expect(foreignRelease.errorCode == "desktop_control_required")
        #expect(fixture.snapshot.creates == 1 && fixture.snapshot.releases.isEmpty)
        #expect(await executor.handle(frame("desktop_control_release", target, token: token), proxy: nil).type == "result")
        #expect(fixture.snapshot.releases == [1] && fixture.snapshot.active.isEmpty)
        _ = try await acquire(executor, owner(persona: "rival"))
        #expect(fixture.snapshot.creates == 2)
        #expect(await executor.close())
        #expect(fixture.snapshot.releases == [1, 2] && fixture.snapshot.unexpected == 0)
    }

    @Test func failedPowerAcquisitionGrantsNoLeaseAndCanRetry() async throws {
        let fixture = PowerFixture()
        fixture.denyCreation(true)
        let executor = DesktopControlCommandExecutor(powerAssertion: fixture.assertion())
        let denied = await executor.handle(frame("desktop_control_acquire", owner()), proxy: nil)
        #expect(denied.type == "failure" && denied.errorCode == "desktop_executor_unavailable")
        #expect(denied.errorMessage?.contains("Awake During Remote Work") == true)
        #expect(denied.result == nil && fixture.snapshot.active.isEmpty)
        let status = await executor.handle(frame("desktop_control_status", owner()), proxy: nil)
        guard case .object(let values)? = status.result else { Issue.record("Missing status"); return }
        #expect(values["busy"] == .bool(false))
        fixture.denyCreation(false)
        _ = try await acquire(executor, owner(persona: "rival"))
        #expect(await executor.close())
        #expect(fixture.snapshot.creates == 2 && fixture.snapshot.releases == [1])
    }

    @Test(arguments: ["desktop_control_revoke_config", "desktop_control_revoke_binding"])
    func scopedRevocationReleasesPowerAndDeniesLaterAcquisition(_ operation: String) async throws {
        let fixture = PowerFixture()
        let executor = DesktopControlCommandExecutor(powerAssertion: fixture.assertion())
        _ = try await acquire(executor, owner())
        let revocation = DesktopControlTarget(installationID: "install", workspaceID: "workspace", configID: "config",
            personaID: operation == "desktop_control_revoke_binding" ? "persona" : "", runID: "",
            generation: operation == "desktop_control_revoke_binding" ? 1 : 0, configVersion: 1)
        #expect(await executor.handle(frame(operation, revocation), proxy: nil).type == "result")
        #expect(fixture.snapshot.releases == [1] && fixture.snapshot.active.isEmpty)
        #expect(await executor.handle(frame("desktop_control_acquire", owner()), proxy: nil).type == "failure")
        #expect(fixture.snapshot.creates == 1)
        #expect(await executor.close())
    }

    @Test(arguments: [91, 1801])
    func idleAndAbsoluteExpiryReleasePower(_ elapsed: Int) async throws {
        let fixture = PowerFixture()
        var clock = ContinuousClock.now
        let executor = DesktopControlCommandExecutor(now: { clock }, powerAssertion: fixture.assertion())
        _ = try await acquire(executor, owner())
        if elapsed == 1801 {
            // Renew only before the hard deadline. Acquisition at that deadline
            // would correctly create a fresh lease after cleaning up the old one.
            for _ in 0..<29 {
                clock += .seconds(60)
                _ = try await acquire(executor, owner())
            }
        }
        clock += .seconds(elapsed == 91 ? 91 : 61)
        await executor.expireLeaseIfNeeded()
        #expect(fixture.snapshot.releases == [1] && fixture.snapshot.active.isEmpty)
        #expect(await executor.close())
    }

    @Test func failedPowerReleaseFencesNewLeasesUntilOwnedCleanupSucceeds() async throws {
        let fixture = PowerFixture()
        let executor = DesktopControlCommandExecutor(powerAssertion: fixture.assertion())
        let token = try await acquire(executor, owner())
        fixture.failNextRelease()
        let release = await executor.handle(frame("desktop_control_release", owner(), token: token), proxy: nil)
        #expect(release.errorCode == "desktop_executor_unavailable")
        #expect(fixture.snapshot.active == [1])
        #expect(await executor.handle(frame("desktop_control_acquire", owner(persona: "rival")), proxy: nil).type == "failure")
        #expect(fixture.snapshot.creates == 1)
        let revoke = DesktopControlTarget(installationID: "install", workspaceID: "workspace", configID: "config",
                                         personaID: "", runID: "", generation: 0, configVersion: 1)
        #expect(await executor.handle(frame("desktop_control_revoke_config", revoke), proxy: nil).type == "result")
        #expect(fixture.snapshot.releases == [1, 1] && fixture.snapshot.active.isEmpty)
        _ = try await acquire(executor, owner(persona: "rival", version: 2))
        #expect(await executor.close())
        #expect(fixture.snapshot.releases == [1, 1, 2] && fixture.snapshot.unexpected == 0)
    }

    @Test func runtimeTerminationRetriesClosedExecutorPowerCleanupWithoutReopeningCommands() async throws {
        let fixture = PowerFixture()
        let power = fixture.assertion()
        let executor = DesktopControlCommandExecutor(powerAssertion: power)
        _ = try await acquire(executor, owner())
        let connectionID = UUID()
        let suite = "desktop-control-power-cleanup-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let runtime = DesktopControlRuntime.makeForTesting(installer: PowerInstallerFixture(),
            credentials: PowerCredentialsFixture(), executor: executor, connectionID: connectionID,
            connected: true, sessionLockState: .unlocked, preferences: preferences)
        #expect(runtime.nativeExecutorReady)
        fixture.failNextRelease()
        await runtime.gatewayDisconnected(connectionID: connectionID, error: nil)
        #expect(!runtime.nativeExecutorReady && power.isHeld)
        #expect(runtime.executorCleanupFailedForTesting)
        #expect(fixture.snapshot.releases == [1])
        #expect(await executor.handle(frame("desktop_control_acquire", owner(persona: "rival")), proxy: nil).type == "failure")

        await runtime.shutdownForQuit()
        #expect(!runtime.executorCleanupFailedForTesting && !power.isHeld)
        #expect(fixture.snapshot.releases == [1, 1] && fixture.snapshot.active.isEmpty)
        #expect(fixture.snapshot.unexpected == 0 && fixture.snapshot.creates == 1)
        #expect(await executor.handle(frame("desktop_control_acquire", owner()), proxy: nil).type == "failure")
    }

    @Test func concurrentCloseJoinsOneOwnedCleanupAndKeepsCommandsFenced() async throws {
        let fixture = PowerFixture()
        let executor = DesktopControlCommandExecutor(powerAssertion: fixture.assertion())
        _ = try await acquire(executor, owner())
        let gate = PowerCleanupGate()
        executor.pauseCleanupBeforeResourceCloseForTesting { await gate.wait() }
        let first = Task { await executor.close() }
        while !(await gate.entered) { await Task.yield() }
        var secondStarted = false
        var secondCompleted = false
        let second = Task {
            secondStarted = true
            let result = await executor.close()
            secondCompleted = true
            return result
        }
        while !secondStarted { await Task.yield() }
        #expect(!secondCompleted)
        #expect(fixture.snapshot.releases == [1] && fixture.snapshot.active.isEmpty)
        #expect(await executor.handle(frame("desktop_control_acquire", owner(persona: "rival")), proxy: nil).type == "failure")
        await gate.release()
        let firstResult = await first.value
        let secondResult = await second.value
        #expect(firstResult && secondResult)
        #expect(await executor.close())
        #expect(fixture.snapshot.releases == [1] && fixture.snapshot.unexpected == 0)
    }
}
