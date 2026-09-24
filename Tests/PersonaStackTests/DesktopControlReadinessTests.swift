import Testing
import PersonaStackCore

@testable import PersonaStack

@MainActor
@Test func cuaFailuresMapToFiniteDesktopReadiness() {
    #expect(DesktopControlRuntime.readiness(for: CuaMCPProxyError.permissionsRequired) == "permission_required")
    #expect(DesktopControlRuntime.readiness(for: CuaMCPProxyError.functionalProbeFailed) == "cua_unavailable")
    #expect(DesktopControlRuntime.readiness(for: CuaMCPProxyError.processExited) == "cua_unavailable")
    #expect(DesktopControlRuntime.readiness(for: DesktopControlEnrollmentError.rejected) == "cua_unavailable")
}
