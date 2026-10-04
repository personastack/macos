import Carbon
import Foundation
import PersonaStackCore
import Testing
@testable import PersonaStack

@MainActor @Test(arguments: ["ready", "missingProof", "denied", "wouldPrompt", "wrongPID", "wrongWindow", "restart", "codeChanged", "proofRevoked", "hostChanged"])
func safariPageReadUsesOnlyCurrentAttendedProof(mode: String) async throws {
    let suite = "safari-read-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    var context = DesktopPermissionReceipt.Context(hostIdentity: "host", osVersion: "os", driverIdentity: "driver")
    let evidence = DesktopPermissionEvidence(preferences: preferences, context: { context })
    let original = DesktopSafariProcessIdentity(pid: 123, launchedAt: Date(timeIntervalSince1970: 100), codeIdentity: "signed-safari")
    var identity = original
    if mode != "missingProof" {
        evidence.record([.safariJavaScript: .init(.ready, detail: "attended", verificationKey: original.verificationKey, verified: true)])
    }
    if mode == "codeChanged" { identity = .init(pid: 123, launchedAt: original.launchedAt, codeIdentity: "changed") }
    var queries = 0
    var access = DesktopSafariPageAccess.Access()
    access.identity = { identity }
    access.ownsWindow = { pid, window in pid == 123 && window == 45 && mode != "wrongWindow" }
    access.automation = {
        queries += 1
        if mode == "restart" { identity = .init(pid: 123, launchedAt: Date(timeIntervalSince1970: 200), codeIdentity: original.codeIdentity) }
        if mode == "proofRevoked" { evidence.invalidate(.safariJavaScript) }
        if mode == "hostChanged" { context = .init(hostIdentity: "other-host", osVersion: "os", driverIdentity: "driver") }
        if mode == "denied" { return OSStatus(errAEEventNotPermitted) }
        if mode == "wouldPrompt" { return OSStatus(errAEEventWouldRequireUserConsent) }
        return noErr
    }
    let allowed = await DesktopSafariPageAccess.allowed(pid: mode == "wrongPID" ? 999 : 123, windowID: 45,
                                                       evidence: evidence, access: access)
    #expect(allowed == (mode == "ready"))
    let preflightDenied = ["missingProof", "wrongPID", "wrongWindow", "codeChanged"].contains(mode)
    #expect(queries == (preflightDenied ? 0 : 1))
    if ["denied", "wouldPrompt"].contains(mode) {
        access.automation = { noErr }
        #expect(await DesktopSafariPageAccess.allowed(pid: 123, windowID: 45, evidence: evidence, access: access) == false)
    }
}

@MainActor @Test func safariJavaScriptSetupIdentityRejectsSamePIDNewProcess() async {
    var identity = "safari-javascript:123:launch-1:code-1"
    var access = DesktopPermissionSystemAccess.permissionFixture()
    access.safariProcessIdentifier = { 123 }
    access.safariProcessIdentity = { identity }
    access.automation = { prompt in #expect(!prompt); return noErr }
    access.verifySafariJavaScript = { true }
    let adapter = DesktopPermissionChecklistSystemAdapter(access: access, evidence: nil)
    #expect(await adapter.check(.safariJavaScript).verified)
    identity = "safari-javascript:123:launch-2:code-1"
    #expect(await adapter.observe(.safariJavaScript).state == .verificationRequired)
}

private struct SafariJavaScriptFixtureRunner: CuaProcessRunning {
    let status: Int32
    let output: String
    func run(_ executable: URL, arguments: [String]) throws -> CuaProcessResult {
        #expect(executable.path == "/usr/bin/osascript")
        #expect(arguments.count == 2 && arguments[0] == "-e")
        let script = arguments[1]
        #expect(script.contains("tell application id \"com.apple.Safari\""))
        #expect(script.contains("if (count of documents) is 0 then"))
        #expect(script.contains("set verificationDocument to make new document with properties {URL:\"about:blank\"}"))
        #expect(script.contains("set verificationDocument to front document"))
        #expect(script.contains("return do JavaScript \"1\" in verificationDocument"))
        #expect(!script.contains("close") && !script.contains("quit") && !script.contains("activate"))
        return CuaProcessResult(status: status, stdout: Data(output.utf8), stderr: Data())
    }
}

@MainActor @Test(arguments: ["success", "denied", "unexpectedOutput"])
func safariAttendedJavaScriptCheckUsesBoundedBlankDocumentScript(mode: String) async {
    let success = await DesktopBrowserPermission.verifyJavaScript(processRunner: SafariJavaScriptFixtureRunner(
        status: mode == "denied" ? 1 : 0, output: mode == "unexpectedOutput" ? "other" : "1\n"))
    #expect(success == (mode == "success"))
    let chromium = DesktopBrowserPermission.javaScriptVerificationScript(bundleIdentifier: "com.google.Chrome")
    #expect(chromium?.contains("make new document") == false)
    #expect(chromium?.contains("about:blank") == false)
    #expect(DesktopBrowserPermission.javaScriptVerificationScript(bundleIdentifier: "untrusted") == nil)
}
