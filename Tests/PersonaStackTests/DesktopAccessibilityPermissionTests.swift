import ApplicationServices
import PersonaStackCore
import Testing
@testable import PersonaStack

@Test @MainActor func accessibilityTrustDoesNotReadAnotherApplicationWhenAlreadyGranted() {
    let granted = DesktopAccessibilityPermission.isGranted(trusted: { true }, readRole: {
        Issue.record("An existing trust grant needs no role read")
        return false
    })
    #expect(granted)
}

@Test @MainActor func accessibilityReadbackDetectsStaleTrustAndLaterRevocation() {
    var roleReadable = true
    let check = { DesktopAccessibilityPermission.isGranted(trusted: { false }, readRole: { roleReadable }) }
    #expect(check())
    roleReadable = false
    #expect(!check())
}

@Test(arguments: [AXError.apiDisabled, .cannotComplete, .invalidUIElement, .attributeUnsupported, .noValue, .failure])
@MainActor func accessibilityErrorsNeverEstablishPermission(result: AXError) {
    #expect(!DesktopAccessibilityPermission.roleReadGranted(result: result, role: "AXApplication"))
}

@Test @MainActor func accessibilityRoleReadRequiresAnActualApplicationRole() {
    #expect(DesktopAccessibilityPermission.roleReadGranted(result: .success, role: "AXApplication"))
    #expect(!DesktopAccessibilityPermission.roleReadGranted(result: .success, role: nil))
    #expect(!DesktopAccessibilityPermission.roleReadGranted(result: .success, role: "AXWindow"))
    let granted = DesktopAccessibilityPermission.isGranted(trusted: { false }, readRole: { false })
    #expect(!granted)
}

@Test @MainActor func accessibilityRoleReadMakesChecklistReadyWithoutSetupActions() async {
    var roleReadable = true
    var access = DesktopPermissionSystemAccess()
    access.accessibility = {
        DesktopAccessibilityPermission.isGranted(trusted: { false }, readRole: { roleReadable })
    }
    access.requestAccessibility = { Issue.record("Confirmed access must not request permission") }
    let adapter = DesktopPermissionChecklistSystemAdapter(hooks: .init(
        setup: { _ in Issue.record("Accessibility must not invoke Cua"); return nil },
        verifyAutomatically: { _ in Issue.record("Accessibility must not invoke Cua"); return nil }
    ), access: access, openSettings: { _ in Issue.record("Confirmed access must not open Settings") })
    let observed = await adapter.observe(.accessibility)
    let presented = await adapter.setupAutomatically(.accessibility)
    let retried = await adapter.setup(.accessibility)
    #expect(observed.state == .ready && observed.verified)
    #expect(presented.state == .ready && retried.state == .ready)
    #expect(adapter.screenCaptureAccessibilityObservation() == nil)
    roleReadable = false
    let revoked = await adapter.observe(.accessibility)
    #expect(revoked.state == .notGranted && !revoked.verified)
    #expect(adapter.screenCaptureAccessibilityObservation()?.state == .verificationRequired)
}
