import Foundation
import PersonaStackCore
import Testing
@testable import PersonaStack

private struct DisconnectInstaller: DesktopControlDriverInstalling {
    func validateOrInstall(repair: Bool,
        commitManagedInstall: (@MainActor @Sendable (URL, URL, Bool) throws -> Void)?) async throws -> CuaDriverInstallation {
        throw CuaDriverInstallError.invalidLayout
    }
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
    guard case .object(let result)? = acquired.result, case .string(let token)? = result["control_token"] else {
        Issue.record("missing control token"); return
    }
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("fixture".utf8).write(to: path)
    defer { try? FileManager.default.removeItem(at: path) }
    #expect(await executor.handle(command("desktop_control_file", ["control_token": .string(token),
        "action": .string("open"), "path": .string(path.path)]), proxy: nil).type == "result")
    #expect(await executor.handle(command("desktop_control_execute", ["control_token": .string(token),
        "command": .string("sleep 30"), "working_directory": .string("/tmp")]), proxy: nil).type == "result")
    await runtime.gatewayDisconnected(connectionID: UUID(), error: nil)
    #expect(await executor.diagnostics().openFileHandles == 1)
    #expect(await executor.diagnostics().activeProcesses == 1)
    await runtime.gatewayDisconnected(connectionID: connectionID, error: nil)
    #expect(await executor.diagnostics().openFileHandles == 0)
    #expect(await executor.diagnostics().activeProcesses == 0)
    #expect(await executor.handle(command("desktop_control_acquire"), proxy: nil).errorCode == "desktop_executor_unavailable")
}
