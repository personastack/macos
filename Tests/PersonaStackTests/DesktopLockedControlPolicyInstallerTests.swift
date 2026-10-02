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
    var omitsAllowRootOnReadback = false
    var updatesModifiedOnWrite = false
    var policyWriteOverrides: [String: Any] = [:]

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
        if omitsAllowRootOnReadback && name == Policy.right { rights[name]?["allow-root"] = nil }
        if updatesModifiedOnWrite {
            let previous = value["modified"] as? Double ?? 100.0
            rights[name]?["modified"] = previous + 1.0
        }
        if name == Policy.screensaverRight {
            for (key, value) in policyWriteOverrides { rights[name]?[key] = value }
        }
    }
    func removeRight(_ name: String) throws { calls.append("remove:" + name); rights[name] = nil }
    func removeReceipt() throws { calls.append("receipt.remove"); receipt = nil }
    var writes: [String] { calls.filter { $0.hasPrefix("write:") || $0 == "receipt.write" } }
}

@Suite struct DesktopLockedControlPolicyInstallerTests {
    typealias Policy = DesktopLockedControlPolicy

    @Test func mechanismsReadbackOmitsUserClassAllowRootField() throws {
        let system = PolicyInstallFixture()
        system.omitsAllowRootOnReadback = true
        try DesktopLockedControlPolicyInstaller.install(using: system)
        #expect(system.rights[Policy.right]?["allow-root"] == nil)
        #expect(Policy.validLeaf(system.rights[Policy.right]!))
        system.calls = []
        try DesktopLockedControlPolicyInstaller.install(using: system)
        #expect(system.writes.isEmpty)
        try DesktopLockedControlPolicyInstaller.uninstall(using: system)
        #expect(system.rights[Policy.right] == nil)
    }

    @Test func explicitRootBypassAndMalformedBooleansStillFailVerification() {
        for rootValue: Any in [true, 0, "false"] {
            var leaf = Policy.leaf
            leaf["allow-root"] = rootValue
            #expect(!Policy.validLeaf(leaf))
        }
    }

    @Test func uninstallRestoresManualPolicyBeforeRemovingPrivateArtifacts() throws {
        let system = PolicyInstallFixture()
        try DesktopLockedControlPolicyInstaller.install(using: system)
        system.calls = []
        try DesktopLockedControlPolicyInstaller.uninstall(using: system)
        #expect(system.calls.first == "verify")
        #expect(system.rights[Policy.screensaverRight]?["rule"] as? [String] == ["manual.one", "manual.two"])
        #expect(system.rights[Policy.screensaverRight]?["comment"] as? String == "keep")
        #expect(system.rights[Policy.right] == nil && system.receipt == nil)
        let writes = system.calls.filter { $0.hasPrefix("write:") || $0.hasPrefix("remove:") || $0 == "receipt.remove" }
        #expect(writes == ["write:" + Policy.screensaverRight, "remove:" + Policy.right, "receipt.remove"])
        try DesktopLockedControlPolicyInstaller.uninstall(using: system)
    }

    @Test func uninstallAcceptsAuthdModifiedTimestampWithoutLosingPolicyFields() throws {
        let system = PolicyInstallFixture()
        let created = 50.0
        system.rights[Policy.screensaverRight]?["created"] = created
        system.rights[Policy.screensaverRight]?["modified"] = 100.0
        system.updatesModifiedOnWrite = true
        try DesktopLockedControlPolicyInstaller.install(using: system)
        system.calls = []
        try DesktopLockedControlPolicyInstaller.uninstall(using: system)
        #expect(system.rights[Policy.screensaverRight]?["modified"] as? Double == 102.0)
        #expect(system.rights[Policy.screensaverRight]?["created"] as? Double == created)
        #expect(system.rights[Policy.screensaverRight]?["rule"] as? [String] == ["manual.one", "manual.two"])
        #expect(system.rights[Policy.screensaverRight]?["k-of-n"] as? Int == 1)
        #expect(system.rights[Policy.screensaverRight]?["comment"] as? String == "keep")
        #expect(system.rights[Policy.right] == nil && system.receipt == nil)
        #expect(system.calls.contains("remove:" + Policy.right) && system.calls.contains("receipt.remove"))
        try DesktopLockedControlPolicyInstaller.uninstall(using: system)
    }

    @Test(arguments: ["rule", "k-of-n", "class", "comment", "created", "foreign"])
    func uninstallRejectsChangedAuthorizationFieldsDespiteModifiedTimestamp(field: String) throws {
        let system = PolicyInstallFixture()
        system.rights[Policy.screensaverRight]?["created"] = 50.0
        system.updatesModifiedOnWrite = true
        try DesktopLockedControlPolicyInstaller.install(using: system)
        let changes: [String: Any] = [
            "rule": ["manual.two", "manual.one"], "k-of-n": 2, "class": "allow",
            "comment": "changed", "created": 51.0, "foreign": true
        ]
        system.policyWriteOverrides = [field: changes[field]!]
        system.calls = []
        #expect(throws: Policy.Failure.verificationFailed) {
            try DesktopLockedControlPolicyInstaller.uninstall(using: system)
        }
        #expect(system.rights[Policy.right] != nil && system.receipt != nil)
        #expect(!system.calls.contains(where: { $0.hasPrefix("remove:") || $0 == "receipt.remove" }))
    }

    @Test func uninstallRefusesForeignPolicyWithoutRemovingPayloadEvidence() throws {
        let system = PolicyInstallFixture()
        try DesktopLockedControlPolicyInstaller.install(using: system)
        system.rights[Policy.screensaverRight]?["rule"] = [Policy.right, "manual.one", "foreign"]
        system.calls = []
        #expect(throws: Policy.Failure.conflictingInstallation) {
            try DesktopLockedControlPolicyInstaller.uninstall(using: system)
        }
        #expect(system.writes.isEmpty)
        #expect(!system.calls.contains(where: { $0.hasPrefix("remove:") || $0 == "receipt.remove" }))
    }

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
