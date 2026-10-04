import AppKit
import Carbon
import PersonaStackCore

/// The exposed Cua set_value fallback sends Apple Events to Safari. Other
/// BrowserJS targets belong to upstream page tools that PersonaStack omits.
enum DesktopBrowserPermission {
    static let safariBundleIdentifier = "com.apple.Safari"
    static let javascriptInstructions = "In Safari Settings → Advanced, enable Show features for web developers. Then open Developer → Automation and enable Allow JavaScript from Apple Events. Open a Safari tab and choose Check here."

    @MainActor static func automation(prompt: Bool) async -> OSStatus {
        guard !Task.isCancelled else { return OSStatus(userCanceledErr) }
        if prompt && safariProcessIdentifier() == nil {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: safariBundleIdentifier) else { return OSStatus(procNotFound) }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            guard (try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)) != nil else { return OSStatus(procNotFound) }
        }
        guard !Task.isCancelled else { return OSStatus(userCanceledErr) }
        return await Task.detached {
            let target = NSAppleEventDescriptor(bundleIdentifier: safariBundleIdentifier)
            return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, prompt)
        }.value
    }

    @MainActor static func safariProcessIdentifier() -> Int32? {
        NSRunningApplication.runningApplications(withBundleIdentifier: safariBundleIdentifier).first?.processIdentifier
    }

    @MainActor static func openSafari() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: safariBundleIdentifier) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    /// Explicit Check only, after non-prompting Automation preflight. The fixed
    /// expression reads no page content and changes no page or browser setting.
    static func verifyJavaScript() async -> Bool {
        let runner = SystemCuaProcessRunner(timeout: 5, outputLimit: 1024)
        let script = """
        with timeout of 3 seconds
            tell application id "com.apple.Safari"
                return do JavaScript "1" in front document
            end tell
        end timeout
        """
        return await Task.detached {
            guard let result = try? runner.run(URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-e", script]) else { return false }
            return result.status == 0 && String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        }.value
    }
}
