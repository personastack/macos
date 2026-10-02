import Foundation
import Testing
import PersonaStackCore
@testable import PersonaStack

@Suite @MainActor
struct DesktopControlActivityTests {
    @Test func activityFollowsTheExclusiveLeaseAndClearsOnReleaseExpiryAndStop() async throws {
        var clock = ContinuousClock.now
        let executor = DesktopControlCommandExecutor(now: { clock }, powerAssertion: .init(create: { 1 }, release: { _ in true }))
        let first = owner("one", label: "A persona")
        let second = owner("two", label: "Another persona")
        let acquired = await executor.handle(command("desktop_control_acquire", first), proxy: nil)
        let token = try controlToken(acquired)
        let lease = try #require(executor.currentLease)
        #expect(lease.token == UUID(uuidString: token))
        #expect(lease.personaID == first.personaID && lease.configVersion == first.configVersion)
        #expect(lease.expires == clock + .seconds(90))
        #expect(executor.presentationActivity?.ownerLabel == "A persona · Test workspace")

        let rival = await executor.handle(command("desktop_control_acquire", second), proxy: nil)
        #expect(rival.errorCode == "desktop_busy")
        #expect(executor.currentLease == lease)
        #expect(executor.presentationActivity?.ownerLabel == "A persona · Test workspace")
        clock += .seconds(61)
        #expect(executor.presentationActivity?.elapsedLabel == "1 min")
        let released = await executor.handle(command("desktop_control_release", first, token: token), proxy: nil)
        #expect(released.type == "result")
        #expect(executor.currentLease == nil)
        #expect(executor.presentationActivity == nil)

        _ = await executor.handle(command("desktop_control_acquire", second), proxy: nil)
        #expect(executor.presentationActivity?.personaName == "Another persona")
        clock += .seconds(91)
        #expect(executor.currentLease == nil)
        #expect(executor.presentationActivity == nil)
        _ = await executor.handle(command("desktop_control_acquire", first), proxy: nil)
        #expect(executor.presentationActivity?.personaName == "A persona")
        #expect(await executor.close())
        #expect(executor.presentationActivity == nil)
    }

    @Test func missingDisplayMetadataUsesGenericIdentityAndRevocationClearsIt() async {
        let executor = DesktopControlCommandExecutor(powerAssertion: .init(create: { 1 }, release: { _ in true }))
        let target = owner("one", label: nil)
        _ = await executor.handle(command("desktop_control_acquire", target), proxy: nil)
        #expect(executor.presentationActivity?.ownerLabel == "An authorized persona")
        let revoked = DesktopControlTarget(installationID: "installation", workspaceID: "workspace", configID: "config",
                                           personaID: "one", runID: "", generation: 1, configVersion: 1)
        let result = await executor.handle(command("desktop_control_revoke_binding", revoked), proxy: nil)
        #expect(result.type == "result")
        #expect(executor.currentLease == nil)
        #expect(executor.presentationActivity == nil)
        #expect(await executor.close())
    }

    private func owner(_ persona: String, label: String?) -> DesktopControlTarget {
        DesktopControlTarget(installationID: "installation", workspaceID: "workspace", configID: "config",
                             personaID: persona, runID: "run", generation: 1, configVersion: 1,
                             ownerDisplay: label.map { .init(personaName: $0, workspaceName: "Test workspace") })
    }

    private func command(_ operation: String, _ target: DesktopControlTarget, token: String? = nil) -> DesktopControlFrame {
        DesktopControlFrame(type: "command", requestID: UUID().uuidString, target: target, operation: operation,
                            arguments: .object(token.map { ["control_token": .string($0)] } ?? [:]),
                            deadlineAt: Date().addingTimeInterval(30))
    }

    private func controlToken(_ frame: DesktopControlFrame) throws -> String {
        guard case .object(let result)? = frame.result, case .string(let token)? = result["control_token"] else {
            throw CocoaError(.coderValueNotFound)
        }
        return token
    }
}
