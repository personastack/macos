import Foundation
import PersonaStackCore
import Testing
@testable import PersonaStack

private func browserTarget(pid: Int32 = 42, window: UInt32 = 7, launch: Double = 100, code: String = "signed-code", bundle: String = "com.google.Chrome") -> DesktopBrowserConsentTarget {
    .init(pid: pid, windowID: window, bundleIdentifier: bundle, launchedAt: Date(timeIntervalSince1970: launch), codeIdentity: code)
}

@Test func browserConsentRequiresLocalApprovalAndCurrentInstance() {
    let target = browserTarget()
    var consent = DesktopBrowserProfileConsent()
    #expect(!consent.allows(pid: 42, windowID: 7, current: [target]))
    consent.approveSelection([target], current: [target])
    #expect(consent.allows(pid: 42, windowID: 7, current: [target]))
    #expect(!consent.allows(pid: 42, windowID: 7, current: [browserTarget(launch: 101)]))
    #expect(!consent.allows(pid: 42, windowID: 7, current: [browserTarget(code: "replacement")]))
    #expect(!consent.allows(pid: 43, windowID: 7, current: [browserTarget(pid: 43)]))
    #expect(!consent.allows(pid: 42, windowID: 7, current: []))
}

@Test func browserConsentCoversInstanceWindowsButNotReusedAnchor() {
    let anchor = browserTarget()
    let second = browserTarget(window: 8)
    var consent = DesktopBrowserProfileConsent()
    consent.approveSelection([anchor], current: [anchor])
    #expect(consent.allows(pid: 42, windowID: 8, current: [anchor, second]))
    #expect(consent.allows(pid: 42, windowID: 8, current: [second]))
    consent.refresh(current: [second])
    #expect(!consent.approvedTargets.isEmpty)
    consent.refresh(current: [])
    #expect(consent.approvedTargets.isEmpty)
    #expect(!consent.allows(pid: 42, windowID: 7, current: [anchor, second]))
}

@Test func browserConsentRejectsChangedSelectionAndUnsupportedBrowser() {
    let target = browserTarget()
    let unsupported = browserTarget(bundle: "com.apple.Safari")
    var consent = DesktopBrowserProfileConsent()
    consent.approveSelection([target, unsupported], current: [browserTarget(launch: 101), unsupported])
    #expect(consent.approvedTargets.isEmpty)
    consent.approveSelection([target], current: [target])
    consent.revokeAll()
    #expect(consent.approvedTargets.isEmpty)
}

@Test @MainActor func browserConsentControllerNeverApprovesOnRefreshOrSelection() {
    let target = browserTarget()
    var current = [target, browserTarget(window: 8)]
    let controller = DesktopBrowserProfileConsentController(inventory: { current }, evidence: nil)
    controller.refresh()
    #expect(controller.selectionTargets.count == 1)
    controller.setSelected(true, id: target.id)
    #expect(!controller.hasApprovedTargets)
    #expect(!controller.allowed(pid: 42, windowID: 7))
    controller.approveSelection()
    #expect(controller.hasApprovedTargets)
    #expect(controller.allowed(pid: 42, windowID: 8))
    current = [browserTarget(window: 8)]
    #expect(controller.approvedTargets.first?.windowID == 8)
    #expect(controller.selectedIDs == [browserTarget(window: 8).id])
    current = [browserTarget(launch: 101)]
    #expect(!controller.allowed(pid: 42, windowID: 7))
    #expect(!controller.hasApprovedTargets)
}

@Test @MainActor func browserConsentControllerFencesLateContinueAndUnknownSelection() {
    let target = browserTarget()
    var current = [target]
    let controller = DesktopBrowserProfileConsentController(inventory: { current }, evidence: nil)
    controller.refresh()
    controller.setSelected(true, id: "unknown")
    #expect(controller.selectedIDs.isEmpty)
    controller.setSelected(true, id: target.id)
    current = [browserTarget(launch: 101)]
    controller.approveSelection()
    #expect(!controller.hasApprovedTargets)
    #expect(controller.selectedIDs.isEmpty)
}

@MainActor private final class BrowserConsentPermissionAdapter: DesktopPermissionChecklistAdapting {
    var requests = 0
    func observe(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation { .init(.notGranted, detail: "Fixture") }
    func setup(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation {
        requests += 1
        return .init(.ready, detail: "Fixture")
    }
}

@Test @MainActor func browserConsentSetupRejectsOldOSBeforePermissionRequests() async {
    let adapter = BrowserConsentPermissionAdapter()
    let coordinator = DesktopPermissionChecklistCoordinator(adapter: adapter)
    let consent = DesktopBrowserProfileConsentController(inventory: { [browserTarget()] }, evidence: nil)
    var lockedChecks = 0
    let verifier = DesktopLockedControlSetupVerifier(operations: .init(inspect: { lockedChecks += 1; return .ready }))
    let window = DesktopPermissionChecklistWindow(coordinator: coordinator, browserConsent: consent,
                                                 supportsFullControl: { false }, lockedControlVerifier: verifier)
    coordinator.open()
    defer { coordinator.cancel() }
    await window.continueSetup()
    #expect(!coordinator.hasStarted)
    #expect(adapter.requests == 0 && lockedChecks == 0)
    #expect(!consent.hasApprovedTargets)
    #expect(coordinator.completionError.contains("macOS 15"))
    #expect(coordinator.completionError.contains("Chat remains available"))
}

@Test @MainActor func browserConsentReceiptPreservesPermissionEvidenceAndAppRestart() throws {
    let suite = "PersonaStackBrowserConsentTest-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let context = DesktopPermissionReceipt.Context(hostIdentity: "signed-host", osVersion: "15", driverIdentity: "pinned-driver")
    let evidence = DesktopPermissionEvidence(preferences: preferences, context: { context })
    let target = browserTarget()
    evidence.record([.localNetwork: .init(.ready, detail: "Fixture", verified: true)])
    let first = DesktopBrowserProfileConsentController(inventory: { [target] }, evidence: evidence)
    first.setSelected(true, id: target.id)
    first.approveSelection()
    #expect(first.hasApprovedTargets)
    let restarted = DesktopBrowserProfileConsentController(inventory: { [target] }, evidence: evidence)
    #expect(restarted.allowed(pid: 42, windowID: 7))
    #expect(restarted.selectedIDs == [target.id])
    #expect(evidence.restoring(.localNetwork, current: .init(.verificationRequired, detail: "Unknown")).state == .ready)
    evidence.record([.directCapture: .init(.ready, detail: "Fixture", verified: true)])
    #expect(restarted.allowed(pid: 42, windowID: 7))
    let changedBrowser = DesktopBrowserProfileConsentController(inventory: { [browserTarget(launch: 101)] }, evidence: evidence)
    #expect(!changedBrowser.hasApprovedTargets)
    let changedHost = DesktopPermissionEvidence(preferences: preferences, context: {
        .init(hostIdentity: "different-host", osVersion: "15", driverIdentity: "pinned-driver")
    })
    #expect(changedHost.browserTargets().isEmpty)
    restarted.revokeAll()
    #expect(evidence.browserTargets().isEmpty)
}

@Test func browserConsentReceiptBoundsAndLegacyDecode() throws {
    let context = DesktopPermissionReceipt.Context(hostIdentity: "host", osVersion: "15", driverIdentity: "driver")
    var receipt = DesktopPermissionReceipt(context: context, observations: [:], now: .distantPast)
    receipt.setBrowserTargets(Set((1...33).map { browserTarget(pid: Int32($0)) }))
    #expect(receipt.browserTargets(context: context).isEmpty)
    let data = try JSONEncoder().encode(receipt)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "approvedBrowserTargets")
    let legacy = try JSONDecoder().decode(DesktopPermissionReceipt.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(legacy.browserTargets(context: context).isEmpty)
}

@Test @MainActor func browserConsentPermissionChecksArePassiveAndSetupIsSequential() async {
    let target = browserTarget()
    var calls: [String] = []
    var granted = false
    var access = DesktopBrowserProfileConsentController.PermissionAccess()
    access.verifyConnection = { _ in }
    access.grantNeedsRestart = { false }
    access.automation = { bundle, prompt in
        calls.append("\(bundle):\(prompt)")
        if prompt { granted = true }
        return granted ? 0 : -1743
    }
    access.javaScript = { _ in calls.append("javascript"); return true }
    access.verifyConnection = { _ in calls.append("connection") }
    let controller = DesktopBrowserProfileConsentController(inventory: { [target] }, evidence: nil, permissionAccess: access)
    controller.setSelected(true, id: target.id)
    controller.approveSelection()
    #expect(await controller.observeSelectedBrowsers().state == .notGranted)
    #expect(calls == ["com.google.Chrome:false"])
    calls.removeAll()
    #expect(await controller.authorizeSelectedBrowsers().state == .ready)
    #expect(calls == ["com.google.Chrome:false", "com.google.Chrome:true", "javascript", "connection"])
    calls.removeAll()
    #expect(await controller.observeSelectedBrowsers().state == .ready)
    #expect(calls == ["com.google.Chrome:false"])
}

@Test @MainActor func browserConsentPermissionDenialNeverRunsJavaScript() async {
    let target = browserTarget()
    var scripts = 0
    var prompts = 0
    var access = DesktopBrowserProfileConsentController.PermissionAccess()
    access.verifyConnection = { _ in }
    access.grantNeedsRestart = { false }
    access.automation = { _, prompt in if prompt { prompts += 1 }; return -1743 }
    access.javaScript = { _ in scripts += 1; return true }
    let controller = DesktopBrowserProfileConsentController(inventory: { [target] }, evidence: nil, permissionAccess: access)
    controller.setSelected(true, id: target.id)
    controller.approveSelection()
    #expect(await controller.authorizeSelectedBrowsers().state == .notGranted)
    #expect(prompts == 1 && scripts == 0)
    #expect(await controller.checkSelectedBrowsers().state == .notGranted)
    #expect(prompts == 1 && scripts == 0)
}

@Test @MainActor func browserConsentSafePageAccessRequiresVerifiedSingleLiveInstance() async {
    let target = browserTarget()
    var current = [target]
    var scripts = 0
    var prompts = 0
    var changeDuringPreflight = false
    var access = DesktopBrowserProfileConsentController.PermissionAccess()
    access.verifyConnection = { _ in }
    access.grantNeedsRestart = { false }
    access.automation = { _, prompt in
        if prompt { prompts += 1 }
        if changeDuringPreflight { current = [browserTarget(launch: 101)] }
        return 0
    }
    access.javaScript = { _ in scripts += 1; return true }
    let controller = DesktopBrowserProfileConsentController(inventory: { current }, evidence: nil, permissionAccess: access)
    controller.setSelected(true, id: target.id)
    controller.approveSelection()
    #expect(await controller.safePageAccess(pid: 42, windowID: 7) == false)
    #expect(scripts == 0 && prompts == 0)
    #expect(await controller.authorizeSelectedBrowsers().state == .ready)
    #expect(await controller.safePageAccess(pid: 42, windowID: 7))
    #expect(scripts == 1 && prompts == 0)
    current.append(browserTarget(pid: 43, window: 8))
    #expect(await controller.safePageAccess(pid: 42, windowID: 7) == false)
    current = [target]
    changeDuringPreflight = true
    #expect(await controller.safePageAccess(pid: 42, windowID: 7) == false)
    #expect(scripts == 1 && prompts == 0)
}

@Test @MainActor func browserConsentConnectionProofPersistsPerInstanceAndNewSelectionRequiresHandshake() async throws {
    let suite = "browser-handshake-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let evidence = DesktopPermissionEvidence(preferences: defaults, context: {
        .init(hostIdentity: "fixture-host", osVersion: "fixture-os", driverIdentity: "fixture-driver")
    })
    let first = browserTarget()
    let second = browserTarget(pid: 43, window: 8, bundle: "com.microsoft.edgemac")
    var current = [first]
    var connected: [String] = []
    var scripts: [String] = []
    var restart = false
    var access = DesktopBrowserProfileConsentController.PermissionAccess()
    access.automation = { _, _ in 0 }
    access.javaScript = { scripts.append($0.instanceIdentity); return true }
    access.verifyConnection = { connected.append($0.instanceIdentity); restart = false }
    access.grantNeedsRestart = { restart }
    let controller = DesktopBrowserProfileConsentController(inventory: { current }, evidence: evidence, permissionAccess: access)
    controller.setSelected(true, id: first.id)
    controller.approveSelection()
    evidence.recordVerifiedBrowserInstances([first.instanceIdentity])
    #expect(await controller.observeSelectedBrowsers().state == .verificationRequired)
    #expect(connected.isEmpty && scripts.isEmpty)
    #expect(await controller.checkSelectedBrowsers().state == .ready)
    #expect(connected == [first.instanceIdentity])
    let relaunched = DesktopBrowserProfileConsentController(inventory: { current }, evidence: evidence, permissionAccess: access)
    #expect(await relaunched.observeSelectedBrowsers().state == .ready)
    #expect(connected.count == 1)
    current.append(second)
    relaunched.refresh()
    relaunched.setSelected(true, id: second.id)
    relaunched.approveSelection()
    #expect(await relaunched.observeSelectedBrowsers().state == .verificationRequired)
    #expect(await relaunched.checkSelectedBrowsers().state == .ready)
    #expect(connected == [first.instanceIdentity, second.instanceIdentity])
    #expect(scripts == [second.instanceIdentity])
    restart = true
    #expect(await relaunched.observeSelectedBrowsers().state == .verificationRequired)
    #expect(await relaunched.checkSelectedBrowsers().state == .ready)
    #expect(connected.count == 3)
    #expect(evidence.verifiedBrowserConnectionInstances() == [first.instanceIdentity, second.instanceIdentity])
}

@Test(arguments: ["cancel", "replace", "revoke", "failure"]) @MainActor
func browserConsentConnectionCompletionCannotApproveStaleOrFailedSetup(change: String) async {
    let target = browserTarget()
    var current = [target]
    var pending: CheckedContinuation<Void, Error>?
    var access = DesktopBrowserProfileConsentController.PermissionAccess()
    access.automation = { _, _ in 0 }
    access.javaScript = { _ in true }
    access.grantNeedsRestart = { false }
    access.verifyConnection = { _ in try await withCheckedThrowingContinuation { pending = $0 } }
    let controller = DesktopBrowserProfileConsentController(inventory: { current }, evidence: nil, permissionAccess: access)
    controller.setSelected(true, id: target.id)
    controller.approveSelection()
    let task = Task { await controller.checkSelectedBrowsers() }
    for _ in 0..<1_000 { if pending != nil { break }; await Task.yield() }
    #expect(pending != nil)
    switch change {
    case "cancel": task.cancel()
    case "replace": current = [browserTarget(launch: 101)]
    case "revoke": controller.revokeAll()
    default: break
    }
    if change == "failure" { pending?.resume(throwing: CuaMCPProxyError.invalidResponse) }
    else { pending?.resume() }
    #expect(await task.value.state == .verificationRequired)
    #expect(!(await controller.safePageAccess(pid: target.pid, windowID: target.windowID)))
}

@Test func browserConsentReceiptConnectionProofIsOptionalAndScopedToApprovedInstances() throws {
    let context = DesktopPermissionReceipt.Context(hostIdentity: "host", osVersion: "os", driverIdentity: "driver")
    let first = browserTarget()
    let second = browserTarget(pid: 43, window: 8)
    var receipt = DesktopPermissionReceipt(context: context, observations: [:], now: Date(), browserTargets: [first, second],
        browserConnectionInstances: [first.instanceIdentity, second.instanceIdentity, "foreign"])
    #expect(receipt.verifiedBrowserConnectionInstances(context: context) == [first.instanceIdentity, second.instanceIdentity])
    receipt.setBrowserTargets([second])
    #expect(receipt.verifiedBrowserConnectionInstances(context: context) == [second.instanceIdentity])
    #expect(receipt.verifiedBrowserConnectionInstances(context: .init(hostIdentity: "other", osVersion: "os", driverIdentity: "driver")).isEmpty)
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
    object.removeValue(forKey: "browserConnectionInstances")
    let legacy = try JSONDecoder().decode(DesktopPermissionReceipt.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(legacy.verifiedBrowserConnectionInstances(context: context).isEmpty)
}
