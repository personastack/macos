import Foundation
import PersonaStackCore
import Testing
@testable import PersonaStack

private actor RecoveryProbeObservations {
    var disconnects = 0
    func disconnected() { disconnects += 1 }
}

private final class RecoveryPingFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: [@Sendable (Bool) -> Void] = []
    func ping(_ callback: @escaping @Sendable (Bool) -> Void) {
        lock.lock(); defer { lock.unlock() }
        callbacks.append(callback)
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return callbacks.count }
    func complete(_ healthy: Bool) {
        lock.lock(); let callback = callbacks.last; lock.unlock()
        callback?(healthy)
    }
}

private func recoveryConnection(_ observations: RecoveryProbeObservations) throws -> DesktopControlGatewayConnection {
    let profile = DesktopEnvironmentConfiguration.production
    let installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: JSONSerialization.data(withJSONObject: [
        "installation_id": "fixture", "machine_credential": String(repeating: "A", count: 43),
        "gateway_websocket_url": profile.gatewayWebsocketURL.absoluteString, "environment_origin": profile.appOrigin,
    ]))
    return DesktopControlGatewayConnection(installation: installation,
        onDisconnect: { _ in await observations.disconnected() }) { _, _ in
        Issue.record("Recovery must not execute or replay commands")
        return DesktopControlFrame(type: "failure")
    }
}

@Test func desktopRecoveryProbeKeepsHealthyConnectionAndCoalescesEvents() async throws {
    let observations = RecoveryProbeObservations()
    let fixture = RecoveryPingFixture()
    let connection = try recoveryConnection(observations)
    await connection.configureRecoveryProbeForTesting(ping: { fixture.ping($0) })
    await connection.checkConnectionAfterRecovery()
    await connection.checkConnectionAfterRecovery()
    #expect(fixture.count == 1)
    fixture.complete(true)
    for _ in 0..<1000 {
        if !(await connection.hasRecoveryProbeForTesting()) { break }
        await Task.yield()
    }
    #expect(await connection.isConnected())
    #expect(await observations.disconnects == 0)
    #expect(!(await connection.hasRecoveryProbeForTesting()))
    await connection.stop()
}

@Test(arguments: [false, true]) func desktopRecoveryProbeTimeoutDisconnectsOnceAndIgnoresLatePong(explicitFailure: Bool) async throws {
    let observations = RecoveryProbeObservations()
    let fixture = RecoveryPingFixture()
    let connection = try recoveryConnection(observations)
    await connection.configureRecoveryProbeForTesting(timeout: .milliseconds(1), ping: { fixture.ping($0) })
    await connection.checkConnectionAfterRecovery()
    if explicitFailure { fixture.complete(false) }
    try await Task.sleep(for: .milliseconds(20))
    #expect(!(await connection.isConnected()))
    #expect(await observations.disconnects == 1)
    fixture.complete(true)
    await Task.yield()
    #expect(!(await connection.isConnected()))
    #expect(await observations.disconnects == 1)
    await connection.stop()
}

@Test func desktopRecoveryProbeFailureAndStopFenceOutstandingCallbacks() async throws {
    let observations = RecoveryProbeObservations()
    let fixture = RecoveryPingFixture()
    let connection = try recoveryConnection(observations)
    await connection.configureRecoveryProbeForTesting(ping: { fixture.ping($0) })
    await connection.checkConnectionAfterRecovery()
    await connection.stop()
    fixture.complete(false)
    await Task.yield()
    #expect(await observations.disconnects == 0)
    #expect(!(await connection.isConnected()))
    await connection.checkConnectionAfterRecovery()
    #expect(fixture.count == 1)
}
