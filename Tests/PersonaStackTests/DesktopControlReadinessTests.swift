import Foundation
import Testing
import PersonaStackCore

@testable import PersonaStack

@MainActor
@Test func cuaFailuresMapToFiniteDesktopReadiness() {
    #expect(DesktopControlRuntime.readiness(for: CuaMCPProxyError.permissionsRequired) == "permission_required")
    #expect(DesktopControlRuntime.readiness(for: CuaMCPProxyError.functionalProbeFailed) == "cua_unavailable")
    #expect(DesktopControlRuntime.readiness(for: CuaMCPProxyError.processExited) == "cua_unavailable")
    #expect(DesktopControlRuntime.readiness(for: DesktopControlGatewayConnectionError.upgradeRequired) == "upgrade_required")
    #expect(CuaMCPProxyError.serviceRunning.localizedDescription.contains("will not terminate CuaDriver.app"))
    #expect(DesktopControlRuntime.readiness(for: DesktopControlEnrollmentError.rejected) == "cua_unavailable")
    #expect(!DesktopControlRuntime.shouldForceRepair(after: CuaMCPProxyError.permissionsRequired))
    #expect(!DesktopControlRuntime.shouldForceRepair(after: CuaMCPProxyError.serviceRunning))
    #expect(!DesktopControlRuntime.shouldForceRepair(after: CancellationError()))
    #expect(DesktopControlRuntime.shouldForceRepair(after: CuaMCPProxyError.functionalProbeFailed))
}

@MainActor
@Test func desktopCommandsRequireTheCurrentConnectionAndAnActiveLifecycle() {
    let currentConnection = UUID()
    #expect(DesktopControlRuntime.acceptsCommand(
        connectionID: currentConnection,
        currentConnectionID: currentConnection,
        disconnecting: false
    ))
    #expect(!DesktopControlRuntime.acceptsCommand(
        connectionID: UUID(),
        currentConnectionID: currentConnection,
        disconnecting: false
    ))
    #expect(!DesktopControlRuntime.acceptsCommand(
        connectionID: currentConnection,
        currentConnectionID: currentConnection,
        disconnecting: true
    ))
}
