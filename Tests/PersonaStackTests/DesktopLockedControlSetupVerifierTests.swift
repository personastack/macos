import Foundation
@testable import PersonaStack
import Testing

@MainActor
private final class LockedControlSetupVerifierFixture {
    var value: DesktopLockedControlSetupVerifier.Snapshot
    var inspectCount = 0
    var changeCount = 0
    var suspendInspection = false
    var pendingInspection: CheckedContinuation<DesktopLockedControlSetupVerifier.Snapshot, Never>?
    let defaults: UserDefaults
    var verifier: DesktopLockedControlSetupVerifier! = nil

    init(_ value: DesktopLockedControlSetupVerifier.Snapshot = .absent) {
        self.value = value
        let suite = "DesktopLockedControlSetupVerifierTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        verifier = DesktopLockedControlSetupVerifier(defaults: defaults, operations: .init(inspect: { [unowned self] in
            self.inspectCount += 1
            if self.suspendInspection {
                self.suspendInspection = false
                return await withCheckedContinuation { self.pendingInspection = $0 }
            }
            return self.value
        }))
        verifier.onChange = { [unowned self] in self.changeCount += 1 }
    }
}

@Suite @MainActor
struct DesktopLockedControlSetupVerifierTests {
    @Test func codeSignatureVerificationUsesInlineRequirementAndExactPin() {
        let bundleURL = URL(fileURLWithPath: "/tmp/candidate with spaces.bundle")
        #expect(DesktopLockedControlSetupVerifier.pinnedCodeSignatureArguments(bundleURL, pin: Data()) == [
            "--verify", "--strict", "--deep", "-R",
            "=identifier \"ai.personastack.locked-grant-candidate\" and certificate leaf = H\"da39a3ee5e6b4b0d3255bfef95601890afd80709\"",
            "/tmp/candidate with spaces.bundle",
        ])
    }

    @Test func constructorUsesCachedFailClosedStateWithoutInspection() {
        let fixture = LockedControlSetupVerifierFixture(.ready)

        #expect(fixture.inspectCount == 0)
        #expect(fixture.verifier.snapshot == .absent)
        #expect(!fixture.verifier.permitsLockedControl)
        #expect(!fixture.verifier.recordAcknowledgement())
        #expect(!DesktopLockedControlAcknowledgement.isAccepted(defaults: fixture.defaults))
    }

    @Test func refreshPublishesStrictInjectedReadinessAndChange() async {
        let fixture = LockedControlSetupVerifierFixture(.mismatch)

        let result = await fixture.verifier.refresh()

        #expect(result.readiness == .mismatch)
        #expect(fixture.verifier.snapshot == result)
        #expect(fixture.inspectCount == 1)
        #expect(fixture.changeCount == 1)
        #expect(!fixture.verifier.permitsLockedControl)
        #expect(!fixture.verifier.recordAcknowledgement())

        fixture.value = .ready
        #expect(await fixture.verifier.refresh() == .ready)
        #expect(fixture.verifier.snapshot.readiness == .ready)
        #expect(fixture.inspectCount == 2)
        #expect(fixture.changeCount == 2)
        #expect(!fixture.verifier.permitsLockedControl)
    }

    @Test func concurrentRefreshesShareInspectionAndPublishOnce() async {
        let fixture = LockedControlSetupVerifierFixture(.absent)
        fixture.suspendInspection = true

        let explicitFinishRefresh = Task { await fixture.verifier.refresh() }
        while fixture.pendingInspection == nil { await Task.yield() }
        fixture.value = .ready
        let backgroundRefresh = Task { await fixture.verifier.refresh() }
        await Task.yield()

        #expect(fixture.inspectCount == 1)
        fixture.pendingInspection?.resume(returning: fixture.value)
        fixture.pendingInspection = nil

        let explicitResult = await explicitFinishRefresh.value
        let backgroundResult = await backgroundRefresh.value
        #expect(explicitResult == .ready)
        #expect(backgroundResult == .ready)
        #expect(fixture.verifier.snapshot == .ready)
        #expect(fixture.inspectCount == 1)
        #expect(fixture.changeCount == 1)
        #expect(!fixture.verifier.permitsLockedControl)
    }

    @Test func acknowledgementIsVersionedAndRequiresVerifiedSetup() async {
        let fixture = LockedControlSetupVerifierFixture(.ready)

        #expect(!fixture.verifier.permitsLockedControl)
        #expect(await fixture.verifier.refresh() == .ready)
        #expect(fixture.verifier.recordAcknowledgement())
        #expect(DesktopLockedControlAcknowledgement.currentVersion == 1)
        #expect(DesktopLockedControlAcknowledgement.isAccepted(defaults: fixture.defaults))
        #expect(fixture.verifier.permitsLockedControl)

        fixture.value = .mismatch
        await fixture.verifier.refresh()
        #expect(!fixture.verifier.permitsLockedControl)
        #expect(!fixture.verifier.recordAcknowledgement())
        #expect(DesktopLockedControlAcknowledgement.isAccepted(defaults: fixture.defaults))

        DesktopLockedControlAcknowledgement.clear(defaults: fixture.defaults)
        #expect(!DesktopLockedControlAcknowledgement.isAccepted(defaults: fixture.defaults))
        #expect(!fixture.verifier.permitsLockedControl)
    }

    @Test func wrongAcknowledgementVersionDoesNotPermitLockedControl() async {
        let fixture = LockedControlSetupVerifierFixture(.ready)
        fixture.defaults.set(DesktopLockedControlAcknowledgement.currentVersion + 1,
                            forKey: DesktopLockedControlAcknowledgement.defaultsKey)
        await fixture.verifier.refresh()

        #expect(!fixture.verifier.permitsLockedControl)
    }

    @Test func policyReadbackRejectsUnreviewedAdditionalAnyOfDelegate() throws {
        let ownedRight = try plist([
            "class": "evaluate-mechanisms",
            "mechanisms": [DesktopLockedControlSetupVerifier.candidateMechanism],
            "tries": 1,
            "shared": false,
            "allow-root": false,
            "version": 1,
        ])
        let screensaver = try plist([
            "class": "rule",
            "rule": [DesktopLockedControlSetupVerifier.candidateRight,
                     "use-login-window-ui", "vendor.later-change"],
            "k-of-n": 1,
            "comment": "unrelated live policy field",
        ])
        let receipt = try baselineReceipt(["use-login-window-ui"])

        #expect(!DesktopLockedControlSetupVerifier.policyEvidenceMatches(
            ownedRight: ownedRight, screensaverPolicy: screensaver, baselineReceipt: receipt))
    }

    @Test func policyReadbackRejectsMissingOrReorderedManualFallbacks() throws {
        let ownedRight = try validOwnedRight()
        let receipt = try baselineReceipt(["manual.one", "manual.two"])
        let missing = try screensaverRule([DesktopLockedControlSetupVerifier.candidateRight, "manual.two"])
        let reordered = try screensaverRule([DesktopLockedControlSetupVerifier.candidateRight,
                                             "manual.two", "manual.one"])

        #expect(!DesktopLockedControlSetupVerifier.policyEvidenceMatches(
            ownedRight: ownedRight, screensaverPolicy: missing, baselineReceipt: receipt))
        #expect(!DesktopLockedControlSetupVerifier.policyEvidenceMatches(
            ownedRight: ownedRight, screensaverPolicy: reordered, baselineReceipt: receipt))
    }

    @Test func policyReadbackRejectsWrongOwnedRightAndAmbiguousBranch() throws {
        let valid = try validOwnedRight()
        let wrongRight = try plist([
            "class": "evaluate-mechanisms", "mechanisms": ["another:mechanism,privileged"],
            "tries": 1, "shared": false, "allow-root": false, "version": 1,
        ])
        let duplicateBranch = try screensaverRule([
            DesktopLockedControlSetupVerifier.candidateRight,
            DesktopLockedControlSetupVerifier.candidateRight,
            "use-login-window-ui",
        ])
        let receipt = try baselineReceipt(["use-login-window-ui"])

        #expect(!DesktopLockedControlSetupVerifier.policyEvidenceMatches(
            ownedRight: wrongRight, screensaverPolicy: duplicateBranch, baselineReceipt: receipt))
        #expect(!DesktopLockedControlSetupVerifier.policyEvidenceMatches(
            ownedRight: valid, screensaverPolicy: duplicateBranch, baselineReceipt: receipt))
    }

    @Test func policyReadbackRequiresExactReceiptAndAnyOfFallbackRule() throws {
        let ownedRight = try validOwnedRight()
        let validRule = try screensaverRule([DesktopLockedControlSetupVerifier.candidateRight, "use-login-window-ui"])
        let wrongReceipt = try plist(["version": 1, "right": "other.right", "manualFallbacks": ["use-login-window-ui"]])
        let allOfRule = try plist([
            "class": "rule", "rule": [DesktopLockedControlSetupVerifier.candidateRight, "use-login-window-ui"],
            "k-of-n": 2,
        ])

        #expect(!DesktopLockedControlSetupVerifier.policyEvidenceMatches(
            ownedRight: ownedRight, screensaverPolicy: validRule, baselineReceipt: wrongReceipt))
        #expect(!DesktopLockedControlSetupVerifier.policyEvidenceMatches(
            ownedRight: ownedRight, screensaverPolicy: allOfRule,
            baselineReceipt: try baselineReceipt(["use-login-window-ui"])))
    }
}

private func validOwnedRight() throws -> Data {
    try plist([
        "class": "evaluate-mechanisms",
        "mechanisms": [DesktopLockedControlSetupVerifier.candidateMechanism],
        "tries": 1,
        "shared": false,
        "allow-root": false,
        "version": 1,
    ])
}

private func baselineReceipt(_ fallbacks: [String]) throws -> Data {
    try plist(["version": 1, "right": DesktopLockedControlSetupVerifier.candidateRight,
               "manualFallbacks": fallbacks])
}

private func screensaverRule(_ rules: [String]) throws -> Data {
    try plist(["class": "rule", "rule": rules, "k-of-n": 1])
}

private func plist(_ value: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
}
