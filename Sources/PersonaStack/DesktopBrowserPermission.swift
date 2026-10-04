import AppKit
import Carbon
import PersonaStackCore
import Security

/// Safari Apple Events are target-specific. Native profile consent does not
/// replace these macOS and browser settings.
enum DesktopBrowserPermission {
    static let safariBundleIdentifier = "com.apple.Safari"
    static let javascriptInstructions = "In Safari Settings → Advanced, enable Show features for web developers. Then open Developer → Automation and enable Allow JavaScript from Apple Events. Return to PersonaStack for automatic verification. If Safari has no document, PersonaStack opens a blank test tab and leaves it open."

    @MainActor static func automation(bundleIdentifier: String = safariBundleIdentifier, prompt: Bool) async -> OSStatus {
        guard [safariBundleIdentifier, "com.google.Chrome", "com.microsoft.edgemac"].contains(bundleIdentifier) else { return OSStatus(paramErr) }
        guard !Task.isCancelled else { return OSStatus(userCanceledErr) }
        if prompt && NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty {
            guard bundleIdentifier == safariBundleIdentifier else { return OSStatus(procNotFound) }
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: safariBundleIdentifier) else { return OSStatus(procNotFound) }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            guard (try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)) != nil else { return OSStatus(procNotFound) }
        }
        guard !Task.isCancelled else { return OSStatus(userCanceledErr) }
        return await Task.detached {
            let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
            return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, prompt)
        }.value
    }

    @MainActor static func safariProcessIdentifier() -> Int32? {
        NSRunningApplication.runningApplications(withBundleIdentifier: safariBundleIdentifier).first?.processIdentifier
    }

    @MainActor static func safariProcessIdentity() -> DesktopSafariProcessIdentity? {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: safariBundleIdentifier)
        guard applications.count == 1, let application = applications.first, !application.isTerminated,
              let launchedAt = application.launchDate, let code = codeIdentity(pid: application.processIdentifier) else { return nil }
        return DesktopSafariProcessIdentity(pid: application.processIdentifier, launchedAt: launchedAt, codeIdentity: code)
    }

    static func codeIdentity(pid: Int32) -> String? {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code, SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess,
              let values = information as? [String: Any],
              let digest = values[kSecCodeInfoUnique as String] as? Data else { return nil }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    @MainActor static func openSafari() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: safariBundleIdentifier) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    /// Within an explicit setup or diagnostic intent only, after non-prompting Automation preflight. The fixed
    /// expression reads no page content and changes no browser setting. Safari
    /// receives a blank test document only when it has no existing document.
    @MainActor static func verifyJavaScript(bundleIdentifier: String = safariBundleIdentifier, expectedPID: Int32? = nil,
                                            processRunner: any CuaProcessRunning = SystemCuaProcessRunner(timeout: 5, outputLimit: 1024)) async -> Bool {
        guard [safariBundleIdentifier, "com.google.Chrome", "com.microsoft.edgemac"].contains(bundleIdentifier) else { return false }
        if let expectedPID {
            let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            guard applications.count == 1, applications.first?.processIdentifier == expectedPID else { return false }
        }
        guard let script = javaScriptVerificationScript(bundleIdentifier: bundleIdentifier) else { return false }
        return await Task.detached {
            guard let result = try? processRunner.run(URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-e", script]) else { return false }
            return result.status == 0 && String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        }.value
    }
    static func javaScriptVerificationScript(bundleIdentifier: String) -> String? {
        guard [safariBundleIdentifier, "com.google.Chrome", "com.microsoft.edgemac"].contains(bundleIdentifier) else { return nil }
        let expression = bundleIdentifier == safariBundleIdentifier ? """
            if (count of documents) is 0 then
                set verificationDocument to make new document with properties {URL:"about:blank"}
            else
                set verificationDocument to front document
            end if
            return do JavaScript "1" in verificationDocument
            """ : "return execute active tab of front window javascript \"1\""
        return """
        with timeout of 3 seconds
            tell application id "\(bundleIdentifier)"
                \(expression)
            end tell
        end timeout
        """
    }

}

/// Validates the pinned browser_prepare and end_session outputs without reading
/// page content. A nonerror MCP response alone does not establish attachment.
enum DesktopBrowserHandshakeValidation {
    static func requirePrepared(_ data: Data, pid: Int32) throws {
        let result = try structuredResult(data)
        guard pid > 0,
              result["status"] == .string("ok"), result["prepared"] == .bool(true),
              result["prepared_pid"] == .number(Double(pid)),
              result["action"] == .string("attached_existing_profile"),
              case .object(let ownership)? = result["endpoint_ownership"],
              ownership["owner_pid"] == .number(Double(pid)),
              case .string(let method)? = ownership["method"],
              ["listening_socket_pid", "devtools_active_ports_file", "platform_attested"].contains(method),
              case .object(let attachment)? = result["attachment"],
              attachment["kind"] == .string("existing_profile"),
              attachment["browser"] == .string("chromium"),
              attachment["capabilities_invalidated"] == .bool(true),
              attachment["next_action"] == .string("get_browser_state") else {
            throw CuaMCPProxyError.permissionsRequired
        }
    }

    static func requireEnded(_ data: Data, session: String) throws {
        let result = try structuredResult(data)
        guard !session.isEmpty, result["session"] == .string(session), result["active"] == .bool(false) else {
            throw CuaMCPProxyError.permissionsRequired
        }
    }

    private static func structuredResult(_ data: Data) throws -> [String: DesktopControlJSONValue] {
        guard case .object(let envelope) = try JSONDecoder().decode(DesktopControlJSONValue.self, from: data),
              envelope["error"] == nil, case .object(let result)? = envelope["result"],
              result["isError"] == nil || result["isError"] == .bool(false),
              case .object(let structured)? = result["structuredContent"] else {
            throw CuaMCPProxyError.permissionsRequired
        }
        return structured
    }
}
