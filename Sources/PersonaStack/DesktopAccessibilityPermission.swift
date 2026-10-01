import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics

/// Content-free permission readback in PersonaStack's own process.
/// An AX role read can establish access when the process trust flag is stale.
/// Never prompts, posts events, changes focus, or reads application content.
@MainActor
enum DesktopAccessibilityPermission {
    static func isGranted(
        trusted: @MainActor () -> Bool = currentProcessTrusted,
        readRole: @MainActor () -> Bool = canReadApplicationRole,
        canPostEvents: @MainActor () -> Bool = { CGPreflightPostEventAccess() }
    ) -> Bool {
        trusted() || (readRole() && canPostEvents())
    }

    static func currentProcessTrusted() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func canReadApplicationRole() -> Bool {
        guard let application = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.finder" && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }) else { return false }
        let element = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.25)
        var role: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        return roleReadGranted(result: result, role: role as? String)
    }

    static func roleReadGranted(result: AXError, role: String?) -> Bool {
        result == .success && role == (kAXApplicationRole as String)
    }

    static func printDiagnostics() {
        let trusted = currentProcessTrusted()
        let readable = canReadApplicationRole()
        let postEvents = CGPreflightPostEventAccess()
        print("accessibility_trust_flag=\(AXIsProcessTrusted())")
        print("accessibility_trust_without_prompt=\(trusted)")
        print("accessibility_application_role_read=\(readable)")
        print("event_posting_allowed=\(postEvents)")
        print("screen_capture_allowed=\(CGPreflightScreenCaptureAccess())")
        print("accessibility_granted=\(isGranted(trusted: { trusted }, readRole: { readable }, canPostEvents: { postEvents }))")
    }
}
