import AppKit
import Combine
import Carbon
import PersonaStackCore

@MainActor
final class DesktopBrowserProfileConsentController: ObservableObject {
    static let shared = DesktopBrowserProfileConsentController()
    @Published private(set) var targets: [DesktopBrowserConsentTarget] = []
    @Published private(set) var selectedIDs: Set<String> = []
    @Published private(set) var approvedCount = 0
    struct PermissionAccess {
        var automation: @MainActor (String, Bool) async -> OSStatus = { await DesktopBrowserPermission.automation(bundleIdentifier: $0, prompt: $1) }
        var verifyConnection: @MainActor (DesktopBrowserConsentTarget) async throws -> Void = {
            try await DesktopControlRuntime.shared.verifyExistingBrowserForPermissions(target: $0)
        }
        var grantNeedsRestart: @MainActor () -> Bool = { DesktopControlRuntime.shared.existingBrowserGrantNeedsRestart }
        var javaScript: @MainActor (DesktopBrowserConsentTarget) async -> Bool = { await DesktopBrowserPermission.verifyJavaScript(bundleIdentifier: $0.bundleIdentifier, expectedPID: $0.pid) }
    }
    private var verifiedConnections: Set<String> = []
    private var verifiedJavaScript: Set<String> = []
    private var pendingTarget: DesktopBrowserConsentTarget?
    private var approvalGeneration = UUID()
    private let permissionAccess: PermissionAccess
    private var consent = DesktopBrowserProfileConsent()
    private let evidence: DesktopPermissionEvidence?
    private let inventory: @MainActor () -> [DesktopBrowserConsentTarget]

    init(inventory: @escaping @MainActor () -> [DesktopBrowserConsentTarget] = { DesktopBrowserProfileConsentController.currentBrowserWindows() },
         evidence: DesktopPermissionEvidence? = .shared, permissionAccess: PermissionAccess = .init()) {
        self.inventory = inventory
        self.evidence = evidence
        self.permissionAccess = permissionAccess
        verifiedJavaScript = evidence?.verifiedBrowserInstances() ?? []
        verifiedConnections = evidence?.verifiedBrowserConnectionInstances() ?? []
        refresh()
        selectedIDs = Set(selectionTargets.filter { consent.allows(pid: $0.pid, windowID: $0.windowID, current: targets) }.map(\.id))
    }

    var selectionTargets: [DesktopBrowserConsentTarget] {
        var seen: Set<Int32> = []
        return targets.filter { seen.insert($0.pid).inserted }
    }

    func refresh() {
        let selectedInstances = Set(targets.filter { selectedIDs.contains($0.id) }.map(\.instanceIdentity))
        targets = inventory().filter(\.isSupported)
        selectedIDs = Set(selectionTargets.filter { selectedInstances.contains($0.instanceIdentity) }.map(\.id))
        if let evidence { consent.restore(evidence.browserTargets(), current: targets) }
        consent.refresh(current: targets)
        approvedCount = consent.approvedTargets.count
    }

    func setSelected(_ selected: Bool, id: String) {
        guard targets.contains(where: { $0.id == id }) else { return }
        if selected { selectedIDs.insert(id) } else { selectedIDs.remove(id) }
    }

    /// Called exclusively from the native Continue action, after its generation
    /// guard. Passive refresh never records approval.
    func approveSelection() {
        approvalGeneration = UUID()
        let selected = Set(targets.filter { selectedIDs.contains($0.id) })
        let current = inventory()
        consent.approveSelection(selected, current: current)
        verifiedJavaScript.formIntersection(Set(consent.approvedTargets.map(\.instanceIdentity)))
        verifiedConnections.formIntersection(Set(consent.approvedTargets.map(\.instanceIdentity)))
        evidence?.recordBrowserTargets(consent.approvedTargets)
        refresh()
    }

    var hasApprovedTargets: Bool {
        refresh()
        return !consent.approvedTargets.isEmpty
    }

    var approvedTargets: Set<DesktopBrowserConsentTarget> {
        refresh()
        return Set(selectionTargets.filter { consent.allows(pid: $0.pid, windowID: $0.windowID, current: targets) })
    }

    func allowed(pid: Int32, windowID: UInt32) -> Bool {
        let current = inventory()
        if let evidence { consent.restore(evidence.browserTargets(), current: current) }
        consent.refresh(current: current)
        approvedCount = consent.approvedTargets.count
        return consent.allows(pid: pid, windowID: windowID, current: current)
    }

    func revokeAll() {
        approvalGeneration = UUID()
        verifiedJavaScript.removeAll()
        verifiedConnections.removeAll()
        consent.revokeAll()
        evidence?.recordBrowserTargets([])
        selectedIDs.removeAll()
        approvedCount = 0
    }

    /// Remote page reads never request Automation or exercise JavaScript to
    /// discover setup. Bundle-targeted Apple Events must have one live instance.
    func safePageAccess(pid: Int32, windowID: UInt32) async -> Bool {
        let before = inventory()
        guard let target = before.first(where: { $0.pid == pid && $0.windowID == windowID }),
              Set(before.filter { $0.bundleIdentifier == target.bundleIdentifier }.map(\.pid)).count == 1,
              allowed(pid: pid, windowID: windowID) else { return false }
        if let evidence {
            verifiedJavaScript = evidence.verifiedBrowserInstances()
            verifiedConnections = evidence.verifiedBrowserConnectionInstances()
        }
        guard verifiedJavaScript.contains(target.instanceIdentity), verifiedConnections.contains(target.instanceIdentity),
              !permissionAccess.grantNeedsRestart() else { return false }
        let generation = approvalGeneration
        let status = await permissionAccess.automation(target.bundleIdentifier, false)
        guard !Task.isCancelled, generation == approvalGeneration, status == noErr else { return false }
        let after = inventory()
        return !permissionAccess.grantNeedsRestart() && after.contains(target) &&
            Set(after.filter { $0.bundleIdentifier == target.bundleIdentifier }.map(\.pid)).count == 1 &&
            allowed(pid: pid, windowID: windowID)
    }

    func observeSelectedBrowsers() async -> DesktopPermissionObservation {
        await verifySelectedBrowsers(prompt: false, exerciseJavaScript: false)
    }

    func authorizeSelectedBrowsers() async -> DesktopPermissionObservation {
        await verifySelectedBrowsers(prompt: true, exerciseJavaScript: true)
    }

    func checkSelectedBrowsers() async -> DesktopPermissionObservation {
        await verifySelectedBrowsers(prompt: false, exerciseJavaScript: true)
    }

    @discardableResult func openPendingBrowser() -> Bool {
        guard let target = pendingTarget, allowed(pid: target.pid, windowID: target.windowID),
              let application = NSRunningApplication(processIdentifier: target.pid) else { return false }
        application.activate()
        return true
    }

    private func verifySelectedBrowsers(prompt: Bool, exerciseJavaScript: Bool) async -> DesktopPermissionObservation {
        let generation = approvalGeneration
        let selected = approvedTargets.sorted { $0.id < $1.id }
        var seen: Set<String> = []
        for target in selected where seen.insert(target.instanceIdentity).inserted {
            guard !Task.isCancelled, generation == approvalGeneration else { return .init(.verificationRequired, detail: "Browser setup was cancelled.") }
            let result = await verifyBrowser(target, prompt: prompt, exerciseJavaScript: exerciseJavaScript, generation: generation)
            guard !Task.isCancelled, generation == approvalGeneration,
                  allowed(pid: target.pid, windowID: target.windowID) else { return .init(.verificationRequired, detail: "The selected browser changed. Return to setup and select its current instance.") }
            if result.state != .ready {
                pendingTarget = target
                return result
            }
        }
        pendingTarget = nil
        return .init(.ready, detail: "Selected browser instances are approved and verified.", verified: true)
    }

    private func stillApproved(_ target: DesktopBrowserConsentTarget, generation: UUID) -> Bool {
        !Task.isCancelled && generation == approvalGeneration &&
            inventory().contains(target) && allowed(pid: target.pid, windowID: target.windowID)
    }

    private func verifyBrowser(_ target: DesktopBrowserConsentTarget, prompt: Bool, exerciseJavaScript: Bool, generation: UUID) async -> DesktopPermissionObservation {
        var status = await permissionAccess.automation(target.bundleIdentifier, false)
        guard stillApproved(target, generation: generation) else { return changedBrowser() }
        if status != noErr && prompt {
            status = await permissionAccess.automation(target.bundleIdentifier, true)
            guard stillApproved(target, generation: generation) else { return changedBrowser() }
        }
        guard status == noErr else {
            verifiedJavaScript.remove(target.instanceIdentity)
            verifiedConnections.remove(target.instanceIdentity)
            evidence?.recordVerifiedBrowserInstances(verifiedJavaScript)
            evidence?.recordVerifiedBrowserConnectionInstances(verifiedConnections)
            return .init(.notGranted, detail: "Allow PersonaStack to control \(target.browserName) in System Settings → Privacy & Security → Automation. Return here to continue.")
        }
        if let evidence {
            verifiedJavaScript = evidence.verifiedBrowserInstances()
            verifiedConnections = evidence.verifiedBrowserConnectionInstances()
        }
        if !verifiedJavaScript.contains(target.instanceIdentity) {
            guard exerciseJavaScript else { return .init(.verificationRequired, detail: "Verify JavaScript from Apple Events for \(target.browserName) during setup.") }
            let verified = await permissionAccess.javaScript(target)
            guard stillApproved(target, generation: generation) else { return changedBrowser() }
            guard verified else {
                return .init(.verificationRequired, detail: "In \(target.browserName), open View → Developer → Allow JavaScript from Apple Events. Keep a tab open, then return to PersonaStack for verification. Multiple running instances of the same browser require separate setup.")
            }
            verifiedJavaScript.insert(target.instanceIdentity)
            evidence?.recordVerifiedBrowserInstances(verifiedJavaScript)
        }
        return await verifyBrowserConnection(target, attended: exerciseJavaScript, generation: generation)
    }

    private func verifyBrowserConnection(_ target: DesktopBrowserConsentTarget, attended: Bool, generation: UUID) async -> DesktopPermissionObservation {
        if verifiedConnections.contains(target.instanceIdentity), !permissionAccess.grantNeedsRestart() {
            return .init(.ready, detail: "\(target.browserName) was connected and verified during setup.", verified: true)
        }
        guard attended else {
            return .init(.verificationRequired, detail: "Connect the approved \(target.browserName) instance during setup to verify unattended browser access.")
        }
        verifiedConnections.remove(target.instanceIdentity)
        evidence?.recordVerifiedBrowserConnectionInstances(verifiedConnections)
        do {
            try await permissionAccess.verifyConnection(target)
        } catch {
            guard stillApproved(target, generation: generation) else { return changedBrowser() }
            return .init(.verificationRequired, detail: "The approved \(target.browserName) connection could not be verified. Keep its window open and retry setup.")
        }
        guard stillApproved(target, generation: generation) else { return changedBrowser() }
        guard !permissionAccess.grantNeedsRestart() else {
            return .init(.verificationRequired, detail: "The browser service still needs to restart with the approved browser grant. Retry setup.")
        }
        verifiedConnections.insert(target.instanceIdentity)
        evidence?.recordVerifiedBrowserConnectionInstances(verifiedConnections)
        return .init(.ready, detail: "\(target.browserName) connection and JavaScript were verified during setup.", verified: true)
    }

    private func changedBrowser() -> DesktopPermissionObservation {
        .init(.verificationRequired, detail: "The selected browser changed or setup was cancelled. Select its current instance and retry.")
    }

    private static func currentBrowserWindows() -> [DesktopBrowserConsentTarget] {
        guard let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        var identities: [Int32: (String, Date, String)] = [:]
        for application in NSWorkspace.shared.runningApplications {
            guard let bundleID = application.bundleIdentifier,
                  ["com.google.Chrome", "com.microsoft.edgemac"].contains(bundleID),
                  let launchedAt = application.launchDate, !application.isTerminated,
                  let identity = DesktopBrowserPermission.codeIdentity(pid: application.processIdentifier) else { continue }
            identities[application.processIdentifier] = (bundleID, launchedAt, identity)
        }
        return windows.compactMap { window in
            guard let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let number = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue, layer == 0,
                  let identity = identities[pid] else { return nil }
            return DesktopBrowserConsentTarget(pid: pid, windowID: number, bundleIdentifier: identity.0,
                                               launchedAt: identity.1, codeIdentity: identity.2)
        }.sorted { $0.browserName == $1.browserName ? $0.windowID < $1.windowID : $0.browserName < $1.browserName }
    }


}
