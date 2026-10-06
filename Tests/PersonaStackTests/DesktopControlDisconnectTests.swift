import Foundation
import PersonaStackCore
import Testing
@testable import PersonaStack

private struct DisconnectInstaller: DesktopControlDriverInstalling {
    func discoverExisting() async throws -> CuaDriverInstallation? { nil }
    func install() async throws -> CuaDriverInstallation { throw CuaDriverInstallError.invalidLayout }

}

private struct DisconnectCredentials: DesktopControlCredentialStoring {
    func save(_ installation: DesktopControlInstallation) throws {}
    func load() throws -> DesktopControlInstallation? { nil }
    func delete() throws {}
}

@Test @MainActor
func currentGatewayDisconnectClosesOwnedResourcesAndStaleDisconnectDoesNothing() async throws {
    let executor = DesktopControlCommandExecutor()
    let connectionID = UUID()
    let runtime = DesktopControlRuntime.makeForTesting(installer: DisconnectInstaller(),
        credentials: DisconnectCredentials(), executor: executor, connectionID: connectionID)
    let target = DesktopControlTarget(installationID: "install", workspaceID: "workspace", configID: "config",
        personaID: "persona", runID: "run", generation: 1)
    func command(_ operation: String, _ args: [String: DesktopControlJSONValue] = [:]) -> DesktopControlFrame {
        DesktopControlFrame(type: "command", requestID: UUID().uuidString, target: target,
            operation: operation, arguments: .object(args), deadlineAt: Date().addingTimeInterval(30))
    }
    let acquired = await executor.handle(command("desktop_control_acquire"), proxy: nil)
    #expect(acquired.type == "result")
    let lease = try #require(executor.currentLease)
    await runtime.gatewayDisconnected(connectionID: UUID(), error: nil)
    #expect(executor.currentLease == lease)
    await runtime.gatewayDisconnected(connectionID: connectionID, error: nil)
    #expect(executor.currentLease == nil)
    #expect(await executor.handle(command("desktop_control_acquire"), proxy: nil).errorCode == "desktop_executor_unavailable")
}
