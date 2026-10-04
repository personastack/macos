import AppKit
import Carbon
import PersonaStackCore

struct DesktopSafariProcessIdentity: Equatable {
    let pid: Int32
    let launchedAt: Date
    let codeIdentity: String
    var verificationKey: String { "safari-javascript:\(pid):\(launchedAt.timeIntervalSince1970):\(codeIdentity)" }
}

/// Reuses attended Safari setup evidence. It never launches a browser, executes
/// JavaScript, captures a window, or requests Apple Events authorization.
@MainActor
enum DesktopSafariPageAccess {
    struct Access {
        var identity: @MainActor () -> DesktopSafariProcessIdentity? = { DesktopBrowserPermission.safariProcessIdentity() }
        var ownsWindow: @MainActor (Int32, UInt32) -> Bool = { pid, window in
            guard let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                    as? [[String: Any]] else { return false }
            return windows.contains {
                ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int64Value == Int64(pid) &&
                ($0[kCGWindowNumber as String] as? NSNumber)?.uint64Value == UInt64(window) &&
                ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
            }
        }
        var automation: @MainActor () async -> OSStatus = { await DesktopBrowserPermission.automation(prompt: false) }
    }

    static func allowed(pid: Int32, windowID: UInt32,
                        evidence: DesktopPermissionEvidence = .shared, access: Access = .init()) async -> Bool {
        guard !Task.isCancelled, pid > 0, windowID > 0, let identity = access.identity(), identity.pid == pid,
              access.ownsWindow(pid, windowID), hasProof(identity, evidence: evidence) else { return false }
        let status = await access.automation()
        guard !Task.isCancelled, access.identity() == identity, access.ownsWindow(pid, windowID) else { return false }
        guard status == noErr else {
            if status == OSStatus(errAEEventNotPermitted) || status == OSStatus(errAEEventWouldRequireUserConsent) {
                evidence.invalidate(.safariJavaScript)
            }
            return false
        }
        return hasProof(identity, evidence: evidence)
    }

    private static func hasProof(_ identity: DesktopSafariProcessIdentity, evidence: DesktopPermissionEvidence) -> Bool {
        let current = DesktopPermissionObservation(.verificationRequired, detail: "Safari page read preflight",
                                                   verificationKey: identity.verificationKey)
        return evidence.restoring(.safariJavaScript, current: current).state == .ready
    }
}
