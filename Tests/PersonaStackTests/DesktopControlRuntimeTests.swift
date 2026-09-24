import Foundation
import PersonaStackCore
import Testing
@testable import PersonaStack

private actor DesktopControlInstallerFixture: DesktopControlDriverInstalling {
    private let errors: [any Error]
    private(set) var repairArguments: [Bool] = []

    init(errors: [any Error]) { self.errors = errors }

    func validateOrInstall(
        repair: Bool,
        commitManagedInstall: (@MainActor @Sendable (URL, URL, Bool) throws -> Void)?
    ) async throws -> CuaDriverInstallation {
        repairArguments.append(repair)
        guard let error = errors.indices.contains(repairArguments.count - 1) ? errors[repairArguments.count - 1] : nil else {
            throw CuaDriverInstallError.invalidLayout
        }
        throw error
    }
}

private struct EmptyDesktopControlCredentialStore: DesktopControlCredentialStoring {
    func save(_ installation: DesktopControlInstallation) throws {}
    func load() throws -> DesktopControlInstallation? { nil }
    func delete() throws {}
}

@Test @MainActor func repairDoesNotForceReinstallWhenCuaNeedsPermission() async throws {
    let installer = DesktopControlInstallerFixture(errors: [CuaMCPProxyError.permissionsRequired])
    let runtime = DesktopControlRuntime(installer: installer, credentials: EmptyDesktopControlCredentialStore())

    await #expect(throws: CuaMCPProxyError.permissionsRequired) {
        try await runtime.repair()
    }

    #expect(await installer.repairArguments == [false])
    #expect(runtime.readiness == "permission_required")
}

@Test @MainActor func repairAllowsOnlyOneForcedInstallAfterRetryableFailure() async throws {
    let installer = DesktopControlInstallerFixture(errors: [CuaDriverInstallError.invalidLayout, CuaDriverInstallError.invalidLayout])
    let runtime = DesktopControlRuntime(installer: installer, credentials: EmptyDesktopControlCredentialStore())

    await #expect(throws: CuaDriverInstallError.invalidLayout) {
        try await runtime.repair()
    }

    #expect(await installer.repairArguments == [false, true])
    #expect(runtime.readiness == "cua_unavailable")
}

@Test @MainActor func setupBridgeAllowsPermissionRetryWithoutForcingInstall() async throws {
    let installer = DesktopControlInstallerFixture(errors: [
        CuaMCPProxyError.permissionsRequired,
        CuaMCPProxyError.permissionsRequired,
    ])
    let runtime = DesktopControlRuntime(installer: installer, credentials: EmptyDesktopControlCredentialStore())
    let manager = DesktopControlSetupManager(runtime: runtime)
    let page = DesktopControlSetupManager.Page(appURL: URL(string: "https://personastack.ai")!)
    page.setupScope.synchronize("workspace-setup-session")
    let command = DesktopControlSetupCommand.prepare(
        scope: "workspace-setup-session",
        enrollmentTicket: String(repeating: "a", count: 43)
    )

    for _ in 0..<2 {
        do {
            _ = try await manager.apply(command, page: page)
            Issue.record("permission denial should leave setup available for another attempt")
        } catch let error as CuaMCPProxyError {
            #expect(error == .permissionsRequired)
        } catch {
            Issue.record("unexpected setup error: \(error)")
        }
    }

    #expect(await installer.repairArguments == [false, false])
    #expect(runtime.readiness == "permission_required")
}
