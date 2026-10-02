import Foundation
import PersonaStackCore
import Testing

private final class PolicyInstallFixture: DesktopLockedControlPolicyInstalling {
    typealias Policy = DesktopLockedControlPolicy
    var rights: [String: [String: Any]] = [Policy.screensaverRight:
        ["class": "rule", "rule": ["manual.one", "manual.two"], "k-of-n": 1, "comment": "keep"]]
    var receipt: [String: Any]?
    var calls: [String] = []
    var rejectedPayload = false
    var failActivation = false
    var driftBeforeActivation = false
    var loseReadback = false
    var screensaverReads = 0

    func verifyPayload() throws {
        calls.append("verify")
        if rejectedPayload { throw Policy.Failure.verificationFailed }
    }
    func readRight(_ name: String) throws -> [String: Any]? {
        calls.append("read:" + name)
        if name == Policy.screensaverRight {
            screensaverReads += 1
            if driftBeforeActivation && screensaverReads == 2 { rights[name]?["comment"] = "changed" }
            if loseReadback && screensaverReads == 3 { return nil }
        }
        return rights[name]
    }
    func readReceipt() throws -> [String: Any]? { calls.append("receipt.read"); return receipt }
    func writeReceipt(_ value: [String: Any]) throws { calls.append("receipt.write"); receipt = value }
    func writeRight(_ name: String, value: [String: Any]) throws {
        calls.append("write:" + name)
        if failActivation && name == Policy.screensaverRight { throw Policy.Failure.verificationFailed }
        rights[name] = value
    }
    var writes: [String] { calls.filter { $0.hasPrefix("write:") || $0 == "receipt.write" } }
}

@Suite struct DesktopLockedControlPolicyInstallerTests {
    typealias Policy = DesktopLockedControlPolicy

    @Test func installPreservesManualFallbacksAndVerifiesReadback() throws {
        let system = PolicyInstallFixture()
        try DesktopLockedControlPolicyInstaller.install(using: system)
        #expect(system.calls.first == "verify")
        #expect(system.writes == ["receipt.write", "write:" + Policy.right, "write:" + Policy.screensaverRight])
        #expect(system.rights[Policy.screensaverRight]?["rule"] as? [String] == [Policy.right, "manual.one", "manual.two"])
        #expect(system.rights[Policy.screensaverRight]?["comment"] as? String == "keep")
        #expect(Policy.matches(leaf: system.rights[Policy.right]!, policy: system.rights[Policy.screensaverRight]!, receipt: system.receipt!))
        system.calls = []
        try DesktopLockedControlPolicyInstaller.install(using: system)
        #expect(system.writes.isEmpty)
    }

    @Test func untrustedPayloadDoesNotReadOrMutatePolicy() {
        let system = PolicyInstallFixture()
        system.rejectedPayload = true
        #expect(throws: (any Error).self) { try DesktopLockedControlPolicyInstaller.install(using: system) }
        #expect(system.calls == ["verify"])
    }

    @Test func invalidOrConflictingPoliciesNeverWrite() {
        let invalid: [[String: Any]] = [
            ["class": "allow"],
            ["class": "rule", "rule": ["one", "two"], "k-of-n": 0],
            ["class": "rule", "rule": "one", "k-of-n": true],
            ["class": "rule", "rule": "one", "k-of-n": 1.5],
            ["class": "rule", "rule": ["one", "one"], "k-of-n": 1],
            ["class": "rule", "rule": [Policy.right, "one"], "k-of-n": 1],
        ]
        for value in invalid {
            let system = PolicyInstallFixture()
            system.rights[Policy.screensaverRight] = value
            #expect(throws: (any Error).self) { try DesktopLockedControlPolicyInstaller.install(using: system) }
            #expect(system.writes.isEmpty)
        }
        let system = PolicyInstallFixture()
        system.rights[Policy.right] = ["class": "allow"]
        #expect(throws: (any Error).self) { try DesktopLockedControlPolicyInstaller.install(using: system) }
        #expect(system.writes.isEmpty)
    }

    @Test func inertPartialInstallCanRetryWithoutReplacingBaseline() throws {
        let system = PolicyInstallFixture()
        system.failActivation = true
        #expect(throws: (any Error).self) { try DesktopLockedControlPolicyInstaller.install(using: system) }
        #expect(system.rights[Policy.screensaverRight]?["rule"] as? [String] == ["manual.one", "manual.two"])
        system.calls = []
        system.failActivation = false
        try DesktopLockedControlPolicyInstaller.install(using: system)
        #expect(system.writes == ["write:" + Policy.screensaverRight])
    }

    @Test func concurrentPolicyChangeIsNotOverwritten() {
        let system = PolicyInstallFixture()
        system.driftBeforeActivation = true
        #expect(throws: (any Error).self) { try DesktopLockedControlPolicyInstaller.install(using: system) }
        #expect(!system.writes.contains("write:" + Policy.screensaverRight))
        #expect(system.rights[Policy.screensaverRight]?["comment"] as? String == "changed")
    }

    @Test func missingReadbackIsFailureEvenAfterSuccessfulWrite() {
        let system = PolicyInstallFixture()
        system.loseReadback = true
        #expect(throws: (any Error).self) { try DesktopLockedControlPolicyInstaller.install(using: system) }
    }

    @Test func insertedAnyOfDelegateDoesNotQualifyInstalledPolicy() throws {
        let original: [String: Any] = ["class": "rule", "rule": ["manual.one", "manual.two"], "k-of-n": 1]
        var changed = try Policy.compose(original)
        changed["rule"] = [Policy.right, "manual.one", "unreviewed.allow", "manual.two"]
        #expect(!Policy.matches(leaf: Policy.leaf, policy: changed, receipt: try Policy.receipt(for: original)))
        changed["rule"] = [Policy.right, "manual.one", "manual.two", "unreviewed.allow"]
        #expect(!Policy.matches(leaf: Policy.leaf, policy: changed, receipt: try Policy.receipt(for: original)))
    }

    @Test func changedOrForgedBaselineIsNotReplaced() throws {
        let system = PolicyInstallFixture()
        system.receipt = ["version": 1, "right": Policy.right, "manualFallbacks": ["other"]]
        #expect(throws: (any Error).self) { try DesktopLockedControlPolicyInstaller.install(using: system) }
        #expect(system.writes.isEmpty)
        let policy = try Policy.compose(system.rights[Policy.screensaverRight]!)
        #expect(!Policy.matches(leaf: Policy.leaf, policy: policy,
            receipt: ["version": 1, "right": Policy.right, "manualFallbacks": [Policy.right]]))
    }
}
